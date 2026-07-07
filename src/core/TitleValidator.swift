import Foundation

/// Validates and repairs generated note titles before they go to Bear.
/// Rejects LLM refusal text, empty strings, and meta-sentences.
struct TitleValidator {

    /// Patterns that indicate LLM refusal or error text (should not be a title).
    static let refusalPatterns = [
        "i don't see a transcript",
        "i'd be happy to help",
        "id be happy to help",
        "could you please provide",
        "once you share the transcript",
        "unable to generate",
        "meeting transcript correction request",
        "please provide the meeting transcript",
        "i don't have access to",
        "i cannot generate",
        "i'm unable to",
        "im unable to"
    ]

    /// Bare 1:1 title pattern: "Dan/X 1:1" or "Dan / X 1:1"
    static let bareOneOnOnePattern = #"^\w+\s*/\s*\w+\s+1:1$"#

    /// Validate a title — returns the cleaned title if valid, nil if unusable.
    static func validate(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty or whitespace-only
        guard !trimmed.isEmpty else { return nil }

        // Too short to be meaningful
        guard trimmed.count >= 3 else { return nil }

        // Check refusal patterns (case-insensitive)
        let lowercased = trimmed.lowercased()
        for pattern in refusalPatterns {
            if lowercased.contains(pattern) {
                return nil
            }
        }

        // Check if it looks like a sentence (ends with period and is long)
        // A title shouldn't be a full sentence
        if trimmed.hasSuffix(".") && trimmed.count > 60 {
            return nil
        }

        // Strip surrounding quotes
        var cleaned = trimmed
        if (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"")) ||
           (cleaned.hasPrefix("'") && cleaned.hasSuffix("'")) {
            cleaned = String(cleaned.dropFirst().dropLast())
        }

        // Truncate to 100 chars at word boundary
        if cleaned.count > 100 {
            let prefix = String(cleaned.prefix(100))
            if let lastSpace = prefix.lastIndex(of: " ") {
                cleaned = String(cleaned[..<lastSpace])
            } else {
                cleaned = prefix
            }
        }

        return cleaned.isEmpty ? nil : cleaned
    }

    /// Full fallback chain: validate(llmTitle) → calendarTitle → date-based title.
    static func resolve(
        llmTitle: String?,
        calendarTitle: String?,
        date: Date
    ) -> String {
        // Try LLM title first (if calendar title is empty)
        if let calTitle = calendarTitle, !calTitle.isEmpty {
            // Calendar title is primary — but still validate it
            if let validated = validate(calTitle) {
                return validated
            }
        }

        // Try LLM-generated title
        if let llm = llmTitle, let validated = validate(llm) {
            return validated
        }

        // Fall back to calendar title even if it didn't pass strict validation
        if let calTitle = calendarTitle, !calTitle.isEmpty {
            let trimmed = calTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        // Final fallback: date-based title
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "Meeting Notes - \(formatter.string(from: date))"
    }

    /// Disambiguate a bare 1:1 pattern title by appending a topic.
    /// "Dan/Anando 1:1" + topic "PEDM vs Agentic" → "Dan/Anando 1:1: PEDM vs Agentic"
    /// If no topic available, append the date for uniqueness.
    static func disambiguate(title: String, topic: String?, date: Date) -> String {
        let lowerTitle = title.lowercased()

        // Check if it matches the bare 1:1 pattern
        guard let regex = try? NSRegularExpression(pattern: bareOneOnOnePattern, options: [.caseInsensitive]),
              regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil else {
            // Not a bare pattern — return as-is
            return title
        }

        // If we have a topic, append it
        if let topic = topic, !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleanTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            // Take first sentence or first ~80 chars of the topic
            let topicPrefix: String
            if let firstPeriod = cleanTopic.firstIndex(of: ".") {
                topicPrefix = String(cleanTopic[..<firstPeriod])
            } else if cleanTopic.count > 80 {
                let prefix = String(cleanTopic.prefix(80))
                if let lastSpace = prefix.lastIndex(of: " ") {
                    topicPrefix = String(cleanTopic[..<lastSpace])
                } else {
                    topicPrefix = prefix
                }
            } else {
                topicPrefix = cleanTopic
            }

            return "\(title): \(topicPrefix)"
        }

        // No topic — append date for uniqueness
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "\(title) - \(formatter.string(from: date))"
    }
}