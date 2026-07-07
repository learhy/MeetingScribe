import Foundation

/// Cleans SPEAKER_XX labels from generated notes sections (Summary, Notes).
/// Replaces them with resolved names from NameResolver, or "Speaker N" if unidentified.
struct NotesLabelCleaner {

    /// Regex pattern for matching SPEAKER_XX labels (e.g., SPEAKER_00, SPEAKER_01)
    static let speakerLabelPattern = #"SPEAKER_(\d{2})"#

    /// Replace SPEAKER_XX labels in text with resolved names or "Speaker N".
    ///
    /// - Parameters:
    ///   - text: The summary or notes text to clean
    ///   - labelMap: Resolved canonical names by speaker label
    /// - Returns: Cleaned text with SPEAKER_XX replaced by real names
    static func clean(_ text: String, labelMap: [String: CanonicalName]) -> String {
        guard let regex = try? NSRegularExpression(pattern: speakerLabelPattern, options: []) else {
            return text
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        // Process matches in reverse to maintain index validity
        var result = text
        for match in matches.reversed() {
            let matchRange = match.range
            let fullLabel = nsText.substring(with: matchRange)

            // Extract the number (e.g., "00" from "SPEAKER_00")
            let numberRange = match.range(at: 1)
            let numberStr = nsText.substring(with: numberRange)

            // Try to find a resolved name
            if let canonical = labelMap[fullLabel] {
                result = (result as NSString).replacingCharacters(
                    in: matchRange,
                    with: canonical.displayName
                )
            } else {
                // No resolved name — use "Speaker N" (human-readable)
                if let num = Int(numberStr) {
                    result = (result as NSString).replacingCharacters(
                        in: matchRange,
                        with: "Speaker \(num)"
                    )
                } else {
                    // Fallback: just use the number as-is
                    result = (result as NSString).replacingCharacters(
                        in: matchRange,
                        with: "Speaker \(numberStr)"
                    )
                }
            }
        }

        return result
    }

    /// Clean both summary and notes sections.
    static func cleanSummaryAndNotes(
        summary: String,
        notes: String,
        labelMap: [String: CanonicalName]
    ) -> (summary: String, notes: String) {
        return (
            summary: clean(summary, labelMap: labelMap),
            notes: clean(notes, labelMap: labelMap)
        )
    }
}