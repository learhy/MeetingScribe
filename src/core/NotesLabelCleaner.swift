import Foundation

/// Cleans SPEAKER_XX labels from the Summary and Notes sections of generated notes.
///
/// Replaces raw diarization labels with resolved names from the NameResolver,
/// or with a neutral "Speaker N" label when the speaker is truly unidentified.
///
/// This prevents raw labels from leaking into Bear notes (336 of 730 existing notes
/// had SPEAKER_XX in Summary/Notes sections).
struct NotesLabelCleaner {

    /// Regex pattern to match SPEAKER_XX labels (e.g. SPEAKER_00, SPEAKER_01)
    static let speakerLabelPattern = #"SPEAKER_\d+"#

    /// Replace SPEAKER_XX in summary/notes with resolved names or "Speaker N".
    ///
    /// - Parameters:
    ///   - text: The summary or notes text to clean.
    ///   - labelMap: Map from speaker label to canonical name (from NameResolver).
    /// - Returns: Cleaned text with SPEAKER_XX labels replaced.
    static func clean(_ text: String, labelMap: [String: CanonicalName]) -> String {
        guard let regex = try? NSRegularExpression(pattern: speakerLabelPattern, options: []) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        var result = text

        // We need to process matches from right to left to preserve indices
        let matches = regex.matches(in: text, range: range).reversed()

        for match in matches {
            guard let matchRange = Range(match.range, in: result) else { continue }
            let label = String(result[matchRange])

            // Find the replacement name
            let replacement: String
            if let canonical = labelMap[label] {
                replacement = canonical.displayName
            } else {
                replacement = CanonicalName.neutralLabel(for: label)
            }

            result.replaceSubrange(matchRange, with: replacement)
        }

        return result
    }

    /// Clean text using a simple label→String display name map (for backward compatibility).
    static func clean(_ text: String, displayNameMap: [String: String]) -> String {
        guard let regex = try? NSRegularExpression(pattern: speakerLabelPattern, options: []) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        var result = text
        let matches = regex.matches(in: text, range: range).reversed()

        for match in matches {
            guard let matchRange = Range(match.range, in: result) else { continue }
            let label = String(result[matchRange])

            let replacement: String
            if let name = displayNameMap[label] {
                replacement = name
            } else {
                replacement = CanonicalName.neutralLabel(for: label)
            }

            result.replaceSubrange(matchRange, with: replacement)
        }

        return result
    }

    /// Clean speaker labels from multiple text sections at once.
    static func clean(sections: [String], labelMap: [String: CanonicalName]) -> [String] {
        return sections.map { clean($0, labelMap: labelMap) }
    }
}