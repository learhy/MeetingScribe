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

// MARK: - Protocols for Dependency Injection

/// Protocol for database operations - allows mocking in tests
protocol OutlookDatabaseProtocol {
    func getUserEmail() -> String?
    func findCalendarEvent(overlapping start: Date, end: Date) -> CalendarEvent?
}

/// Protocol for file operations - allows mocking in tests  
protocol EventFileReaderProtocol {
    func extractAttendeeEmails(fromEventFile path: String) -> [String]
}

// MARK: - Production Implementations

/// Real SQLite database reader for Outlook
class OutlookSQLiteDatabase: OutlookDatabaseProtocol {
    private let databasePath: String
    
    init(databasePath: String) {
        self.databasePath = databasePath
    }
    
    func getUserEmail() -> String? {
        let dbPath = databasePath + "Outlook.sqlite"
        
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }
        
        // Query all columns to get email at index 5
        let query = "SELECT * FROM AccountsExchange LIMIT 1"
        var statement: OpaquePointer?
        
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        
        if sqlite3_step(statement) == SQLITE_ROW {
            if let emailCString = sqlite3_column_text(statement, 5) {
                return String(cString: emailCString)
            }
        }
        
        return nil
    }
    
    func findCalendarEvent(overlapping start: Date, end: Date) -> CalendarEvent? {
        let dbPath = databasePath + "Outlook.sqlite"
        
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }
        
        // Outlook stores dates as Mac Absolute Time (seconds since Jan 1, 2001)
        let macAbsoluteStart = start.timeIntervalSinceReferenceDate
        let macAbsoluteEnd = end.timeIntervalSinceReferenceDate
        
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
}

/// Real file reader that uses /usr/bin/strings to extract emails from binary event files
class OutlookEventFileReader: EventFileReaderProtocol {
    private let basePath: String
    
    init(basePath: String) {
        self.basePath = basePath
    }
    
    func extractAttendeeEmails(fromEventFile relativePath: String) -> [String] {
        let fullPath = basePath + relativePath
        let expandedPath = (fullPath as NSString).expandingTildeInPath
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return []
        }
        
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
            
            return CalendarParticipantResolver.extractEmails(from: output)
        } catch {
            return []
        }
    }
}

// MARK: - Calendar Participant Resolver

class CalendarParticipantResolver {
    private let logger = DualLogger(category: "CalendarParticipantResolver")
    private let database: OutlookDatabaseProtocol
    private let fileReader: EventFileReaderProtocol
    private let isEnabled: Bool
    
    // Default Outlook database path
    static let defaultOutlookPath = "~/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile/Data/"
    
    /// Production initializer using ConfigManager
    convenience init(config: ConfigManager = .shared) {
        let configPath = config.config.participants.outlookDatabasePath
        let databasePath: String
        if !configPath.isEmpty {
            let expanded = (configPath as NSString).expandingTildeInPath
            databasePath = expanded.hasSuffix("/") ? expanded : expanded + "/"
        } else {
            databasePath = (Self.defaultOutlookPath as NSString).expandingTildeInPath
        }
        
        self.init(
            database: OutlookSQLiteDatabase(databasePath: databasePath),
            fileReader: OutlookEventFileReader(basePath: databasePath),
            isEnabled: config.config.participants.enabled
        )
    }
    
    /// Testable initializer with dependency injection
    init(database: OutlookDatabaseProtocol, fileReader: EventFileReaderProtocol, isEnabled: Bool = true) {
        self.database = database
        self.fileReader = fileReader
        self.isEnabled = isEnabled
    }
    
    /// Resolve meeting participants for a recording time window
    func resolveParticipants(recordingStart: Date, recordingEnd: Date) -> MeetingParticipants? {
        guard isEnabled else {
            logger.info("Participant resolution disabled in config")
            return nil
        }
        
        // Get user's email first
        guard let myEmail = database.getUserEmail() else {
            logger.warning("Could not determine user email from Outlook")
            return nil
        }
        
        logger.info("User email: \(myEmail)")
        
        // Find matching calendar event
        guard let event = database.findCalendarEvent(overlapping: recordingStart, end: recordingEnd) else {
            logger.info("No matching calendar event found for recording window")
            return nil
        }
        
        logger.info("Found matching event with \(event.attendeeCount) attendees")
        
        // Extract attendee emails from event file
        let attendeeEmails = fileReader.extractAttendeeEmails(fromEventFile: event.pathToDataFile)
        
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
