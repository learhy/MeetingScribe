import Foundation
import SQLite3

// MARK: - Data Models

struct MeetingParticipants {
    let myEmail: String
    let myFirstName: String
    let attendeeEmails: [String]
    let attendeeFirstNames: [String]
    
    /// Format participant information for LLM context injection
    func formatForLLMContext() -> String {
        var parts: [String] = []
        
        // Add "me" first
        if !myFirstName.isEmpty {
            parts.append("\(myFirstName) (me)")
        }
        
        // Add other attendees
        for name in attendeeFirstNames {
            if name != myFirstName && !name.isEmpty {
                parts.append(name)
            }
        }
        
        if parts.isEmpty {
            return ""
        }
        
        let participantList = parts.joined(separator: ", ")
        return """
        Meeting participants: \(participantList).
        When you see speaker labels like SPEAKER_00, SPEAKER_01, etc., try to identify who is speaking based on conversation context and attribute statements to the correct person when possible.
        """
    }
}

struct CalendarEvent {
    let recordId: Int
    let pathToDataFile: String
    let startDateUTC: Date
    let endDateUTC: Date
    let attendeeCount: Int
}

// MARK: - Calendar Participant Resolver

class CalendarParticipantResolver {
    private let logger = DualLogger(category: "CalendarParticipantResolver")
    private let config: ConfigManager
    
    // Default Outlook database path
    private static let defaultOutlookPath = "~/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile/Data/"
    
    init(config: ConfigManager = .shared) {
        self.config = config
    }
    
    /// Resolve meeting participants for a recording time window
    func resolveParticipants(recordingStart: Date, recordingEnd: Date) -> MeetingParticipants? {
        guard config.config.participants.enabled else {
            logger.info("Participant resolution disabled in config")
            return nil
        }
        
        let databasePath = getDatabasePath()
        
        // Get user's email first
        guard let myEmail = getUserEmail(databasePath: databasePath) else {
            logger.warning("Could not determine user email from Outlook")
            return nil
        }
        
        logger.info("User email: \(myEmail)")
        
        // Find matching calendar event
        guard let event = findMatchingCalendarEvent(
            recordingStart: recordingStart,
            recordingEnd: recordingEnd,
            databasePath: databasePath
        ) else {
            logger.info("No matching calendar event found for recording window")
            return nil
        }
        
        logger.info("Found matching event with \(event.attendeeCount) attendees")
        
        // Extract attendee emails from event file
        let eventFilePath = databasePath + event.pathToDataFile
        let attendeeEmails = extractAttendeesFromEventFile(path: eventFilePath)
        
        if attendeeEmails.isEmpty {
            logger.warning("Could not extract attendee emails from event file")
            return nil
        }
        
        logger.info("Extracted \(attendeeEmails.count) attendee emails")
        
        // Filter out "me" and derive first names
        let otherEmails = attendeeEmails.filter { $0.lowercased() != myEmail.lowercased() }
        let otherNames = otherEmails.map { Self.deriveFirstName(from: $0) }
        let myFirstName = Self.deriveFirstName(from: myEmail)
        
        return MeetingParticipants(
            myEmail: myEmail,
            myFirstName: myFirstName,
            attendeeEmails: otherEmails,
            attendeeFirstNames: otherNames
        )
    }
    
    // MARK: - Database Operations
    
    private func getDatabasePath() -> String {
        let configPath = config.config.participants.outlookDatabasePath
        if !configPath.isEmpty {
            let expanded = (configPath as NSString).expandingTildeInPath
            return expanded.hasSuffix("/") ? expanded : expanded + "/"
        }
        return (Self.defaultOutlookPath as NSString).expandingTildeInPath
    }
    
    private func getUserEmail(databasePath: String) -> String? {
        let dbPath = databasePath + "Outlook.sqlite"
        
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            logger.error("Failed to open Outlook database at \(dbPath)")
            return nil
        }
        defer { sqlite3_close(db) }
        
