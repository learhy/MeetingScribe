import Foundation

// MARK: - RosterBuilder
//
// Builds the per-meeting Whisper biasing prompt (P0-2/P0-3 of the accuracy plan).
//
// Design (approved plan, §2 P0-3):
//   - Attendee names from the resolved calendar event, using FULL display names
//     from contacts (Dan's Q3 decision), falling back to calendar first names.
//   - Ranked: organizer first, then known/repeat attendees (present in the people
//     DB with a non-calendar source), then remaining attendees in calendar order.
//   - De-duplicated (case-insensitive).
//   - Plus top glossary terms and any stored wrong→right correction mappings.
//   - Capped: ~200-word soft budget, 224-token Whisper prompt hard limit with
//     headroom (208 estimated). Drop-tail: lowest-ranked entries are dropped
//     first — glossary terms before names, names never truncated mid-name.
//
// If calendar resolution failed (participants == nil), returns "" so callers
// fall back to the static glossary prompt.

struct RosterBuilder {

    /// Hard token limit of the Whisper `prompt` parameter is 224; we target
    /// 208 to leave headroom for tokenizer variance.
    static let tokenBudget = 208

    /// Soft word budget (~200 words per the plan).
    static let wordBudget = 200

    // MARK: Public entry point

    /// Build the per-meeting roster prompt.
    ///
    /// - Parameters:
    ///   - participants: Calendar-resolved meeting participants (nil if calendar resolution failed).
    ///   - contacts: Contacts fetched for the meeting's attendee emails.
    ///   - glossary: Glossary entries (person-context entries ranked first).
    ///   - corrections: Stored wrong→right name mappings (P1-1 flywheel).
    ///   - priorNames: Names seen in prior meetings for these attendees (repeat attendees).
    /// - Returns: The prompt string, or "" when there is nothing meeting-specific to add.
    ///
    /// P1-1: taught corrections are the HIGHEST-priority tier — they are placed
    /// FIRST (before names) so the budget never drops them in favor of
    /// lower-value glossary terms. The 200-word/208-token cap still applies
    /// overall; corrections are capped at 10 pairs to keep the roster viable.
    static func buildPrompt(
        participants: MeetingParticipants?,
        contacts: [ContactInfo],
        glossary: [AppConfiguration.Transcription.GlossaryEntry],
        corrections: [String: String] = [:],
        priorNames: [String] = []
    ) -> String {
        guard let participants = participants, !participants.participants.isEmpty else {
            return ""
        }

        let names = rankedNames(participants: participants, contacts: contacts, priorNames: priorNames)
        guard !names.isEmpty else { return "" }

        var prompt = namesSection(for: names)

        // Corrections (P1-1 flywheel) — highest authority, first so the
        // drop-tail budget can never evict them in favor of glossary terms.
        if !corrections.isEmpty {
            let cappedPairs = corrections
                .sorted { $0.key.lowercased() < $1.key.lowercased() }
                .prefix(10)
            let correctionsIntro = "Common corrections: "
            var keptPairs: [String] = []
            for pair in cappedPairs {
                var trial = prompt + " " + correctionsIntro
                if !keptPairs.isEmpty {
                    trial += keptPairs.joined(separator: ", ") + ", "
                }
                trial += "\(pair.key)→\(pair.value)" + "."
                if estimateTokens(trial) <= tokenBudget && wordCount(trial) <= wordBudget {
                    keptPairs.append("\(pair.key)→\(pair.value)")
                } else {
                    break
                }
            }
            if !keptPairs.isEmpty {
                prompt += " " + correctionsIntro + keptPairs.joined(separator: ", ") + "."
            }
        }

        // Names section — drop tail names whole (never mid-name) if over budget.
        var keptNames = names
        while keptNames.count > 1 &&
              (estimateTokens(prompt) > tokenBudget || wordCount(prompt) > wordBudget) {
            keptNames.removeLast()
            prompt = namesSection(for: keptNames)
            if !corrections.isEmpty {
                // Re-append any corrections that still fit with the shrunken roster.
                prompt = appendCorrections(prompt, corrections: corrections)
            }
        }
        guard estimateTokens(prompt) <= tokenBudget else { return "" }
        if keptNames.count < names.count {
            // Tail dropped — could log at call site; prompt stays honest about what it kept.
        }

        // Glossary terms — appended while they fit; drop-tail (terms before names).
        let terms = rankedGlossaryTerms(glossary: glossary, exclude: Set(names.map { $0.lowercased() }))
        if !terms.isEmpty {
            let termsIntro = "Technical terms that may come up: "
            var keptTerms: [String] = []
            for term in terms {
                var trial = prompt + " " + termsIntro
                if !keptTerms.isEmpty {
                    trial += keptTerms.joined(separator: ", ") + ", "
                }
                trial += term + "."
                if estimateTokens(trial) <= tokenBudget && wordCount(trial) <= wordBudget {
                    keptTerms.append(term)
                } else {
                    break // drop-tail: once one doesn't fit, stop
                }
            }
            if !keptTerms.isEmpty {
                prompt += " " + termsIntro + keptTerms.joined(separator: ", ") + "."
            }
        }

        return prompt
    }

