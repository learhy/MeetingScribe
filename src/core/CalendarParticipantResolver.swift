import Foundation
import SQLite3

// MARK: - Data Models

struct Participant {
    let email: String
    let firstName: String
    let isMe: Bool
    let inferredRole: String?  // "remote", "local", or nil if uncertain
}

struct MeetingParticipants {
    let meetingTitle: String?  // Calendar event title (nil if not available)
    let myEmail: String
    let myFirstName: String
    let attendeeEmails: [String]
    let attendeeFirstNames: [String]
    let participants: [Participant]  // Enhanced mapping with roles
    
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
        
        // Build diarization guidance based on participant count and roles
        var diarizationGuidance = ""
        
        // Find "me" and "remote" participants
        let meParticipant = participants.first { $0.isMe }
        let remoteParticipants = participants.filter { !$0.isMe }
        
        if participants.count == 2, let me = meParticipant, let remote = remoteParticipants.first {
            // 1:1 call - provide explicit mapping guidance
            diarizationGuidance = """
            
            
            Diarization speaker mapping guidance:
            - This appears to be a 1:1 conversation between \(me.firstName) (local user) and \(remote.firstName) (remote participant).
            - Attempt to intelligently infer which diarized speaker (SPEAKER_00, SPEAKER_01, etc.) corresponds to the local user based on context clues in the conversation.
            - DO NOT assume SPEAKER_00 is always the local user - this varies by audio setup.
            - Look for context like "I think...", "from my perspective...", or references that indicate the speaker's role.
            - Once you've identified which speaker is likely the local user, map: \(me.firstName) = that speaker, \(remote.firstName) = the other speaker.
            """
        } else if participants.count > 2 {
            // Group call - provide general guidance
            diarizationGuidance = """
            
            
            Diarization speaker mapping guidance:
            - This is a group conversation with \(participants.count) participants including \(meParticipant?.firstName ?? "the local user") (local) and \(remoteParticipants.count) remote participant(s).
            - Attempt to map diarized speakers (SPEAKER_00, SPEAKER_01, etc.) to actual participants based on conversation context.
            - DO NOT assume SPEAKER_00 is the local user - analyze the content to infer speaker identity.
            - If you cannot confidently map a speaker, you may provide likely mappings with a caveat about uncertainty.
            - Participant list with emails for reference: \(participants.map { "\($0.firstName) <\($0.email)>\(($0.isMe ? " (me)" : ""))" }.joined(separator: ", ")).
            """
        } else if let me = meParticipant {
            // Solo meeting (only local user detected)
            diarizationGuidance = """
            
            
            Diarization speaker mapping guidance:
            - Only the local user (\(me.firstName)) was detected in the calendar event.
            - Any diarized speakers are likely all \(me.firstName), unless other voices are present in the audio.
            """
        }
        
