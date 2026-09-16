import Foundation

/// P2-3: proactive dictionary hygiene audit (plan §2 P2-3).
///
/// Monthly-ish audit (manual cadence — no LaunchAgent per task scope):
///   `meetingscribe hygiene`          audit + report (read-only)
///   `meetingscribe hygiene --apply`  backup-then-prune (never destructive
///                                    without a backup copy first)
///
/// Audits ~/.meetingscribe/corrections.json + glossary.json:
///   - entries unused for 90+ days (updatedAt older than the cutoff);
///   - duplicates / case-collisions (two wrong-terms differing only by case,
///     and no-op wrong==right-ignoring-case mappings);
///   - phonetic collisions (DoubleMetaphone primary code shared between an
///     active correction term and a glossary term) — the "odd substitutions"
///     class Wispr's docs warn about; these are REPORT-ONLY, never auto-pruned.
///
/// Also shows the active prompt-list composition (taught corrections -> names
/// -> glossary) against RosterBuilder's 200-word budget, so the report tells
/// Dan whether the dictionary still fits the cap.
///
/// Pure audit/prune logic is deterministic and mirrored in
/// tools/eval/p2_logic.py for the host regression suite.
enum DictionaryHygiene {

    static let unusedDays = 90
    static let wordBudget = RosterBuilder.wordBudget  // 200, same cap as the roster prompt

    // MARK: - Findings

    enum FindingKind: String {
        case unused = "unused"
        case duplicate = "duplicate"
        case caseCollision = "case-collision"
        case phoneticCollision = "phonetic-collision"
    }

    struct Finding {
        let kind: FindingKind
        let term: String
        let detail: String
    }

    struct Report {
        let findings: [Finding]
        /// Terms safe to prune automatically with --apply (unused, duplicates,
        /// case-collisions). Phonetic collisions are report-only.
        let pruneSuggestions: [String]
        /// Roster prompt composition vs the 200-word budget (advisory).
        let promptWordCount: Int
        let promptWordBudget: Int
        let correctionsCount: Int
        let glossaryCount: Int

        var withinBudget: Bool { promptWordCount <= promptWordBudget }
    }

    // MARK: - Audit (pure)

    /// Audit the dictionary + glossary. `updatedAtNow` injectable for tests.
    static func audit(
        corrections: CorrectionDictionary.File,
        glossary: [AppConfiguration.Transcription.GlossaryEntry],
        now: Double = Date().timeIntervalSince1970
    ) -> Report {
        var findings: [Finding] = []
        var prune: [String] = []
        let cutoff = now - Double(unusedDays) * 86400

        var seen: [String: String] = [:]  // lowercased wrong -> original wrong
        for entry in corrections.entries {
            let key = entry.wrong.lowercased()
            if let original = seen[key] {
                findings.append(Finding(kind: .duplicate, term: entry.wrong,
                                        detail: "case-insensitive duplicate of '\(original)'"))
                prune.append(entry.wrong)
                continue
            }
            seen[key] = entry.wrong

            if entry.updatedAt < cutoff {
                let days = Int((now - entry.updatedAt) / 86400)
                findings.append(Finding(kind: .unused, term: entry.wrong,
                                        detail: "unused for \(days) days (>\(unusedDays))"))
                prune.append(entry.wrong)
            }
            if entry.wrong.lowercased() == entry.right.lowercased() {
                findings.append(Finding(kind: .caseCollision, term: entry.wrong,
                                        detail: "wrong/right differ only by case (no-op mapping)"))
                if !prune.contains(entry.wrong) { prune.append(entry.wrong) }
            }
        }

        // Phonetic collisions: correction term vs glossary term sharing a
        // DoubleMetaphone primary code. Report-only — a collision does not
        // mean either entry is wrong.
        let metaphone = DoubleMetaphone()
        var glossaryByCode: [String: String] = [:]
        for entry in glossary {
            let code = metaphone.encode(entry.term).primary
            if !code.isEmpty, glossaryByCode[code] == nil {
                glossaryByCode[code] = entry.term
            }
        }
        for entry in corrections.entries {
            let code = metaphone.encode(entry.right).primary
            if let clash = glossaryByCode[code], clash.lowercased() != entry.right.lowercased() {
                findings.append(Finding(kind: .phoneticCollision, term: entry.right,
                                        detail: "phonetically collides with glossary term '\(clash)' — review, not auto-pruned"))
            }
        }

        return Report(
            findings: findings,
            pruneSuggestions: prune,
            promptWordCount: 0,   // filled by auditPrompt when a prompt exists
            promptWordBudget: wordBudget,
            correctionsCount: corrections.entries.count,
            glossaryCount: glossary.count)
    }