    // MARK: - Prompt section helpers

    private static func namesSection(for names: [String]) -> String {
        "The following people may be mentioned in this meeting: " + names.joined(separator: ", ") + "."
    }

    /// Append the "Common corrections:" section to a prompt while it fits the budget.
    /// Used by buildPrompt so corrections survive roster shrinkage (P1-1).
    private static func appendCorrections(_ prompt: String, corrections: [String: String]) -> String {
        guard !corrections.isEmpty else { return prompt }
        let correctionsIntro = "Common corrections: "
        let cappedPairs = corrections
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .prefix(10)
        var keptPairs: [String] = []
        for pair in cappedPairs {
            let rendered = "\(pair.key)→\(pair.value)"
            let trial = prompt + " " + correctionsIntro
                + (keptPairs.isEmpty ? "" : keptPairs.joined(separator: ", ") + ", ")
                + rendered + "."
            if estimateTokens(trial) <= tokenBudget && wordCount(trial) <= wordBudget {
                keptPairs.append(rendered)
            } else {
                break
            }
        }
        if keptPairs.isEmpty { return prompt }
        return prompt + " " + correctionsIntro + keptPairs.joined(separator: ", ") + "."
    }

    // MARK: - Name resolution & ranking

    /// Resolve and rank attendee display names.
    /// Rank: organizer (isMe) → prior/repeat names → contacts-known attendees → calendar-only.
    /// De-duplicated case-insensitively; full display names from contacts per Dan's Q3 decision.
    static func rankedNames(
        participants: MeetingParticipants,
        contacts: [ContactInfo],
        priorNames: [String] = []
    ) -> [String] {
        let contactsByEmail = Dictionary(
            contacts.map { ($0.email.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Buckets by rank
        var organizer: [String] = []
        var prior: [String] = []
        var known: [String] = []
        var calendarOnly: [String] = []
        var seen = Set<String>()

        let priorLower = Set(priorNames.map { $0.lowercased() })

        /// Best full display name for a participant: contact displayName → preferredName → calendar first name.
        func displayName(for participant: Participant) -> String {
            let contact = contactsByEmail[participant.email.lowercased()]
            return contact?.displayName ?? contact?.bestName ?? participant.firstName
        }

        /// Append name to its rank bucket if non-empty and not already seen.
        func append(_ name: String, bucket: inout [String]) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed.lowercased()) else { return }
            seen.insert(trimmed.lowercased())
            bucket.append(trimmed)
        }

        // Organizer first
        if let me = participants.participants.first(where: { $0.isMe }) {
            append(displayName(for: me), bucket: &organizer)
        } else if !participants.myFirstName.isEmpty {
            append(participants.myFirstName, bucket: &organizer)
        }

        // Other attendees, ranked
        for participant in participants.participants where !participant.isMe {
            let name = displayName(for: participant)
            if priorLower.contains(name.lowercased()) {
                append(name, bucket: &prior)
            } else if let contact = contactsByEmail[participant.email.lowercased()],
                      contact.source == "manual" || contact.source == "speaker_db" {
                // Known people (manually curated or seen via the speaker DB) rank
                // above calendar-only names as a proxy for repeat attendees.
                append(name, bucket: &known)
            } else {
                append(name, bucket: &calendarOnly)
            }
        }

        return organizer + prior + known + calendarOnly
    }

    // MARK: - Glossary ranking

    /// Rank glossary terms: person-context entries first (they are the names Whisper
    /// most needs), then technical terms. Excludes terms already present in the roster.
    static func rankedGlossaryTerms(
        glossary: [AppConfiguration.Transcription.GlossaryEntry],
        exclude: Set<String>
    ) -> [String] {
        let personContexts = ["team", "colleague", "person", "manager", "engineer",
                              "analyst", "design", "pm", "lead", "director", "principal", "vault"]

        var personTerms: [String] = []
        var otherTerms: [String] = []
        var seen = Set<String>()

        for entry in glossary {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            let key = term.lowercased()
            guard !seen.contains(key), !exclude.contains(key) else { continue }
            seen.insert(key)

            let context = entry.context?.lowercased() ?? ""
            if personContexts.contains(where: { context.contains($0) }) {
                personTerms.append(term)
            } else {
                otherTerms.append(term)
            }
        }
        return personTerms + otherTerms
    }

    // MARK: - Budget estimation

    /// Conservative token estimate for the Whisper tokenizer: each whitespace-
    /// separated word costs ceil(len/4) tokens (min 1); punctuation-adjacent
    /// separators add 1 token per word on top. Conservative by design so we
    /// never exceed the 224-token hard limit.
    static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        var tokens = 0
        for word in words {
            tokens += max(1, Int(ceil(Double(word.count) / 4.0))) + 1
        }
        return tokens
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func sentence(for names: [String]) -> String {
        namesSection(for: names)
    }
}