        return """
        Meeting participants: \(participantList).\(diarizationGuidance)
        
        When you see speaker labels like SPEAKER_00, SPEAKER_01, etc., use the guidance above to identify who is speaking and attribute statements to the correct person when possible.
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
        
        // Outlook stores dates as minutes since OLE epoch (Jan 1, 1601)
        // Convert Swift Date to OLE minutes
        let oleEpoch = Date(timeIntervalSince1970: -11644473600) // Jan 1, 1601 in Unix time
        let oleMinutesStart = start.timeIntervalSince(oleEpoch) / 60.0
        let oleMinutesEnd = end.timeIntervalSince(oleEpoch) / 60.0
        
        // Allow 5 minute buffer on either side for detection delays
        let bufferMinutes: Double = 5.0
        let adjustedStart = oleMinutesStart - bufferMinutes
        let adjustedEnd = oleMinutesEnd + bufferMinutes
        
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
            let startOleMinutes = sqlite3_column_double(statement, 2)
            let endOleMinutes = sqlite3_column_double(statement, 3)
            let attendeeCount = Int(sqlite3_column_int(statement, 4))
            
            // Convert OLE minutes back to Date
            let startDate = oleEpoch.addingTimeInterval(startOleMinutes * 60.0)
            let endDate = oleEpoch.addingTimeInterval(endOleMinutes * 60.0)
            
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
    private let logger = DualLogger(category: "OutlookEventFileReader")
    
    init(basePath: String) {
        self.basePath = basePath
    }
    
    func extractAttendeeEmails(fromEventFile relativePath: String) -> [String] {
        let fullPath = basePath + relativePath
        let expandedPath = (fullPath as NSString).expandingTildeInPath
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            logger.warning("Event file does not exist: \(expandedPath)")
            return []
        }
        
        // Check file size for sanity
        if let attributes = try? FileManager.default.attributesOfItem(atPath: expandedPath),
           let fileSize = attributes[.size] as? UInt64 {
            if fileSize == 0 {
                logger.warning("Event file is empty (0 bytes): \(expandedPath)")
                return []
            }
        }
        
        // Try standard strings extraction first
        var emails = runStringsCommand(path: expandedPath, arguments: [expandedPath])
        
        // If empty, retry with more aggressive options
        if emails.isEmpty {
            logger.debug("Standard strings extraction returned empty, retrying with -a -n 4")
            emails = runStringsCommand(path: expandedPath, arguments: ["-a", "-n", "4", expandedPath])
        }
        
        return emails
    }
    
    private func runStringsCommand(path: String, arguments: [String]) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/strings")
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                logger.warning("Failed to decode strings output as UTF-8")
                return []
            }
            
            return CalendarParticipantResolver.extractEmails(from: output)
        } catch {
            logger.error("Failed to run strings command: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - Calendar Participant Resolver

class CalendarParticipantResolver {
    private let logger = DualLogger(category: "CalendarParticipantResolver")
    private let database: OutlookDatabaseProtocol?
    private let fileReader: EventFileReaderProtocol?
    private let eventKitReader: EventKitCalendarReaderProtocol?
    private let calendarSource: String
    private let isEnabled: Bool
    private let debugLogging: Bool
    
    // Default Outlook database path
    static let defaultOutlookPath = "~/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile/Data/"
    
    /// Production initializer using ConfigManager
    convenience init(config: ConfigManager = .shared) {
        let participantConfig = config.config.participants
        let calendarSource = participantConfig.calendarSource
        
        // Initialize Outlook database if needed
        var database: OutlookDatabaseProtocol? = nil
        var fileReader: EventFileReaderProtocol? = nil
        
        if calendarSource == "outlook" || calendarSource == "both" {
            let configPath = participantConfig.outlookDatabasePath
            let databasePath: String
            if !configPath.isEmpty {
                let expanded = (configPath as NSString).expandingTildeInPath
                databasePath = expanded.hasSuffix("/") ? expanded : expanded + "/"
            } else {
                databasePath = (Self.defaultOutlookPath as NSString).expandingTildeInPath
            }
            database = OutlookSQLiteDatabase(databasePath: databasePath)
            fileReader = OutlookEventFileReader(basePath: databasePath)
        }
        
        // Initialize EventKit reader if needed
        var eventKitReader: EventKitCalendarReaderProtocol? = nil
        if calendarSource == "eventkit" || calendarSource == "both" {
            eventKitReader = EventKitCalendarReader(
                targetCalendarNames: [participantConfig.eventKitCalendarName],
                debugLogging: participantConfig.debugLogging
            )
        }
        
        self.init(
            database: database,
            fileReader: fileReader,
            eventKitReader: eventKitReader,
            calendarSource: calendarSource,
            isEnabled: participantConfig.enabled,
            debugLogging: participantConfig.debugLogging
        )
    }
    
    /// Testable initializer with dependency injection
    init(
        database: OutlookDatabaseProtocol?,
        fileReader: EventFileReaderProtocol?,
        eventKitReader: EventKitCalendarReaderProtocol? = nil,
        calendarSource: String = "eventkit",
        isEnabled: Bool = true,
        debugLogging: Bool = false
    ) {
        self.database = database
        self.fileReader = fileReader
        self.eventKitReader = eventKitReader
        self.calendarSource = calendarSource
        self.isEnabled = isEnabled
        self.debugLogging = debugLogging
    }
    
    /// Resolve meeting participants for a recording time window
    func resolveParticipants(recordingStart: Date, recordingEnd: Date) -> MeetingParticipants? {
        guard isEnabled else {
            logger.info("Participant resolution disabled in config")
            return nil
        }
        
        // Try EventKit first if configured
        if (calendarSource == "eventkit" || calendarSource == "both"), let eventKitReader = eventKitReader {
            if let result = resolveFromEventKit(reader: eventKitReader, recordingStart: recordingStart, recordingEnd: recordingEnd) {
                return result
            }
            
            // If "both" mode, fall through to Outlook
            if calendarSource == "eventkit" {
                return nil
            }
        }
        
        // Try Outlook if configured
        if (calendarSource == "outlook" || calendarSource == "both"), let database = database, let fileReader = fileReader {
            return resolveFromOutlook(database: database, fileReader: fileReader, recordingStart: recordingStart, recordingEnd: recordingEnd)
        }
        
        logger.warning("No calendar source configured or available")
        return nil
    }
    
    // MARK: - EventKit Resolution
    
    private func resolveFromEventKit(reader: EventKitCalendarReaderProtocol, recordingStart: Date, recordingEnd: Date) -> MeetingParticipants? {
        logger.info("Attempting to resolve participants from EventKit...")
        
        guard let meetingInfo = reader.findMeeting(overlapping: recordingStart, end: recordingEnd) else {
            logger.info("No matching EventKit calendar event found")
            return nil
        }
        
        logger.info("✓ Found EventKit meeting: \(meetingInfo.title)")
        
        // Build participants from EventKit attendees
        var participants: [Participant] = []
        var myEmail = ""
        var myFirstName = ""
        
        for attendee in meetingInfo.attendees {
            let firstName = attendee.name ?? Self.deriveFirstName(from: attendee.email)
            let isMe = attendee.isOrganizer  // Current user is typically the organizer in their own calendar
            
            let participant = Participant(
                email: attendee.email,
                firstName: firstName,
                isMe: isMe,
                inferredRole: isMe ? "local" : (meetingInfo.attendees.count == 2 ? "remote" : nil)
            )
            participants.append(participant)
            
            if isMe {
                myEmail = attendee.email
                myFirstName = firstName
            }
        }
        
        // If we couldn't identify "me", use the first attendee as a fallback
        if myEmail.isEmpty && !participants.isEmpty {
            myEmail = participants[0].email
            myFirstName = participants[0].firstName
        }
        
        let otherParticipants = participants.filter { !$0.isMe }
        let otherEmails = otherParticipants.map { $0.email }
        let otherNames = otherParticipants.map { $0.firstName }
        
        logger.info("✓ Resolved \(participants.count) participant(s) from EventKit with title: \(meetingInfo.title)")
        
        if debugLogging {
            logger.debug("Meeting title: \(meetingInfo.title)")
            logger.debug("Participants:")
            for p in participants {
                logger.debug("  - \(p.firstName) <\(p.email)>: isMe=\(p.isMe)")
            }
        }
        
        return MeetingParticipants(
            meetingTitle: meetingInfo.title,
            myEmail: myEmail,
            myFirstName: myFirstName,
            attendeeEmails: otherEmails,
            attendeeFirstNames: otherNames,
            participants: participants
        )
    }
    
    // MARK: - Outlook Resolution
    
    private func resolveFromOutlook(database: OutlookDatabaseProtocol, fileReader: EventFileReaderProtocol, recordingStart: Date, recordingEnd: Date) -> MeetingParticipants? {
        logger.info("Attempting to resolve participants from Outlook...")
        
        // Get user's email first
        guard let myEmail = database.getUserEmail() else {
            logger.warning("Could not determine user email from Outlook database")
            return nil
        }
        
        logger.info("✓ Successfully retrieved user email from Outlook")
        if debugLogging {
            logger.debug("User email: \(myEmail)")
        }
        
        // Find matching calendar event
        guard let event = database.findCalendarEvent(overlapping: recordingStart, end: recordingEnd) else {
            logger.info("No matching calendar event found for recording window (\(Self.formatDate(recordingStart)) - \(Self.formatDate(recordingEnd)))")
            return nil
        }
        
        logger.info("✓ Found matching calendar event (recordId=\(event.recordId), attendeeCount=\(event.attendeeCount))")
        if debugLogging {
            logger.debug("Event details: start=\(Self.formatDate(event.startDateUTC)), end=\(Self.formatDate(event.endDateUTC)), path=\(event.pathToDataFile)")
        }
        
        // Extract attendee emails from event file with timing
        let extractionStart = Date()
        let attendeeEmails = fileReader.extractAttendeeEmails(fromEventFile: event.pathToDataFile)
        let extractionDuration = Date().timeIntervalSince(extractionStart)
        
        if attendeeEmails.isEmpty {
            logger.warning("✗ Could not extract attendee emails from event file (\(event.pathToDataFile)) after \(String(format: "%.2f", extractionDuration))s")
            return nil
        }
        
        logger.info("✓ Extracted \(attendeeEmails.count) attendee email(s) in \(String(format: "%.2f", extractionDuration))s")
        if debugLogging {
            logger.debug("Extracted emails: \(attendeeEmails.joined(separator: ", "))")
        }
        
        // Build participant mapping with isMe and inferredRole
        let myFirstName = Self.deriveFirstName(from: myEmail)
        var participants: [Participant] = []
        
        // Add "me" participant
        participants.append(Participant(
            email: myEmail,
            firstName: myFirstName,
            isMe: true,
            inferredRole: "local"
        ))
        
        // Add other participants
        let otherEmails = attendeeEmails.filter { $0.lowercased() != myEmail.lowercased() }
        let otherParticipants = otherEmails.map { email -> Participant in
            let firstName = Self.deriveFirstName(from: email)
            // In 1:1 meetings, mark the other participant as "remote"
            let role: String? = (otherEmails.count == 1) ? "remote" : nil
            return Participant(email: email, firstName: firstName, isMe: false, inferredRole: role)
        }
        
        participants.append(contentsOf: otherParticipants)
        
        if debugLogging {
            logger.debug("Participant mapping:")
            for p in participants {
                logger.debug("  - \(p.firstName) <\(p.email)>: isMe=\(p.isMe), role=\(p.inferredRole ?? "uncertain")")
            }
        }
        
        // Derive names for backward compatibility with attendeeFirstNames array
        let otherNames = otherParticipants.map { $0.firstName }
        
        logger.info("✓ Successfully resolved \(participants.count) participant(s): \(myFirstName) (me) + \(otherNames.joined(separator: ", "))")
        
        // Note: Outlook resolution doesn't provide meeting title
        return MeetingParticipants(
            meetingTitle: nil,
            myEmail: myEmail,
            myFirstName: myFirstName,
            attendeeEmails: otherEmails,
            attendeeFirstNames: otherNames,
            participants: participants
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
    
    /// Format a date for logging (HH:mm:ss)
    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