    /// Prune the suggested terms from the dictionary. Returns nil when a term
    /// was not found (caller decides whether that is an error).
    static func pruned(_ file: CorrectionDictionary.File, removing terms: [String]) -> CorrectionDictionary.File {
        var updated = file
        for term in terms {
            updated = CorrectionDictionary.remove(file: updated, wrong: term) ?? updated
        }
        return updated
    }

    // MARK: - Prompt composition (budget check)

    /// Composition of the active roster prompt against the budget: how many
    /// words go to taught corrections vs attendee names vs glossary terms
    /// (the prompt's priority order). Uses the same section intros the
    /// AssemblyAI keyterm mapping parses.
    static func promptComposition(rosterPrompt: String) -> (corrections: Int, names: Int, terms: Int, total: Int) {
        guard !rosterPrompt.isEmpty else { return (0, 0, 0, 0) }
        let namesWords = sectionBody(rosterPrompt, after: AssemblyAIUniversal3Provider.namesSectionIntro)?
            .split(separator: ",").reduce(0) { $0 + $1.split(whereSeparator: { $0.isWhitespace }).count } ?? 0
        let correctionsWords = sectionBody(rosterPrompt, after: AssemblyAIUniversal3Provider.correctionsSectionIntro)?
            .split(separator: ",").reduce(0) { $0 + $1.split(whereSeparator: { $0.isWhitespace }).count } ?? 0
        let termsWords = sectionBody(rosterPrompt, after: AssemblyAIUniversal3Provider.termsSectionIntro)?
            .split(separator: ",").reduce(0) { $0 + $1.split(whereSeparator: { $0.isWhitespace }).count } ?? 0
        return (correctionsWords, namesWords, termsWords, correctionsWords + namesWords + termsWords)
    }

    private static func sectionBody(_ prompt: String, after intro: String) -> String? {
        guard let introRange = prompt.range(of: intro) else { return nil }
        let tail = prompt[introRange.upperBound...]
        guard let end = tail.range(of: ".") else { return nil }
        let body = String(tail[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    // MARK: - Rendering

    static func renderReport(_ report: Report, composition: (corrections: Int, names: Int, terms: Int, total: Int)?) -> String {
        var lines: [String] = []
        lines.append("Dictionary hygiene report")
        lines.append("=" * 60)
        lines.append("Corrections dictionary: \(report.correctionsCount) entries; glossary: \(report.glossaryCount) entries")

        if let c = composition {
            let status = (c.total <= report.promptWordBudget) ? "within" : "OVER"
            lines.append("Active prompt composition (\(status) the \(report.promptWordBudget)-word budget):")
            lines.append("  taught corrections: \(c.corrections) words (highest priority)")
            lines.append("  attendee names:     \(c.names) words")
            lines.append("  glossary terms:     \(c.terms) words")
            lines.append("  total:              \(c.total) / \(report.promptWordBudget) words")
        }

        lines.append("")
        if report.findings.isEmpty {
            lines.append("No findings — dictionary is clean.")
        } else {
            lines.append("Findings (\(report.findings.count)):")
            for f in report.findings {
                lines.append("  [\(f.kind.rawValue)] \(f.term) — \(f.detail)")
            }
        }

        lines.append("")
        if report.pruneSuggestions.isEmpty {
            lines.append("Prune suggestions: none.")
        } else {
            lines.append("Prune suggestions (\(report.pruneSuggestions.count)) — run `meetingscribe hygiene --apply` to prune (a backup is written first):")
            for term in report.pruneSuggestions {
                lines.append("  - \(term)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension String {
    static func * (lhs: String, rhs: Int) -> String { String(repeating: lhs, count: rhs) }
}
