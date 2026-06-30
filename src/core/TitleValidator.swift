import Foundation

/// Validates and repairs meeting note titles before they are sent to Bear.
///
/// Rejects LLM refusal text, empty strings, meta-sentences, and error text.
/// Falls back to calendar title → date-based title when the LLM output is unusable.
struct TitleValidator {

    // MARK: - Refusal / Error Patterns

    /// Patterns that indicate the LLM produced refusal/error text instead of a title.
    static let refusalPatterns: [String] = [
        "i don't see a transcript",
        "i'd be happy to help",
        "id be happy to help",
        "could you please provide",
        "once you share the transcript",
        "unable to generate",
        "meeting transcript correction request",
        "i dont see a transcript",
        "please provide the meeting transcript",
        "i cannot generate",
        "i can't generate",
        "no transcript provided",
        "transcript not found"
    ]

    /// Patterns indicating LLM meta-commentary rather than a real title.
    static let metaPatterns: [String] = [
        "here is the corrected transcript",
        "here is the meeting notes",
        "here are the meeting notes",
        "generated meeting notes",
        "corrected transcript:",
        "meeting notes:"
    ]

    // MARK: - Validation

    /// Returns a valid title or nil if the input is unusable.
    static func validate(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty or whitespace-only
        guard !trimmed.isEmpty else { return nil }

        let lowercased = trimmed.lowercased()

        // Check refusal patterns
        for pattern in refusalPatterns {
            if lowercased.contains(pattern) {
                return nil
            }
        }

        // Check meta patterns — these are not titles
        for pattern in metaPatterns {
            if lowercased.contains(pattern) {
                return nil
            }
        }

        // Check if the title is too long (likely a sentence, not a title)
        // Real titles should be under ~120 chars. Refusal sentences are usually 100+ chars.
        if trimmed.count > 120 {
            // Try to take just the first sentence if it's short enough
            if let firstPeriod = trimmed.firstIndex(of: ".") {
                let firstSentence = String(trimmed[..<firstPeriod])
                if firstSentence.count <= 80 && !firstSentence.isEmpty {
                    return sanitize(firstSentence)
                }
            }
            return nil
        }

        // Check if it looks like a sentence (contains sentence-like patterns)
        // A title shouldn't end with a period or contain multiple sentences
        if trimmed.hasSuffix(".") && trimmed.contains(" ") {
            // Single-word titles with periods are rare; multi-word ending in period is likely a sentence
            // But some titles like "Q3 Planning." are fine — check for sentence indicators
            let wordCount = trimmed.split(separator: " ").count
            if wordCount > 6 {
                return nil
            }
        }

        return sanitize(trimmed)
    }

    /// Sanitize a title: strip quotes, excessive whitespace, and truncate.
    private static func sanitize(_ title: String) -> String {
        let sanitized = title
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return String(sanitized.prefix(100))
    }

    // MARK: - Full Fallback Chain

    /// Full fallback chain: validate(input) ?? calendarTitle ?? "Meeting Notes - <date>"
    static func resolve(
        llmTitle: String?,
        calendarTitle: String?,
        date: Date
    ) -> String {
        // Try LLM title first
        if let llm = llmTitle, let validated = validate(llm) {
            return validated
        }

        // Fall back to calendar title
        if let calendar = calendarTitle, !calendar.isEmpty {
            return sanitize(calendar)
        }

        // Ultimate fallback: date-based title
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "Meeting Notes - \(formatter.string(from: date))"
    }

    // MARK: - Title Disambiguation

    /// Bare 1:1 pattern regex (e.g. "Dan/Anando 1:1", "Dan/Rachana 1:1")
    /// Matches: Word/Word 1:1 or Word/Word/Word 1:1
    static let bareOneOnOnePattern = #"^\w+/\w+(?:/\w+)?\s+1:1$"#

    /// Check if a title is a bare 1:1 pattern (like "Dan/Anando 1:1").
    static func isBareOneOnOnePattern(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let regex = try? NSRegularExpression(pattern: bareOneOnOnePattern, options: []) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            return regex.firstMatch(in: trimmed, range: range) != nil
        }
        return false
    }

    /// Append a topic disambiguator to a bare 1:1 pattern title.
    /// E.g. "Dan/Anando 1:1" + topic "PEDM vs Agentic Prioritization" → "Dan/Anando 1:1: PEDM vs Agentic Prioritization"
    ///
    /// If no topic is provided or the topic is empty, appends a date suffix instead.
    static func disambiguate(title: String, topic: String?, date: Date) -> String {
        guard isBareOneOnOnePattern(title) else {
            return title
        }

        if let topic = topic, !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleanTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            // Take just the first sentence/line of the topic for brevity
            let topicPrefix: String
            if let newlineIdx = cleanTopic.firstIndex(of: "\n") {
                topicPrefix = String(cleanTopic[..<newlineIdx])
            } else if let periodIdx = cleanTopic.firstIndex(of: ".") {
                topicPrefix = String(cleanTopic[..<periodIdx])
            } else {
                topicPrefix = cleanTopic
            }

            let truncated = String(topicPrefix.prefix(60))
            return "\(title): \(truncated)"
        }

        // No topic — append date for uniqueness
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return "\(title) - \(formatter.string(from: date))"
    }

    /// Extract a topic from a summary string (first meaningful sentence/line).
    static func extractTopic(from summary: String) -> String? {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Try first line
        let lines = trimmed.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let firstLine = lines.first else { return nil }

        // Strip markdown bullet points and formatting
        let cleaned = firstLine
            .replacingOccurrences(of: "^\\s*[-*]\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return nil }

        // Take first sentence
        if let periodIdx = cleaned.firstIndex(of: ".") {
            let firstSentence = String(cleaned[..<periodIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            return firstSentence.isEmpty ? nil : firstSentence
        }

        return cleaned
    }
}