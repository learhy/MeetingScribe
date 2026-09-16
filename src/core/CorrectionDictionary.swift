import Foundation

/// P1-1: Edit-driven dictionary flywheel (manual-first per Dan's Q4 decision).
///
/// Persists wrong→right correction mappings to a local JSON dictionary at
/// `~/.meetingscribe/corrections.json` (git-ignored, alongside config). Each
/// entry is keyed by the wrong term and records source and timestamp.
///
/// The accumulated mappings are consumed by:
///   (a) RosterBuilder.buildPrompt (P0-3) via the `corrections:` parameter —
///       highest-priority tier of the Whisper biasing prompt;
///   (b) TranscriptPostProcessor — injected as a TEACH CORRECTIONS section
///       alongside KNOWN PEOPLE (see formatCorrections).
///
/// Auto-capture from Bear-note edits is v2 (plan §5 Q4): gated on ≥20 trusted
/// entries + harness wins. v1 is the manual teach path only.
struct CorrectionDictionary {

    /// One wrong→right mapping.
    struct Entry: Codable, Equatable {
        let wrong: String
        let right: String
        /// "manual" for v1; future sources: "bear_edit", "speaker_confirm".
        let source: String
        /// Unix timestamp of the last time this mapping was taught/confirmed.
        let updatedAt: Double
    }

    /// The on-disk dictionary shape.
    struct File: Codable {
        var version: Int = 1
        var entries: [Entry] = []
    }

    static let sourceManual = "manual"

    // MARK: - Path helpers

    /// Default store location: ~/.meetingscribe/corrections.json
    static func defaultPath(homeDirectory: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".meetingscribe")
            .appendingPathComponent("corrections.json")
    }

    // MARK: - Parsing the teach argument

    /// Parsed result of a teach argument like "Ratchna->Rachana".
    enum TeachParseError: Error, Equatable {
        case missingSeparator
        case emptySide
    }

    /// Parse a "wrong->right" (or "wrong=>right", "wrong=right") teach argument.
    /// Both sides are trimmed; empty sides are rejected.
    static func parseTeachArgument(_ argument: String) throws -> (wrong: String, right: String) {
        // Support the common arrow spellings; "->" first so it is not consumed
        // by a partial "=>" match (they don't overlap, but keep it explicit).
        let separators = ["->", "=>", "→", "=gt;", "="]
        for separator in separators {
            if let range = argument.range(of: separator) {
                let wrong = String(argument[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(argument[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !wrong.isEmpty, !right.isEmpty else { throw TeachParseError.emptySide }
                return (wrong, right)
            }
        }
        throw TeachParseError.missingSeparator
    }

    // MARK: - Store I/O

    /// Load the dictionary from disk. Missing file → empty dictionary
    /// (not an error — first run has no entries yet).
    static func load(path: URL) -> File {
        guard let data = try? Data(contentsOf: path),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return File()
        }
        return file
    }

    /// Save the dictionary atomically, creating the parent directory if needed.
    @discardableResult
    static func save(_ file: File, path: URL) -> Bool {
        let dir = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: path, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Add (or update) a wrong→right mapping. Re-teaching the same wrong term
    /// updates the right side, source, and timestamp (last write wins — the
    /// user's most recent correction is the most trusted).
    /// - Returns: The updated file.
    static func add(
        file: File,
        wrong: String,
        right: String,
        source: String = CorrectionDictionary.sourceManual,
        now: Double = Date().timeIntervalSince1970
    ) -> File {
        var updated = file
        let wrongKey = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let rightValue = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrongKey.isEmpty, !rightValue.isEmpty else { return updated }

        if let index = updated.entries.firstIndex(where: { $0.wrong == wrongKey }) {
            updated.entries[index] = Entry(wrong: wrongKey, right: rightValue, source: source, updatedAt: now)
        } else {
            updated.entries.append(Entry(wrong: wrongKey, right: rightValue, source: source, updatedAt: now))
        }
        return updated
    }

    /// Remove a mapping by wrong term. Returns the updated file, or nil if not found.
    static func remove(file: File, wrong: String) -> File? {
        let wrongKey = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = file.entries.firstIndex(where: { $0.wrong == wrongKey }) else {
            return nil
        }
        var updated = file
        updated.entries.remove(at: index)
        return updated
    }

    // MARK: - Consumption

    /// Flat wrong→right map for consumers (RosterBuilder, post-processor).
    /// Entries whose right side equals the wrong side (no-ops) are excluded.
    static func correctionsMap(file: File) -> [String: String] {
        var map: [String: String] = [:]
        for entry in file.entries where entry.wrong.lowercased() != entry.right.lowercased() {
            map[entry.wrong] = entry.right
        }
        return map
    }

    /// Format corrections for injection into an LLM prompt (post-processor).
    static func formatCorrections(_ corrections: [String: String]) -> String {
        guard !corrections.isEmpty else { return "" }
        let pairs = corrections
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key) → \($0.value)" }
            .joined(separator: " | ")
        return """

        ## USER-TAUGHT CORRECTIONS (apply these exactly: the left name is a known ASR error, replace it with the right name wherever it appears)
        \(pairs)

        """
    }

    // MARK: - List/export rendering (dictionary subcommand)

    /// Render the dictionary as human-readable text (list subcommand).
    static func renderList(_ file: File) -> String {
        guard !file.entries.isEmpty else {
            return "No corrections taught yet. Teach one with:\n  meetingscribe teach \"WrongName->RightName\""
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        dateFormatter.timeZone = TimeZone.current
        let sorted = file.entries.sorted { $0.wrong.lowercased() < $1.wrong.lowercased() }
        let lines = sorted.map { entry in
            let date = dateFormatter.string(from: Date(timeIntervalSince1970: entry.updatedAt))
            return "\(entry.wrong) → \(entry.right)   [\(entry.source), \(date)]"
        }
        return lines.joined(separator: "\n")
    }

    /// Render the dictionary as JSON (export subcommand).
    static func renderJSON(_ file: File) -> String {
        let map = correctionsMap(file: file)
        let sorted = map.sorted { $0.key.lowercased() < $1.key.lowercased() }
        let object = Dictionary(uniqueKeysWithValues: sorted)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
