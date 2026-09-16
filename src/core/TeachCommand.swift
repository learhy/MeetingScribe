import Foundation

/// P1-1: headless CLI subcommands for the manual dictionary flywheel.
///
/// Usage (via the app binary or a symlink named `meetingscribe`):
///   meetingscribe teach "Ratchna->Rachana"     Teach a wrong→right mapping
///   meetingscribe dictionary list              List all mappings (human-readable)
///   meetingscribe dictionary export            Export mappings as flat JSON
///   meetingscribe dictionary remove "Ratchna"  Remove a mapping
///
/// Exit codes: 0 success, 1 usage/parse error, 2 I/O error.
/// [needs-Mac-build] — exercised on the Mac build; parsing/store logic is
/// mirrored in tools/eval/run_regression.py for this host.
enum TeachCommand {

    static let handledSubcommands: Set<String> = ["teach", "dictionary", "retention", "hygiene"]

    static func handles(_ subcommand: String) -> Bool {
        handledSubcommands.contains(subcommand.lowercased())
    }

    /// Run the subcommand. `arguments` excludes the subcommand itself.
    /// Always exits the process — never returns on the GUI path.
    @discardableResult
    static func run(arguments: [String], path: URL = CorrectionDictionary.defaultPath()) -> Int32 {
        guard let subcommand = arguments.first?.lowercased() else {
            printUsage()
            return 1
        }
        let rest = Array(arguments.dropFirst())

        switch subcommand {
        case "teach":
            return runTeach(rest, path: path)
        case "dictionary":
            return runDictionary(rest, path: path)
        case "retention":
            return runRetention(rest)
        case "hygiene":
            return runHygiene(rest, path: path)
        default:
            print("Unknown subcommand: \(subcommand)")
            printUsage()
            return 1
        }
    }

    // MARK: - hygiene (P2-3)

