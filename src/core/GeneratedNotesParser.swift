import Foundation

struct GeneratedNotesParser {
    struct SplitResult {
        let summary: String
        let notes: String
    }

    static func split(_ raw: String) -> SplitResult {
        let cleaned = stripLeadingMeetingNotesTitle(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else {
            return SplitResult(summary: "", notes: "")
        }

        let lines = cleaned
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard let summaryHeadingIndexAndLevel = findHeading(named: "summary", in: lines) else {
            // No explicit summary section; keep all content as notes.
            return SplitResult(summary: "", notes: cleaned)
        }

        let (summaryHeadingIndex, summaryHeadingLevel) = summaryHeadingIndexAndLevel
        let summaryEndIndex = findEndOfSection(
            startingAfter: summaryHeadingIndex,
            sectionLevel: summaryHeadingLevel,
            in: lines
        )

        let summaryLines = Array(lines[(summaryHeadingIndex + 1)..<summaryEndIndex])
        let summaryText = summaryLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var remainingLines: [String] = []
        remainingLines.reserveCapacity(lines.count)

        for (i, line) in lines.enumerated() {
            // Drop the summary header + its body from the notes.
            if i >= summaryHeadingIndex && i < summaryEndIndex { continue }
            remainingLines.append(line)
        }

        // Trim leading blank lines after section removal.
        while let first = remainingLines.first,
              first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remainingLines.removeFirst()
        }

        let notesText = remainingLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return SplitResult(summary: summaryText, notes: notesText)
    }

    // MARK: - Helpers

    private static func stripLeadingMeetingNotesTitle(_ raw: String) -> String {
        var lines = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        // First, strip any LLM preamble text (e.g., "Generated meeting notes:", "Here are the meeting notes:", etc.)
        // Keep stripping until we find real content
        let preamblePatterns = [
            "generated meeting notes",
            "here are the meeting notes",
            "here are your meeting notes",
            "meeting notes:",
            "**meeting date:**",
            "meeting date:",
            "[date fr"  // Incomplete date patterns
        ]
        
        while let firstNonEmptyIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            let trimmed = lines[firstNonEmptyIndex].trimmingCharacters(in: .whitespaces).lowercased()
            
            let isPreamble = preamblePatterns.contains { pattern in
                trimmed.contains(pattern)
            }
            
            if isPreamble {
                lines.remove(at: firstNonEmptyIndex)
                continue
            }
            
            break
        }

        // Remove duplicate headers and preamble content anywhere in the document
        var indicesToRemove: Set<Int> = []
        var lastHeadingIndex: Int? = nil
        var lastHeadingText: String? = nil
        
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("#") {
                let (_, headingText) = parseHeadingLine(trimmed)
                let normalizedHeading = headingText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                
                if let lastIdx = lastHeadingIndex,
                   let lastText = lastHeadingText,
                   normalizedHeading == lastText {
                    // Found duplicate heading - mark the earlier occurrence and content between for removal
                    for j in lastIdx..<i {
                        indicesToRemove.insert(j)
                    }
                }
                
                lastHeadingIndex = i
                lastHeadingText = normalizedHeading
            } else if !trimmed.isEmpty {
                // Check if this line is preamble content that should be removed
                let isStillPreamble = preamblePatterns.contains { pattern in
                    trimmed.lowercased().contains(pattern)
                }
                
                if isStillPreamble {
                    // Mark preamble line for removal
                    indicesToRemove.insert(i)
                } else {
                    // Real content found - stop tracking heading for duplicates
                    lastHeadingIndex = nil
                    lastHeadingText = nil
                }
            }
        }
        
        // Remove marked lines
        lines = lines.enumerated().filter { !indicesToRemove.contains($0.offset) }.map { $0.element }

        // Then, handle markdown heading titles as before
        guard let firstNonEmptyIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return raw
        }

        let trimmed = lines[firstNonEmptyIndex].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else {
            return lines.joined(separator: "\n")
        }

        let (_, headingText) = parseHeadingLine(trimmed)
        if headingText.lowercased().hasPrefix("meeting notes") {
            lines.remove(at: firstNonEmptyIndex)

            // Remove one blank line immediately following the title.
            if firstNonEmptyIndex < lines.count,
               lines[firstNonEmptyIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.remove(at: firstNonEmptyIndex)
            }

            return lines.joined(separator: "\n")
        }

        return lines.joined(separator: "\n")
    }

    private static func findHeading(named name: String, in lines: [String]) -> (index: Int, level: Int)? {
        let target = name.lowercased()

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }

            let (level, headingText) = parseHeadingLine(trimmed)
            guard level > 0 else { continue }

            if headingText.lowercased() == target {
                return (i, level)
            }
        }

        return nil
    }

    private static func findEndOfSection(startingAfter index: Int, sectionLevel: Int, in lines: [String]) -> Int {
        guard sectionLevel > 0 else { return lines.count }

        if index + 1 >= lines.count {
            return lines.count
        }

        for j in (index + 1)..<lines.count {
            let trimmed = lines[j].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }

            let (level, _) = parseHeadingLine(trimmed)
            if level > 0 && level <= sectionLevel {
                return j
            }
        }

        return lines.count
    }

    private static func parseHeadingLine(_ trimmedLine: String) -> (level: Int, text: String) {
        let hashes = trimmedLine.prefix(while: { $0 == "#" })
        let level = hashes.count
        let text = trimmedLine
            .dropFirst(level)
            .trimmingCharacters(in: .whitespaces)
        return (level, text)
    }
}