        let query = "SELECT Record_AccountUID FROM AccountsExchange LIMIT 1"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            logger.error("Failed to prepare user email query")
            return nil
        }
        defer { sqlite3_finalize(statement) }
        
        // The AccountsExchange table has the email as one of the columns
        // Based on our research, column index 5 contains the email
        let altQuery = "SELECT * FROM AccountsExchange LIMIT 1"
        var altStatement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, altQuery, -1, &altStatement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(altStatement) }
        
        if sqlite3_step(altStatement) == SQLITE_ROW {
            // Column 5 contains the email based on our research
            if let emailCString = sqlite3_column_text(altStatement, 5) {
                return String(cString: emailCString)
            }
        }
        
        return nil
    }
    
    private func findMatchingCalendarEvent(recordingStart: Date, recordingEnd: Date, databasePath: String) -> CalendarEvent? {
        let dbPath = databasePath + "Outlook.sqlite"
        
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            logger.error("Failed to open Outlook database")
            return nil
        }
        defer { sqlite3_close(db) }
        
        // Query for events that overlap with the recording window
        // Outlook stores dates as Mac Absolute Time (seconds since Jan 1, 2001)
        let macAbsoluteStart = recordingStart.timeIntervalSinceReferenceDate
        let macAbsoluteEnd = recordingEnd.timeIntervalSinceReferenceDate
        
        // Allow 5 minute buffer on either side for detection delays
        let buffer: TimeInterval = 5 * 60
        let adjustedStart = macAbsoluteStart - buffer
        let adjustedEnd = macAbsoluteEnd + buffer
        
        let query = """
            SELECT Record_RecordID, PathToDataFile, Calendar_StartDateUTC, Calendar_EndDateUTC, Calendar_AttendeeCount
            FROM CalendarEvents
            WHERE Calendar_AttendeeCount > 0
            AND Calendar_StartDateUTC <= ?
            AND Calendar_EndDateUTC >= ?
            ORDER BY Calendar_AttendeeCount DESC
            LIMIT 1
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            logger.error("Failed to prepare calendar query")
            return nil
        }
        defer { sqlite3_finalize(statement) }
        
        sqlite3_bind_double(statement, 1, adjustedEnd)
        sqlite3_bind_double(statement, 2, adjustedStart)
        
        if sqlite3_step(statement) == SQLITE_ROW {
            let recordId = Int(sqlite3_column_int(statement, 0))
            let pathToDataFile = String(cString: sqlite3_column_text(statement, 1))
            let startTimestamp = sqlite3_column_double(statement, 2)
            let endTimestamp = sqlite3_column_double(statement, 3)
            let attendeeCount = Int(sqlite3_column_int(statement, 4))
            
            let startDate = Date(timeIntervalSinceReferenceDate: startTimestamp)
            let endDate = Date(timeIntervalSinceReferenceDate: endTimestamp)
            
            return CalendarEvent(
                recordId: recordId,
                pathToDataFile: pathToDataFile,
                startDateUTC: startDate,
                endDateUTC: endDate,
                attendeeCount: attendeeCount
            )
        }
        
        return nil
    }
    
    private func extractAttendeesFromEventFile(path: String) -> [String] {
        let expandedPath = (path as NSString).expandingTildeInPath
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            logger.warning("Event file not found: \(expandedPath)")
            return []
        }
        
        // Use `strings` command to extract readable strings from binary file
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/strings")
        process.arguments = [expandedPath]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return []
            }
            
            return Self.extractEmails(from: output)
        } catch {
            logger.error("Failed to extract strings from event file: \(error.localizedDescription)")
            return []
        }
    }
    
    // MARK: - Static Helper Methods (exposed for testing)
    
    /// Extract first name from email address
    static func deriveFirstName(from email: String) -> String {
        guard !email.isEmpty else { return "" }
        
        // Get local part (before @)
        let localPart: String
        if let atIndex = email.firstIndex(of: "@") {
            localPart = String(email[..<atIndex])
        } else {
            localPart = email
        }
        
        // Split on . or _
        let parts = localPart.components(separatedBy: CharacterSet(charactersIn: "._"))
        
        guard let firstName = parts.first, !firstName.isEmpty else {
            return localPart.capitalized
        }
        
        // Remove trailing numbers and capitalize
        let cleaned = firstName.trimmingCharacters(in: .decimalDigits)
        return cleaned.isEmpty ? firstName.capitalized : cleaned.capitalized
    }
    
    /// Extract email addresses from raw string content
    static func extractEmails(from content: String) -> [String] {
        let emailPattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        
        guard let regex = try? NSRegularExpression(pattern: emailPattern, options: []) else {
            return []
        }
        
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, options: [], range: range)
        
        var emails = Set<String>()
        for match in matches {
            if let swiftRange = Range(match.range, in: content) {
                let email = String(content[swiftRange])
                emails.insert(email)
            }
        }
        
        return Array(emails)
    }
    
    /// Check if two time windows overlap
    static func timeWindowsOverlap(recordingStart: Date, recordingEnd: Date, eventStart: Date, eventEnd: Date) -> Bool {
        // Two intervals overlap if: start1 < end2 AND start2 < end1
        return recordingStart < eventEnd && eventStart < recordingEnd
    }
}