    /// `meetingscribe hygiene` — audit corrections.json + glossary, report.
    /// `meetingscribe hygiene --apply` — backup-then-prune (never destructive
    /// without a backup copy first).
    private static func runHygiene(_ args: [String], path: URL) -> Int32 {
        let apply = args.contains("--apply")

        let corrections = CorrectionDictionary.load(path: path)
        let glossary = ConfigManager.shared.glossaryEntries
        let report = DictionaryHygiene.audit(corrections: corrections, glossary: glossary)

        // Advisory prompt-composition line only when a roster prompt exists is
        // not possible headlessly (no meeting) — show dictionary totals only.
        print(DictionaryHygiene.renderReport(report, composition: nil))

        guard apply else {
            print("\nDry run — no changes made. Re-run with --apply to prune \(report.pruneSuggestions.count) term(s).")
            return 0
        }

        guard !report.pruneSuggestions.isEmpty else {
            print("Nothing to prune.")
            return 0
        }

        // Backup first — never destructive without a backup copy.
        let backupPath = path.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))")
        do {
            try FileManager.default.copyItem(at: path, to: backupPath)
            print("Backup written: \(backupPath.path)")
        } catch {
            if FileManager.default.fileExists(atPath: path.path) {
                print("Error: could not write backup, aborting prune: \(error.localizedDescription)")
                return 2
            }
            // No dictionary file on disk yet — nothing to back up, prune is safe.
            print("No existing dictionary file to back up; proceeding.")
        }

        let updated = DictionaryHygiene.pruned(corrections, removing: report.pruneSuggestions)
        guard CorrectionDictionary.save(updated, path: path) else {
            print("Error: could not write pruned dictionary at \(path.path)")
            return 2
        }
        print("Pruned \(report.pruneSuggestions.count) term(s); \(updated.entries.count) entries remain.")
        return 0
    }

    // MARK: - retention (P1-4)

    /// `meetingscribe retention sweep` — delete retained WAVs older than the
    /// configured window (config audio.audioRetentionDays, default 30).
    /// `meetingscribe retention list` — show meetings with raw artifacts that
    /// can be re-run with the current pipeline.
    private static func runRetention(_ args: [String]) -> Int32 {
        guard let verb = args.first?.lowercased() else {
            print("Usage: meetingscribe retention <sweep|list>")
            return 1
        }
        switch verb {
        case "sweep":
            let home = NSHomeDirectory()
            let recordings = URL(fileURLWithPath: home)
                .appendingPathComponent("Documents/MeetingScribe/recordings")
            let retentionDays = AudioRetentionPolicy.defaultRetentionDays
            let (deleted, freed) = AudioRetentionPolicy.enforceRetention(directory: recordings, retentionDays: retentionDays)
            let mb = Double(freed) / 1_000_000.0
            print("Retention sweep (\(retentionDays) days): deleted \(deleted.count) file\(deleted.count == 1 ? "" : "s"), freed \(String(format: "%.1f", mb)) MB")
            for file in deleted { print("  - \(file)") }
            return 0
        case "list":
            let meetings = ArtifactWriter.listedMeetings()
            if meetings.isEmpty {
                print("No retained raw artifacts found in ~/.meetingscribe/artifacts/")
            } else {
                print("Meetings with raw artifacts (re-run candidates):")
                for id in meetings { print("  \(id)") }
            }
            return 0
        default:
            print("Unknown retention verb: \(verb)")
            print("Usage: meetingscribe retention <sweep|list>")
            return 1
        }
    }

    // MARK: - teach

    private static func runTeach(_ args: [String], path: URL) -> Int32 {
        // Accept both:  teach "Wrong->Right"   and   teach "Wrong" "Right"
        let pair: (wrong: String, right: String)
        switch args.count {
        case 1:
            guard let parsed = try? CorrectionDictionary.parseTeachArgument(args[0]) else {
                print("Error: teach argument must be \"WrongName->RightName\" (also accepted: =>, →, =).")
                return 1
            }
            pair = parsed
        case 2:
            let wrong = args[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let right = args[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wrong.isEmpty, !right.isEmpty else {
                print("Error: both names must be non-empty.")
                return 1
            }
            pair = (wrong, right)
        default:
            print("Usage: meetingscribe teach \"WrongName->RightName\"")
            return 1
        }

        var file = CorrectionDictionary.load(path: path)
        file = CorrectionDictionary.add(file: file, wrong: pair.wrong, right: pair.right,
                                        source: CorrectionDictionary.sourceManual)
        guard CorrectionDictionary.save(file, path: path) else {
            print("Error: could not write dictionary at \(path.path)")
            return 2
        }
        print("Taught: \(pair.wrong) → \(pair.right)")
        print("Dictionary: \(path.path) (\(file.entries.count) entr\(file.entries.count == 1 ? "y" : "ies"))")
        return 0
    }

    // MARK: - dictionary

    private static func runDictionary(_ args: [String], path: URL) -> Int32 {
        guard let verb = args.first?.lowercased() else {
            print("Usage: meetingscribe dictionary <list|export|remove \"WrongName\">")
            return 1
        }
        let file = CorrectionDictionary.load(path: path)

        switch verb {
        case "list":
            print(CorrectionDictionary.renderList(file))
            return 0
        case "export":
            print(CorrectionDictionary.renderJSON(file))
            return 0
        case "remove", "rm":
            guard args.count >= 2 else {
                print("Usage: meetingscribe dictionary remove \"WrongName\"")
                return 1
            }
            guard let updated = CorrectionDictionary.remove(file: file, wrong: args[1]) else {
                print("No entry for: \(args[1])")
                return 1
            }
            guard CorrectionDictionary.save(updated, path: path) else {
                print("Error: could not write dictionary at \(path.path)")
                return 2
            }
            print("Removed: \(args[1])")
            return 0
        default:
            print("Unknown dictionary verb: \(verb)")
            print("Usage: meetingscribe dictionary <list|export|remove \"WrongName\">")
            return 1
        }
    }

    private static func printUsage() {
        print("""
        Usage:
          meetingscribe teach "WrongName->RightName"     Teach a correction (manual flywheel v1)
          meetingscribe teach "WrongName" "RightName"    Same, two arguments
          meetingscribe dictionary list                  List all taught corrections
          meetingscribe dictionary export                Export corrections as flat JSON
          meetingscribe dictionary remove "WrongName"    Remove a correction
          meetingscribe retention sweep                  Delete WAVs older than the retention window
          meetingscribe retention list                   List meetings re-runnable with the current pipeline
          meetingscribe hygiene                          Audit corrections + glossary (unused/duplicates/phonetic collisions)
          meetingscribe hygiene --apply                  Prune suggested terms (backup written first)
        """)
    }
}
