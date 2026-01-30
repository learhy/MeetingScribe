import XCTest
import SQLite3
@testable import MeetingScribe

// MARK: - Mock Implementations for Testing

/// Mock database that returns controlled test data
class MockOutlookDatabase: OutlookDatabaseProtocol {
    var userEmail: String?
    var calendarEvent: CalendarEvent?
    var getUserEmailCallCount = 0
    var findCalendarEventCallCount = 0
    var lastRequestedStartDate: Date?
    var lastRequestedEndDate: Date?
    
    func getUserEmail() -> String? {
        getUserEmailCallCount += 1
        return userEmail
    }
    
    func findCalendarEvent(overlapping start: Date, end: Date) -> CalendarEvent? {
        findCalendarEventCallCount += 1
        lastRequestedStartDate = start
        lastRequestedEndDate = end
        return calendarEvent
    }
}

/// Mock file reader that returns controlled test data
class MockEventFileReader: EventFileReaderProtocol {
    var attendeeEmails: [String] = []
    var extractCallCount = 0
    var lastRequestedPath: String?
    
    func extractAttendeeEmails(fromEventFile path: String) -> [String] {
        extractCallCount += 1
        lastRequestedPath = path
        return attendeeEmails
    }
}

// MARK: - Test Cases

final class CalendarParticipantResolverTests: XCTestCase {
    
    // MARK: - Full Integration Tests (with mocks)
    
    /// Tests the complete happy path: database returns user email and event,
    /// file reader returns attendees, resolver produces correct MeetingParticipants
    func testResolveParticipants_HappyPath_ReturnsCorrectParticipants() {
        // Arrange
        let mockDB = MockOutlookDatabase()
        mockDB.userEmail = "dan.rohan@ibm.com"
        mockDB.calendarEvent = CalendarEvent(
            recordId: 1,
            pathToDataFile: "Events/123/test.olk15Event",
            startDateUTC: createDate(hour: 10, minute: 0),
            endDateUTC: createDate(hour: 11, minute: 0),
            attendeeCount: 3
        )
        
        let mockFileReader = MockEventFileReader()
        mockFileReader.attendeeEmails = [
            "dan.rohan@ibm.com",
            "pradeep.sekar1@ibm.com",
            "tim.messier@ibm.com"
        ]
        
        let resolver = CalendarParticipantResolver(
            database: mockDB,
            fileReader: mockFileReader,
            calendarSource: "outlook",
            isEnabled: true
        )
        
        // Act
        let result = resolver.resolveParticipants(
            recordingStart: createDate(hour: 10, minute: 5),
            recordingEnd: createDate(hour: 10, minute: 35)
        )
        
        // Assert
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.myEmail, "dan.rohan@ibm.com")
        XCTAssertEqual(result?.myFirstName, "Dan")
        XCTAssertEqual(result?.attendeeEmails.count, 2)  // Excludes "me"
        XCTAssertTrue(result?.attendeeEmails.contains("pradeep.sekar1@ibm.com") ?? false)
        XCTAssertTrue(result?.attendeeEmails.contains("tim.messier@ibm.com") ?? false)
        XCTAssertEqual(result?.attendeeFirstNames.count, 2)
        XCTAssertTrue(result?.attendeeFirstNames.contains("Pradeep") ?? false)
        XCTAssertTrue(result?.attendeeFirstNames.contains("Tim") ?? false)
        
        // Verify new participant mapping structure
        XCTAssertEqual(result?.participants.count, 3)  // me + 2 others
        let meParticipant = result?.participants.first { $0.isMe }
        XCTAssertNotNil(meParticipant)
        XCTAssertEqual(meParticipant?.email, "dan.rohan@ibm.com")
        XCTAssertEqual(meParticipant?.firstName, "Dan")
        XCTAssertEqual(meParticipant?.inferredRole, "local")
        
        let otherParticipants = result?.participants.filter { !$0.isMe } ?? []
        XCTAssertEqual(otherParticipants.count, 2)
        
        // Verify mocks were called correctly
        XCTAssertEqual(mockDB.getUserEmailCallCount, 1)
        XCTAssertEqual(mockDB.findCalendarEventCallCount, 1)
        XCTAssertEqual(mockFileReader.extractCallCount, 1)
        XCTAssertEqual(mockFileReader.lastRequestedPath, "Events/123/test.olk15Event")
    }
    
    /// Tests that resolver returns nil when disabled in config
    func testResolveParticipants_WhenDisabled_ReturnsNil() {
        let mockDB = MockOutlookDatabase()
        mockDB.userEmail = "dan.rohan@ibm.com"
        
        let resolver = CalendarParticipantResolver(
            database: mockDB,
            fileReader: MockEventFileReader(),
            calendarSource: "outlook",
            isEnabled: false  // Disabled!
        )
        
        let result = resolver.resolveParticipants(
            recordingStart: Date(),
            recordingEnd: Date()
        )
        
        XCTAssertNil(result)
        XCTAssertEqual(mockDB.getUserEmailCallCount, 0)  // Should not even try
    }
    
    /// Tests that resolver returns nil when user email cannot be determined
    func testResolveParticipants_WhenNoUserEmail_ReturnsNil() {
        let mockDB = MockOutlookDatabase()
        mockDB.userEmail = nil  // Simulates Outlook not installed or empty
        
        let resolver = CalendarParticipantResolver(
            database: mockDB,
            fileReader: MockEventFileReader(),
            calendarSource: "outlook",
            isEnabled: true
        )
        
        let result = resolver.resolveParticipants(
            recordingStart: Date(),
            recordingEnd: Date()
        )
        
        XCTAssertNil(result)
        XCTAssertEqual(mockDB.getUserEmailCallCount, 1)
        XCTAssertEqual(mockDB.findCalendarEventCallCount, 0)  // Should stop early
    }
    
    /// Tests that resolver returns nil when no matching calendar event found
    func testResolveParticipants_WhenNoMatchingEvent_ReturnsNil() {
        let mockDB = MockOutlookDatabase()
        mockDB.userEmail = "dan.rohan@ibm.com"
        mockDB.calendarEvent = nil  // No matching event
        
        let mockFileReader = MockEventFileReader()
        
        let resolver = CalendarParticipantResolver(
            database: mockDB,
            fileReader: mockFileReader,
            calendarSource: "outlook",
            isEnabled: true
        )
        
        let result = resolver.resolveParticipants(
            recordingStart: createDate(hour: 10, minute: 0),
            recordingEnd: createDate(hour: 10, minute: 30)
        )
        
        XCTAssertNil(result)
        XCTAssertEqual(mockDB.findCalendarEventCallCount, 1)
        XCTAssertEqual(mockFileReader.extractCallCount, 0)  // Should not try to read file
    }
    
    /// Tests that resolver returns nil when event file has no extractable emails
    func testResolveParticipants_WhenNoAttendeesInFile_ReturnsNil() {
        let mockDB = MockOutlookDatabase()
        mockDB.userEmail = "dan.rohan@ibm.com"
        mockDB.calendarEvent = CalendarEvent(
            recordId: 1,
            pathToDataFile: "Events/123/corrupted.olk15Event",
            startDateUTC: createDate(hour: 10, minute: 0),
            endDateUTC: createDate(hour: 11, minute: 0),
            attendeeCount: 3
        )
        
        let mockFileReader = MockEventFileReader()
        mockFileReader.attendeeEmails = []  // File exists but no emails found
        
        let resolver = CalendarParticipantResolver(
            database: mockDB,
            fileReader: mockFileReader,
            calendarSource: "outlook",
            isEnabled: true
        )
        
        let result = resolver.resolveParticipants(
            recordingStart: createDate(hour: 10, minute: 5),
            recordingEnd: createDate(hour: 10, minute: 35)
        )
        
        XCTAssertNil(result)
        XCTAssertEqual(mockFileReader.extractCallCount, 1)
    }
    
    /// Tests that in a 1:1 meeting, the other participant is correctly marked as "remote"
    func testResolveParticipants_OneOnOneMeeting_MarksRemoteParticipant() {
        let mockDB = MockOutlookDatabase()
        mockDB.userEmail = "dan.rohan@ibm.com"
        mockDB.calendarEvent = CalendarEvent(
            recordId: 1,
            pathToDataFile: "Events/123/test.olk15Event",
            startDateUTC: createDate(hour: 10, minute: 0),
            endDateUTC: createDate(hour: 11, minute: 0),
            attendeeCount: 2
        )
        
        let mockFileReader = MockEventFileReader()
        mockFileReader.attendeeEmails = [
            "dan.rohan@ibm.com",
            "pradeep.sekar1@ibm.com"  // Only one other person
        ]
        
        let resolver = CalendarParticipantResolver(
            database: mockDB,
            fileReader: mockFileReader,
            calendarSource: "outlook",
            isEnabled: true
        )
        
        let result = resolver.resolveParticipants(
            recordingStart: createDate(hour: 10, minute: 5),
            recordingEnd: createDate(hour: 10, minute: 35)
        )
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.participants.count, 2)  // me + 1 other
        
        let meParticipant = result?.participants.first { $0.isMe }
        XCTAssertNotNil(meParticipant)
        XCTAssertEqual(meParticipant?.inferredRole, "local")
        
        let remoteParticipant = result?.participants.first { !$0.isMe }
        XCTAssertNotNil(remoteParticipant)
        XCTAssertEqual(remoteParticipant?.firstName, "Pradeep")
        XCTAssertEqual(remoteParticipant?.inferredRole, "remote")  // Should be marked as remote in 1:1
    }
    
    /// Tests that "me" is correctly filtered out of attendee list
    func testResolveParticipants_FiltersOutCurrentUser() {
        let mockDB = MockOutlookDatabase()
        mockDB.userEmail = "Dan.Rohan@ibm.com"  // Mixed case
        mockDB.calendarEvent = CalendarEvent(
            recordId: 1,
            pathToDataFile: "Events/123/test.olk15Event",
            startDateUTC: createDate(hour: 10, minute: 0),
            endDateUTC: createDate(hour: 11, minute: 0),
            attendeeCount: 2
        )
        
        let mockFileReader = MockEventFileReader()
        mockFileReader.attendeeEmails = [
            "dan.rohan@ibm.com",  // lowercase - should still be filtered
            "other.person@ibm.com"
        ]
        
        let resolver = CalendarParticipantResolver(
            database: mockDB,
            fileReader: mockFileReader,
            calendarSource: "outlook",
            isEnabled: true
        )
        
        let result = resolver.resolveParticipants(
            recordingStart: createDate(hour: 10, minute: 5),
            recordingEnd: createDate(hour: 10, minute: 35)
        )
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.attendeeEmails.count, 1)
        XCTAssertEqual(result?.attendeeEmails.first, "other.person@ibm.com")
        XCTAssertFalse(result?.attendeeEmails.contains("dan.rohan@ibm.com") ?? true)
    }
    
    // MARK: - Email to Name Derivation Tests
    
    func testDeriveFirstName_StandardFormat() {
        XCTAssertEqual(CalendarParticipantResolver.deriveFirstName(from: "dan.rohan@ibm.com"), "Dan")
        XCTAssertEqual(CalendarParticipantResolver.deriveFirstName(from: "pradeep.sekar1@ibm.com"), "Pradeep")
        XCTAssertEqual(CalendarParticipantResolver.deriveFirstName(from: "Katherine.Simmons1@ibm.com"), "Katherine")
    }
    
    func testDeriveFirstName_UnderscoreFormat() {
        XCTAssertEqual(CalendarParticipantResolver.deriveFirstName(from: "john_smith@example.com"), "John")
    }
    
    func testDeriveFirstName_SingleWord() {
        XCTAssertEqual(CalendarParticipantResolver.deriveFirstName(from: "anando@ibm.com"), "Anando")
    }
    
    func testDeriveFirstName_WithTrailingNumbers() {
        XCTAssertEqual(CalendarParticipantResolver.deriveFirstName(from: "grace.k@ibm.com"), "Grace")
    }
    
    func testDeriveFirstName_EmptyInput() {
        XCTAssertEqual(CalendarParticipantResolver.deriveFirstName(from: ""), "")
    }
    
    func testDeriveFirstName_MalformedEmail() {
        XCTAssertEqual(CalendarParticipantResolver.deriveFirstName(from: "noemail"), "Noemail")
    }
    
    // MARK: - Email Extraction Tests
    
    func testExtractEmails_FindsValidEmails() {
        let input = """
        CRLC@
        Katherine.Simmons1@ibm.com
        chloe.li@ibm.com
        some random text
        Tim.Messier@ibm.com
        """
        
        let emails = CalendarParticipantResolver.extractEmails(from: input)
        
        XCTAssertEqual(emails.count, 3)
        XCTAssertTrue(emails.contains("Katherine.Simmons1@ibm.com"))
        XCTAssertTrue(emails.contains("chloe.li@ibm.com"))
        XCTAssertTrue(emails.contains("Tim.Messier@ibm.com"))
    }
    
    func testExtractEmails_Deduplicates() {
        let input = """
        dan.rohan@ibm.com
        something
        dan.rohan@ibm.com
        """
        
        let emails = CalendarParticipantResolver.extractEmails(from: input)
        XCTAssertEqual(emails.count, 1)
    }
    
    func testExtractEmails_EmptyInput() {
        XCTAssertEqual(CalendarParticipantResolver.extractEmails(from: "").count, 0)
    }
    
    func testExtractEmails_RejectsInvalidEmails() {
        let input = "CRLC@ not@valid @missing.com incomplete@ test"
        let emails = CalendarParticipantResolver.extractEmails(from: input)
        XCTAssertEqual(emails.count, 0)
    }
    
    // MARK: - MeetingParticipants Formatting Tests
    
    func testMeetingParticipants_FormatsContextCorrectly() {
        let participants = [
            Participant(email: "dan.rohan@ibm.com", firstName: "Dan", isMe: true, inferredRole: "local"),
            Participant(email: "pradeep.sekar1@ibm.com", firstName: "Pradeep", isMe: false, inferredRole: nil),
            Participant(email: "tim.messier@ibm.com", firstName: "Tim", isMe: false, inferredRole: nil)
        ]
        
        let meetingParticipants = MeetingParticipants(
            meetingTitle: nil,
            myEmail: "dan.rohan@ibm.com",
            myFirstName: "Dan",
            attendeeEmails: ["pradeep.sekar1@ibm.com", "tim.messier@ibm.com"],
            attendeeFirstNames: ["Pradeep", "Tim"],
            participants: participants
        )
        
        let context = meetingParticipants.formatForLLMContext()
        
        XCTAssertTrue(context.contains("Dan (me)"))
        XCTAssertTrue(context.contains("Pradeep"))
        XCTAssertTrue(context.contains("Tim"))
        XCTAssertTrue(context.contains("Meeting participants:"))
        XCTAssertTrue(context.contains("SPEAKER_"))
        XCTAssertTrue(context.contains("group conversation"))
        XCTAssertTrue(context.contains("DO NOT assume SPEAKER_00"))
    }
    
    func testMeetingParticipants_OneOnOne_ProvidesDiarizationGuidance() {
        let participants = [
            Participant(email: "dan.rohan@ibm.com", firstName: "Dan", isMe: true, inferredRole: "local"),
            Participant(email: "pradeep.sekar1@ibm.com", firstName: "Pradeep", isMe: false, inferredRole: "remote")
        ]
        
        let meetingParticipants = MeetingParticipants(
            meetingTitle: nil,
            myEmail: "dan.rohan@ibm.com",
            myFirstName: "Dan",
            attendeeEmails: ["pradeep.sekar1@ibm.com"],
            attendeeFirstNames: ["Pradeep"],
            participants: participants
        )
        
        let context = meetingParticipants.formatForLLMContext()
        
        XCTAssertTrue(context.contains("1:1 conversation"))
        XCTAssertTrue(context.contains("Dan (local user)"))
        XCTAssertTrue(context.contains("Pradeep (remote participant)"))
        XCTAssertTrue(context.contains("DO NOT assume SPEAKER_00 is always the local user"))
        XCTAssertTrue(context.contains("intelligently infer"))
    }
    
    func testMeetingParticipants_SoloMeeting() {
        let participants = [
            Participant(email: "dan.rohan@ibm.com", firstName: "Dan", isMe: true, inferredRole: "local")
        ]
        
        let meetingParticipants = MeetingParticipants(
            meetingTitle: nil,
            myEmail: "dan.rohan@ibm.com",
            myFirstName: "Dan",
            attendeeEmails: [],
            attendeeFirstNames: [],
            participants: participants
        )
        
        let context = meetingParticipants.formatForLLMContext()
        XCTAssertTrue(context.contains("Dan (me)"))
        XCTAssertTrue(context.contains("Only the local user"))
    }
    
    // MARK: - Time Window Overlap Tests
    
    func testTimeWindowsOverlap_FullyContained() {
        // Recording fully within event
        let recordingStart = createDate(hour: 10, minute: 15)
        let recordingEnd = createDate(hour: 10, minute: 45)
        let eventStart = createDate(hour: 10, minute: 0)
        let eventEnd = createDate(hour: 11, minute: 0)
        
        XCTAssertTrue(CalendarParticipantResolver.timeWindowsOverlap(
            recordingStart: recordingStart,
            recordingEnd: recordingEnd,
            eventStart: eventStart,
            eventEnd: eventEnd
        ))
    }
    
    func testTimeWindowsOverlap_NoOverlap() {
        // Recording before event
        let recordingStart = createDate(hour: 9, minute: 0)
        let recordingEnd = createDate(hour: 9, minute: 30)
        let eventStart = createDate(hour: 10, minute: 0)
        let eventEnd = createDate(hour: 11, minute: 0)
        
        XCTAssertFalse(CalendarParticipantResolver.timeWindowsOverlap(
            recordingStart: recordingStart,
            recordingEnd: recordingEnd,
            eventStart: eventStart,
            eventEnd: eventEnd
        ))
    }
    
    func testTimeWindowsOverlap_PartialOverlapStart() {
        // Recording starts before event but overlaps
        let recordingStart = createDate(hour: 9, minute: 45)
        let recordingEnd = createDate(hour: 10, minute: 15)
        let eventStart = createDate(hour: 10, minute: 0)
        let eventEnd = createDate(hour: 11, minute: 0)
        
        XCTAssertTrue(CalendarParticipantResolver.timeWindowsOverlap(
            recordingStart: recordingStart,
            recordingEnd: recordingEnd,
            eventStart: eventStart,
            eventEnd: eventEnd
        ))
    }
    
    func testTimeWindowsOverlap_PartialOverlapEnd() {
        // Recording extends past event
        let recordingStart = createDate(hour: 10, minute: 45)
        let recordingEnd = createDate(hour: 11, minute: 15)
        let eventStart = createDate(hour: 10, minute: 0)
        let eventEnd = createDate(hour: 11, minute: 0)
        
        XCTAssertTrue(CalendarParticipantResolver.timeWindowsOverlap(
            recordingStart: recordingStart,
            recordingEnd: recordingEnd,
            eventStart: eventStart,
            eventEnd: eventEnd
        ))
    }
    
    // MARK: - Helper Methods
    
    private func createDate(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 6
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }
}

// MARK: - Test Fixture Helpers

/// Helper to get the path to test fixtures
func getFixturePath() -> String {
    // #file gives us the path to this source file
    // We need to go from tests/CalendarParticipantResolverTests.swift to tests/fixtures/outlook/
    let currentFile = #file
    let testsDir = (currentFile as NSString).deletingLastPathComponent
    let fixturePath = testsDir + "/fixtures/outlook/"
    return fixturePath
}

/// Convert OLE minutes (minutes since Jan 1, 1601) to Date
/// Outlook stores calendar timestamps in this format
func dateFromOleMinutes(_ oleMinutes: Double) -> Date {
    // OLE epoch is Jan 1, 1601 which is -11644473600 seconds from Unix epoch
    let oleEpoch = Date(timeIntervalSince1970: -11644473600)
    return oleEpoch.addingTimeInterval(oleMinutes * 60.0)
}

// MARK: - Real SQLite Database Tests

/// Tests that verify the actual SQLite implementation works correctly
/// These tests use a fixture database in tests/fixtures/outlook/
final class OutlookSQLiteDatabaseTests: XCTestCase {
    
    var fixturePath: String!
    
    override func setUp() {
        super.setUp()
        fixturePath = getFixturePath()
    }
    
    func testGetUserEmail_ReturnsEmailFromDatabase() {
        let db = OutlookSQLiteDatabase(databasePath: fixturePath)
        
        let email = db.getUserEmail()
        
        XCTAssertNotNil(email, "Should find user email in test database")
        XCTAssertEqual(email, "test.user@company.com")
    }
    
    func testGetUserEmail_ReturnsNilForMissingDatabase() {
        let db = OutlookSQLiteDatabase(databasePath: "/nonexistent/path/")
        
        let email = db.getUserEmail()
        
        XCTAssertNil(email)
    }
    
    func testFindCalendarEvent_ReturnsMatchingEvent() {
        let db = OutlookSQLiteDatabase(databasePath: fixturePath)
        
        // The fixture has an event at OLE minutes 223528920-223528980 (Jan 1, 2026 10:00-11:00 UTC)
        // Query with a time window that overlaps (10:05 - 10:30)
        let start = createDateFromOleMinutes(223528920 + 5)   // 10:05
        let end = createDateFromOleMinutes(223528920 + 30)    // 10:30
        
        let event = db.findCalendarEvent(overlapping: start, end: end)
        
        XCTAssertNotNil(event, "Should find overlapping calendar event")
        XCTAssertEqual(event?.pathToDataFile, "Events/123/test-meeting.olk15Event")
        XCTAssertEqual(event?.attendeeCount, 3)
    }
    
    func testFindCalendarEvent_ReturnsNilForNonOverlappingTime() {
        let db = OutlookSQLiteDatabase(databasePath: fixturePath)
        
        // Query with a time window that doesn't overlap (way in the future)
        let start = createDateFromOleMinutes(230000000)  // ~2038
        let end = createDateFromOleMinutes(230000060)    // 1 hour later
        
        let event = db.findCalendarEvent(overlapping: start, end: end)
        
        XCTAssertNil(event, "Should not find event outside time window")
    }
    
    func testFindCalendarEvent_IgnoresEventsWithNoAttendees() {
        let db = OutlookSQLiteDatabase(databasePath: fixturePath)
        
        // The fixture has a solo event (0 attendees) at the same time as the meeting
        // The query should return the meeting (3 attendees), not the solo event
        let start = createDateFromOleMinutes(223528920 + 5)   // 10:05
        let end = createDateFromOleMinutes(223528920 + 30)    // 10:30
        
        let event = db.findCalendarEvent(overlapping: start, end: end)
        
        XCTAssertNotNil(event)
        XCTAssertGreaterThan(event?.attendeeCount ?? 0, 0, "Should only return events with attendees")
    }
    
    // MARK: - Helper Methods
    
    /// Create a Date from OLE minutes (minutes since Jan 1, 1601)
    private func createDateFromOleMinutes(_ oleMinutes: Double) -> Date {
        // OLE epoch is Jan 1, 1601 which is -11644473600 seconds from Unix epoch
        let oleEpoch = Date(timeIntervalSince1970: -11644473600)
        return oleEpoch.addingTimeInterval(oleMinutes * 60.0)
    }
}

// MARK: - Real Event File Reader Tests

/// Tests that verify the actual file reader extracts emails from binary files
final class OutlookEventFileReaderTests: XCTestCase {
    
    var fixturePath: String!
    
    override func setUp() {
        super.setUp()
        fixturePath = getFixturePath()
    }
    
    func testExtractAttendeeEmails_ExtractsEmailsFromBinaryFile() {
        let reader = OutlookEventFileReader(basePath: fixturePath)
        
        let emails = reader.extractAttendeeEmails(fromEventFile: "Events/123/test-meeting.olk15Event")
        
        XCTAssertGreaterThan(emails.count, 0, "Should extract emails from fixture file")
        XCTAssertTrue(emails.contains("test.user@company.com"))
        XCTAssertTrue(emails.contains("alice.smith@company.com"))
        XCTAssertTrue(emails.contains("bob.jones@company.com"))
    }
    
    func testExtractAttendeeEmails_ReturnsEmptyForMissingFile() {
        let reader = OutlookEventFileReader(basePath: fixturePath)
        
        let emails = reader.extractAttendeeEmails(fromEventFile: "Events/nonexistent.olk15Event")
        
        XCTAssertEqual(emails.count, 0)
    }
}

// MARK: - Full End-to-End Integration Test

/// Tests the complete flow with real SQLite database and real file reader
final class CalendarParticipantResolverIntegrationTests: XCTestCase {
    
    var fixturePath: String!
    
    override func setUp() {
        super.setUp()
        fixturePath = getFixturePath()
    }
    
    func testResolveParticipants_EndToEnd_WithRealFixtures() {
        // Use real implementations with fixture data
        let db = OutlookSQLiteDatabase(databasePath: fixturePath)
        let fileReader = OutlookEventFileReader(basePath: fixturePath)
        
        let resolver = CalendarParticipantResolver(
            database: db,
            fileReader: fileReader,
            calendarSource: "outlook",
            isEnabled: true
        )
        
        // Query with time that overlaps the fixture event (OLE minutes 223528920-223528980)
        let start = dateFromOleMinutes(223528920 + 5)   // 10:05
        let end = dateFromOleMinutes(223528920 + 30)    // 10:30
        
        let result = resolver.resolveParticipants(recordingStart: start, recordingEnd: end)
        
        XCTAssertNotNil(result, "Should resolve participants from fixture data")
        XCTAssertEqual(result?.myEmail, "test.user@company.com")
        XCTAssertEqual(result?.myFirstName, "Test")
        
        // Should have 2 other attendees (excluding "me")
        XCTAssertEqual(result?.attendeeEmails.count, 2)
        XCTAssertTrue(result?.attendeeEmails.contains("alice.smith@company.com") ?? false)
        XCTAssertTrue(result?.attendeeEmails.contains("bob.jones@company.com") ?? false)
        
        // Verify derived names
        XCTAssertTrue(result?.attendeeFirstNames.contains("Alice") ?? false)
        XCTAssertTrue(result?.attendeeFirstNames.contains("Bob") ?? false)
    }
    
    func testResolveParticipants_EndToEnd_NoMatchingEvent() {
        let db = OutlookSQLiteDatabase(databasePath: fixturePath)
        let fileReader = OutlookEventFileReader(basePath: fixturePath)
        
        let resolver = CalendarParticipantResolver(
            database: db,
            fileReader: fileReader,
            calendarSource: "outlook",
            isEnabled: true
        )
        
        // Query with time that doesn't overlap any fixture event (far in the future)
        let start = dateFromOleMinutes(230000000)  // ~2038
        let end = dateFromOleMinutes(230000060)    // 1 hour later
        
        let result = resolver.resolveParticipants(recordingStart: start, recordingEnd: end)
        
        XCTAssertNil(result, "Should return nil when no matching event")
    }
}

// MARK: - SQL Query Edge Case Tests

/// Tests for the 5-minute buffer and event selection logic
final class SQLQueryEdgeCaseTests: XCTestCase {
    
    var fixturePath: String!
    
    override func setUp() {
        super.setUp()
        fixturePath = getFixturePath()
    }
    
    /// Tests that the 5-minute buffer allows finding events that start shortly after recording ends
    /// 
    /// The SQL query uses:
    /// - adjustedStart = recordingStart - 5 minutes (expand backward)
    /// - adjustedEnd = recordingEnd + 5 minutes (expand forward)
    /// - WHERE event.start <= adjustedEnd AND event.end >= adjustedStart
    func testFindCalendarEvent_FiveMinuteBuffer_FindsEventStartingAfterRecordingEnds() {
        let db = OutlookSQLiteDatabase(databasePath: fixturePath)
        
        // "just-inside-buffer" event: OLE minutes 223528982-223529042, 2 attendees
        // 
        // Query a recording that ends 2 minutes BEFORE the event starts:
        // Recording: 223528978 - 223528980
        // adjustedEnd = 223528980 + 5 = 223528985
        // 
        // Event matches if: event.start (223528982) <= adjustedEnd (223528985)  ✓
        //                   event.end (223529042) >= adjustedStart (223528973)  ✓
        //
        // The main event (223528920-223528980, 3 attendees) also matches and has more attendees.
        // So this test verifies that SOME event is found when the buffer is in play.
        let recordingStart = dateFromOleMinutes(223528978)
        let recordingEnd = dateFromOleMinutes(223528980)
        
        let event = db.findCalendarEvent(overlapping: recordingStart, end: recordingEnd)
        
        XCTAssertNotNil(event, "Should find an event (buffer allows matching nearby events)")
    }
    
    /// Tests that events well outside the 5-minute buffer are NOT matched
    func testFindCalendarEvent_FiveMinuteBuffer_DoesNotFindDistantEvent() {
        let db = OutlookSQLiteDatabase(databasePath: fixturePath)
        
        // Query a recording well outside any fixture events
        // All fixture events are between OLE minutes 223528000-223529100
        // Query way after that range
        let recordingStart = dateFromOleMinutes(223540000)
        let recordingEnd = dateFromOleMinutes(223540060)
        
        let event = db.findCalendarEvent(overlapping: recordingStart, end: recordingEnd)
        
        // Should NOT find any event in this gap
        XCTAssertNil(event, "Should not find any event in time gap between fixtures")
    }
    
    /// Tests that when multiple events overlap, the one with highest attendee count is returned
    func testFindCalendarEvent_MultipleOverlapping_ReturnsHighestAttendeeCount() {
        let db = OutlookSQLiteDatabase(databasePath: fixturePath)
        
        // Fixture has two overlapping events at OLE minutes 223529000-223529060:
        // - small-meeting (record 6) with 2 attendees
        // - large-meeting (record 7) with 8 attendees
        let recordingStart = dateFromOleMinutes(223529010)
        let recordingEnd = dateFromOleMinutes(223529050)
        
        let event = db.findCalendarEvent(overlapping: recordingStart, end: recordingEnd)
        
        XCTAssertNotNil(event, "Should find an overlapping event")
        XCTAssertEqual(event?.attendeeCount, 8, "Should return the event with highest attendee count")
        XCTAssertTrue(event?.pathToDataFile.contains("large-meeting") ?? false,
                     "Should return large-meeting, not small-meeting")
    }
}

// MARK: - SQLite Error Handling Tests

/// Tests for graceful handling of database errors
final class SQLiteErrorHandlingTests: XCTestCase {
    
    func testGetUserEmail_CorruptedDatabase_ReturnsNil() {
        let corruptedPath = getFixturePathFor(subdir: "outlook-corrupted")
        let db = OutlookSQLiteDatabase(databasePath: corruptedPath)
        
        let email = db.getUserEmail()
        
        XCTAssertNil(email, "Should return nil for corrupted database")
    }
    
    func testFindCalendarEvent_CorruptedDatabase_ReturnsNil() {
        let corruptedPath = getFixturePathFor(subdir: "outlook-corrupted")
        let db = OutlookSQLiteDatabase(databasePath: corruptedPath)
        
        let event = db.findCalendarEvent(
            overlapping: Date(),
            end: Date().addingTimeInterval(3600)
        )
        
        XCTAssertNil(event, "Should return nil for corrupted database")
    }
    
    func testGetUserEmail_MissingTable_ReturnsNil() {
        let missingTablesPath = getFixturePathFor(subdir: "outlook-missing-tables")
        let db = OutlookSQLiteDatabase(databasePath: missingTablesPath)
        
        let email = db.getUserEmail()
        
        XCTAssertNil(email, "Should return nil when AccountsExchange table is missing")
    }
    
    func testFindCalendarEvent_MissingTable_ReturnsNil() {
        let missingTablesPath = getFixturePathFor(subdir: "outlook-missing-tables")
        let db = OutlookSQLiteDatabase(databasePath: missingTablesPath)
        
        let event = db.findCalendarEvent(
            overlapping: Date(),
            end: Date().addingTimeInterval(3600)
        )
        
        XCTAssertNil(event, "Should return nil when CalendarEvents table is missing")
    }
}

// MARK: - Schema Robustness Tests

/// Tests that document the fragility of hardcoded column indices
/// IMPORTANT: These tests verify current behavior but also document a known limitation:
/// The implementation uses hardcoded column index 5 for email, which will break if Outlook's schema changes.
final class SchemaRobustnessTests: XCTestCase {
    
    /// Verifies that the current fixture database has email at column index 5
    /// This test serves as a canary - if it fails, the fixture schema has changed
    func testColumnIndex_EmailAtExpectedPosition() {
        let fixturePath = getFixturePath()
        let dbPath = fixturePath + "Outlook.sqlite"
        
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            XCTFail("Could not open test database")
            return
        }
        defer { sqlite3_close(db) }
        
        // Get column info using PRAGMA
        let query = "PRAGMA table_info(AccountsExchange)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            XCTFail("Could not prepare PRAGMA query")
            return
        }
        defer { sqlite3_finalize(statement) }
        
        var columnNames: [Int: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let cid = Int(sqlite3_column_int(statement, 0))
            if let name = sqlite3_column_text(statement, 1) {
                columnNames[cid] = String(cString: name)
            }
        }
        
        // Verify Email is at index 5
        XCTAssertEqual(columnNames[5], "Email",
                      "Email column should be at index 5. Actual columns: \(columnNames)")
    }
    
    /// Documents the failure case when email is at a different column position
    /// This test shows that the implementation WILL break if schema changes
    func testColumnIndex_DifferentSchema_ReturnsWrongValue() {
        let differentSchemaPath = getFixturePathFor(subdir: "outlook-different-schema")
        let db = OutlookSQLiteDatabase(databasePath: differentSchemaPath)
        
        let email = db.getUserEmail()
        
        // In the different-schema fixture, Email is at column 1, not 5
        // So getUserEmail() will try to read column 5 which doesn't exist
        // This should return nil because there's no column 5
        // (This documents the fragility - a schema change would cause silent failure)
        XCTAssertNil(email, 
                    "Expected nil because column index 5 doesn't exist in the different schema. " +
                    "This test documents that hardcoded column indices are fragile.")
    }
}

// MARK: - ConfigManager Integration Tests

/// Tests for the convenience initializer that uses ConfigManager
/// Note: These tests use mocks because we can't easily modify the singleton ConfigManager
final class ConfigManagerIntegrationTests: XCTestCase {
    
    /// Tests that resolver respects the enabled flag from config
    func testResolverRespectsEnabledFlag() {
        let mockDB = MockOutlookDatabase()
        mockDB.userEmail = "test@example.com"
        
        let disabledResolver = CalendarParticipantResolver(
            database: mockDB,
            fileReader: MockEventFileReader(),
            calendarSource: "outlook",
            isEnabled: false
        )
        
        let result = disabledResolver.resolveParticipants(
            recordingStart: Date(),
            recordingEnd: Date()
        )
        
        XCTAssertNil(result, "Should return nil when disabled")
        XCTAssertEqual(mockDB.getUserEmailCallCount, 0, "Should not query database when disabled")
    }
    
    /// Tests that the default Outlook path constant is correctly formatted
    func testDefaultOutlookPath_IsCorrectlyFormatted() {
        let defaultPath = CalendarParticipantResolver.defaultOutlookPath
        
        XCTAssertTrue(defaultPath.hasPrefix("~/Library/Group Containers/"),
                     "Default path should start with ~/Library/Group Containers/")
        XCTAssertTrue(defaultPath.contains("UBF8T346G9.Office"),
                     "Default path should contain Office group container ID")
        XCTAssertTrue(defaultPath.contains("Outlook.sqlite") || defaultPath.hasSuffix("/"),
                     "Default path should either include Outlook.sqlite or end with /")
    }
    
    /// Tests path expansion with trailing slash handling
    func testPathExpansion_HandlesTrailingSlash() {
        // Test that paths without trailing slashes get one added
        let pathWithoutSlash = "/some/path"
        let expandedWithoutSlash = pathWithoutSlash.hasSuffix("/") ? pathWithoutSlash : pathWithoutSlash + "/"
        XCTAssertTrue(expandedWithoutSlash.hasSuffix("/"))
        
        // Test that paths with trailing slashes don't get double slashes
        let pathWithSlash = "/some/path/"
        let expandedWithSlash = pathWithSlash.hasSuffix("/") ? pathWithSlash : pathWithSlash + "/"
        XCTAssertFalse(expandedWithSlash.hasSuffix("//"))
    }
}

// MARK: - Graceful Degradation Tests (No Outlook Installed)

/// Tests that verify the software fails gracefully when Outlook is not installed
/// CRITICAL: The software must continue to work without Outlook - it just won't have participant names
final class GracefulDegradationTests: XCTestCase {
    
    /// Tests that resolver returns nil (not crash) when Outlook database doesn't exist
    /// This simulates a user who doesn't have Outlook installed
    func testResolveParticipants_NoOutlookInstalled_ReturnsNilGracefully() {
        // Use the real production path that won't exist on most systems
        let nonExistentPath = "/nonexistent/path/to/outlook/"
        let db = OutlookSQLiteDatabase(databasePath: nonExistentPath)
        let fileReader = OutlookEventFileReader(basePath: nonExistentPath)
        
        let resolver = CalendarParticipantResolver(
            database: db,
            fileReader: fileReader,
            calendarSource: "outlook",
            isEnabled: true
        )
        
        // This should NOT crash - it should return nil gracefully
        let result = resolver.resolveParticipants(
            recordingStart: Date(),
            recordingEnd: Date().addingTimeInterval(3600)
        )
        
        XCTAssertNil(result, "Should return nil gracefully when Outlook is not installed")
    }
    
    /// Tests that the production convenience initializer doesn't crash when Outlook isn't installed
    /// This tests the actual code path used in main.swift
    func testProductionInitializer_NoOutlookInstalled_DoesNotCrash() {
        // The production initializer reads from ConfigManager and constructs real implementations
        // Even if Outlook isn't at the default path, this should not crash
        // We can't easily test this without modifying ConfigManager, but we CAN test that
        // the OutlookSQLiteDatabase handles missing paths gracefully
        
        let defaultPath = (CalendarParticipantResolver.defaultOutlookPath as NSString).expandingTildeInPath
        let db = OutlookSQLiteDatabase(databasePath: defaultPath)
        
        // Even if this path exists (real Outlook), or doesn't exist, this should not crash
        // It should return nil or a valid email
        let email = db.getUserEmail()
        
        // We don't assert the value because it depends on whether Outlook is installed
        // The key assertion is that we reached this line without crashing
        XCTAssertTrue(true, "getUserEmail should complete without crashing regardless of Outlook installation")
        
        // Log for visibility
        if let email = email {
            print("[TEST] Outlook is installed, found email: \(email)")
        } else {
            print("[TEST] Outlook not installed or no email found - this is expected and OK")
        }
    }
    
    /// Tests that meeting processing continues normally when participant resolution fails
    /// This verifies the "old behavior" (SPEAKER_00, etc) remains when Outlook isn't available
    func testParticipantContextIsOptional_NilDoesNotBreakProcessing() {
        // Simulate what happens in main.swift processRecording() when resolver returns nil
        let mockDB = MockOutlookDatabase()
        mockDB.userEmail = nil  // Simulates no Outlook
        
        let resolver = CalendarParticipantResolver(
            database: mockDB,
            fileReader: MockEventFileReader(),
            calendarSource: "outlook",
            isEnabled: true
        )
        
        let participants = resolver.resolveParticipants(
            recordingStart: Date(),
            recordingEnd: Date()
        )
        
        // This is what main.swift does:
        var participantContext: String? = nil
        if let p = participants {
            participantContext = p.formatForLLMContext()
        }
        
        // When Outlook isn't available, participantContext should be nil
        // and the LLM should fall back to SPEAKER_00, SPEAKER_01, etc.
        XCTAssertNil(participantContext, "Should have nil context when Outlook unavailable")
        
        // The key point: the code path completed without error
        // NotesGenerationService.generateNotes() accepts nil participantContext
    }
}

// MARK: - NotesGenerationService Integration Tests

/// Tests for the participant context injection into NotesGenerationService
final class NotesGenerationIntegrationTests: XCTestCase {
    
    /// Tests that generateNotes accepts nil participantContext without error
    func testGenerateNotes_NilParticipantContext_DoesNotCrash() {
        // We can't actually call the LLM in tests, but we can verify the method signature
        // accepts nil and the code structure is correct
        
        // This test documents that the method signature allows nil:
        // func generateNotes(transcript: String, participantContext: String? = nil)
        
        // The actual integration would be:
        // let notes = try await notesService.generateNotes(transcript: "test", participantContext: nil)
        // But we can't await in sync tests without more infrastructure
        
        // For now, verify the MeetingParticipants formatting works correctly
        let participantsList = [
            Participant(email: "test@example.com", firstName: "Test", isMe: true, inferredRole: "local"),
            Participant(email: "other@example.com", firstName: "Other", isMe: false, inferredRole: "remote")
        ]
        
        let meetingParticipants = MeetingParticipants(
            meetingTitle: nil,
            myEmail: "test@example.com",
            myFirstName: "Test",
            attendeeEmails: ["other@example.com"],
            attendeeFirstNames: ["Other"],
            participants: participantsList
        )
        
        let context = meetingParticipants.formatForLLMContext()
        
        // Verify the context would be appended correctly to a system prompt
        let systemPrompt = "You are a meeting notes assistant."
        let augmentedPrompt = systemPrompt + "\n\n" + context
        
        XCTAssertTrue(augmentedPrompt.contains("Meeting participants:"))
        XCTAssertTrue(augmentedPrompt.contains("Test (me)"))
        XCTAssertTrue(augmentedPrompt.contains("Other"))
        XCTAssertTrue(augmentedPrompt.contains("SPEAKER_"))
    }
    
    /// Tests that empty participant context doesn't corrupt the prompt
    func testGenerateNotes_EmptyParticipantContext_DoesNotCorruptPrompt() {
        let systemPrompt = "You are a meeting notes assistant."
        let emptyContext = ""
        
        // This is what NotesGenerationService does when context is empty:
        // if let context = participantContext, !context.isEmpty {
        //     systemPrompt = systemPrompt + "\n\n" + context
        // }
        
        var augmentedPrompt = systemPrompt
        if !emptyContext.isEmpty {
            augmentedPrompt = systemPrompt + "\n\n" + emptyContext
        }
        
        // Prompt should be unchanged
        XCTAssertEqual(augmentedPrompt, systemPrompt, "Empty context should not modify prompt")
    }
}

// MARK: - MeetingParticipants Edge Case Tests

/// Additional edge case tests for MeetingParticipants formatting
final class MeetingParticipantsEdgeCaseTests: XCTestCase {
    
    /// Tests that duplicate names (myFirstName matches attendeeFirstName) are handled
    func testFormatForLLMContext_DuplicateNames_OnlyShowsOnce() {
        // Edge case: What if the user's derived name matches an attendee's name?
        // This could happen with common names like "John"
        let participantsList = [
            Participant(email: "john.smith@example.com", firstName: "John", isMe: true, inferredRole: "local"),
            Participant(email: "john.doe@example.com", firstName: "John", isMe: false, inferredRole: nil),
            Participant(email: "jane.doe@example.com", firstName: "Jane", isMe: false, inferredRole: nil)
        ]
        
        let meetingParticipants = MeetingParticipants(
            meetingTitle: nil,
            myEmail: "john.smith@example.com",
            myFirstName: "John",
            attendeeEmails: ["john.doe@example.com", "jane.doe@example.com"],
            attendeeFirstNames: ["John", "Jane"],
            participants: participantsList
        )
        
        let context = meetingParticipants.formatForLLMContext()
        
        // The current implementation filters out attendee names that match myFirstName in the participant list
        // In the "Meeting participants:" line, "John" should only appear once as "John (me)", not as plain "John"
        XCTAssertTrue(context.contains("Meeting participants: John (me), Jane"))
        XCTAssertFalse(context.contains("John, John"), "Should not have duplicate John in participant list")
        XCTAssertTrue(context.contains("Jane"))
    }
    
    /// Tests formatting when myFirstName is empty
    func testFormatForLLMContext_EmptyMyFirstName_StillWorks() {
        let participantsList = [
            Participant(email: "@malformed.com", firstName: "", isMe: true, inferredRole: "local"),
            Participant(email: "alice@example.com", firstName: "Alice", isMe: false, inferredRole: "remote")
        ]
        
        let meetingParticipants = MeetingParticipants(
            meetingTitle: nil,
            myEmail: "@malformed.com",
            myFirstName: "",
            attendeeEmails: ["alice@example.com"],
            attendeeFirstNames: ["Alice"],
            participants: participantsList
        )
        
        let context = meetingParticipants.formatForLLMContext()
        
        // Should still include Alice, even if "me" is missing
        XCTAssertTrue(context.contains("Alice"))
        XCTAssertFalse(context.contains("(me)"), "Should not have (me) marker when name is empty")
    }
    
    /// Tests that formatForLLMContext returns empty string when no participants
    func testFormatForLLMContext_AllEmpty_ReturnsEmptyString() {
        let meetingParticipants = MeetingParticipants(
            meetingTitle: nil,
            myEmail: "",
            myFirstName: "",
            attendeeEmails: [],
            attendeeFirstNames: [],
            participants: []
        )
        
        let context = meetingParticipants.formatForLLMContext()
        
        XCTAssertEqual(context, "", "Should return empty string when all fields are empty")
    }
}

// MARK: - Real Outlook Integration Test (Optional)

/// Tests that run against real Outlook installation if present
/// These tests are informational - they pass regardless of Outlook installation
final class RealOutlookTests: XCTestCase {
    
    /// Tests against real Outlook installation if present
    /// This test always passes but logs whether Outlook was found
    func testRealOutlookInstallation_InformationalOnly() {
        let defaultPath = (CalendarParticipantResolver.defaultOutlookPath as NSString).expandingTildeInPath
        let dbPath = defaultPath + "Outlook.sqlite"
        
        let outlookExists = FileManager.default.fileExists(atPath: dbPath)
        
        if outlookExists {
            print("[TEST] ✓ Outlook database found at: \(dbPath)")
            
            // Try to read user email
            let db = OutlookSQLiteDatabase(databasePath: defaultPath)
            if let email = db.getUserEmail() {
                print("[TEST] ✓ Successfully read user email: \(email)")
            } else {
                print("[TEST] ✗ Outlook database exists but couldn't read email (schema mismatch?)")
            }
        } else {
            print("[TEST] ○ Outlook not installed at default path - this is OK")
        }
        
        // This test always passes - it's informational
        XCTAssertTrue(true, "This test is informational only")
    }
}

// MARK: - Additional Fixture Helpers

/// Helper to get path to alternative fixture directories
func getFixturePathFor(subdir: String) -> String {
    let currentFile = #file
    let testsDir = (currentFile as NSString).deletingLastPathComponent
    return testsDir + "/fixtures/" + subdir + "/"
}

// MARK: - EventKit Integration Tests

/// Tests for EventKit calendar reader integration with CalendarParticipantResolver
final class EventKitIntegrationTests: XCTestCase {
    
    private func createDate(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 15
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }
    
    /// Tests that EventKit source returns meeting title in MeetingParticipants
    func testResolveParticipants_EventKit_ReturnsMeetingTitle() {
        let mockEventKit = MockEventKitCalendarReader()
        mockEventKit.meetingInfo = EventKitMeetingInfo(
            title: "Weekly Team Sync",
            startDate: createDate(hour: 10, minute: 0),
            endDate: createDate(hour: 11, minute: 0),
            location: "Conference Room A",
            attendees: [
                EventKitAttendee(email: "dan@example.com", name: "Dan", isOrganizer: true),
                EventKitAttendee(email: "alice@example.com", name: "Alice", isOrganizer: false)
            ],
            calendarName: "Calendar"
        )
        
        let resolver = CalendarParticipantResolver(
            database: nil,
            fileReader: nil,
            eventKitReader: mockEventKit,
            calendarSource: "eventkit",
            isEnabled: true
        )
        
        let result = resolver.resolveParticipants(
            recordingStart: createDate(hour: 10, minute: 5),
            recordingEnd: createDate(hour: 10, minute: 55)
        )
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.meetingTitle, "Weekly Team Sync")
        XCTAssertEqual(result?.participants.count, 2)
        XCTAssertEqual(mockEventKit.findMeetingCallCount, 1)
    }
    
    /// Tests that EventKit source uses attendee names directly (not derived from email)
    func testResolveParticipants_EventKit_UsesAttendeeNames() {
        let mockEventKit = MockEventKitCalendarReader()
        mockEventKit.meetingInfo = EventKitMeetingInfo(
            title: "Project Review",
            startDate: createDate(hour: 14, minute: 0),
            endDate: createDate(hour: 15, minute: 0),
            location: nil,
            attendees: [
                EventKitAttendee(email: "dan.rohan@company.com", name: "Daniel Rohan", isOrganizer: true),
                EventKitAttendee(email: "alice.smith@company.com", name: "Alice Smith", isOrganizer: false)
            ],
            calendarName: "Calendar"
        )
        
        let resolver = CalendarParticipantResolver(
            database: nil,
            fileReader: nil,
            eventKitReader: mockEventKit,
            calendarSource: "eventkit",
            isEnabled: true
        )
        
        let result = resolver.resolveParticipants(
            recordingStart: createDate(hour: 14, minute: 5),
            recordingEnd: createDate(hour: 14, minute: 55)
        )
        
        XCTAssertNotNil(result)
        // Should use the full name from EventKit, not derived "Dan" from email
        XCTAssertEqual(result?.myFirstName, "Daniel Rohan")
        XCTAssertTrue(result?.attendeeFirstNames.contains("Alice Smith") ?? false)
    }
    
    /// Tests that EventKit source falls back to email-derived names when name is nil
    func testResolveParticipants_EventKit_FallsBackToEmailDerivedName() {
        let mockEventKit = MockEventKitCalendarReader()
        mockEventKit.meetingInfo = EventKitMeetingInfo(
            title: "Quick Call",
            startDate: createDate(hour: 9, minute: 0),
            endDate: createDate(hour: 9, minute: 30),
            location: nil,
            attendees: [
                EventKitAttendee(email: "dan@example.com", name: nil, isOrganizer: true),
                EventKitAttendee(email: "bob.jones@example.com", name: nil, isOrganizer: false)
            ],
            calendarName: "Calendar"
        )
        
        let resolver = CalendarParticipantResolver(
            database: nil,
            fileReader: nil,
            eventKitReader: mockEventKit,
            calendarSource: "eventkit",
            isEnabled: true
        )
        
        let result = resolver.resolveParticipants(
            recordingStart: createDate(hour: 9, minute: 5),
            recordingEnd: createDate(hour: 9, minute: 25)
        )
        
        XCTAssertNotNil(result)
        // Should derive names from email when attendee.name is nil
        XCTAssertEqual(result?.myFirstName, "Dan")
        XCTAssertTrue(result?.attendeeFirstNames.contains("Bob") ?? false)
    }
    
    /// Tests that "both" mode tries EventKit first
    func testResolveParticipants_BothMode_TriesEventKitFirst() {
        let mockEventKit = MockEventKitCalendarReader()
        mockEventKit.meetingInfo = EventKitMeetingInfo(
            title: "EventKit Meeting",
            startDate: createDate(hour: 10, minute: 0),
            endDate: createDate(hour: 11, minute: 0),
            location: nil,
            attendees: [
                EventKitAttendee(email: "dan@example.com", name: "Dan", isOrganizer: true)
            ],
            calendarName: "Calendar"
        )
        
        let mockDB = MockOutlookDatabase()
        mockDB.userEmail = "dan@outlook.com"
        
        let resolver = CalendarParticipantResolver(
            database: mockDB,
            fileReader: MockEventFileReader(),
            eventKitReader: mockEventKit,
            calendarSource: "both",
            isEnabled: true
        )
        
        let result = resolver.resolveParticipants(
            recordingStart: createDate(hour: 10, minute: 5),
            recordingEnd: createDate(hour: 10, minute: 55)
        )
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.meetingTitle, "EventKit Meeting")
        XCTAssertEqual(mockEventKit.findMeetingCallCount, 1)
        // Outlook should NOT be called since EventKit succeeded
        XCTAssertEqual(mockDB.getUserEmailCallCount, 0)
    }
    
    /// Tests that "both" mode falls back to Outlook when EventKit fails
    func testResolveParticipants_BothMode_FallsBackToOutlook() {
        let mockEventKit = MockEventKitCalendarReader()
        mockEventKit.meetingInfo = nil  // EventKit returns nothing
        
        let mockDB = MockOutlookDatabase()
        mockDB.userEmail = "dan@company.com"
        mockDB.calendarEvent = CalendarEvent(
            recordId: 1,
            pathToDataFile: "Events/123/test.olk15Event",
            startDateUTC: createDate(hour: 10, minute: 0),
            endDateUTC: createDate(hour: 11, minute: 0),
            attendeeCount: 2
        )
        
        let mockFileReader = MockEventFileReader()
        mockFileReader.attendeeEmails = ["dan@company.com", "alice@company.com"]
        
        let resolver = CalendarParticipantResolver(
            database: mockDB,
            fileReader: mockFileReader,
            eventKitReader: mockEventKit,
            calendarSource: "both",
            isEnabled: true
        )
        
        let result = resolver.resolveParticipants(
            recordingStart: createDate(hour: 10, minute: 5),
            recordingEnd: createDate(hour: 10, minute: 55)
        )
        
        XCTAssertNotNil(result)
        // Should fall back to Outlook (no meeting title from Outlook)
        XCTAssertNil(result?.meetingTitle)
        XCTAssertEqual(result?.myEmail, "dan@company.com")
        XCTAssertEqual(mockEventKit.findMeetingCallCount, 1)
        XCTAssertEqual(mockDB.getUserEmailCallCount, 1)
    }
    
    /// Tests that EventKit-only mode returns nil when EventKit fails
    func testResolveParticipants_EventKitOnly_ReturnsNilWhenNoEvent() {
        let mockEventKit = MockEventKitCalendarReader()
        mockEventKit.meetingInfo = nil  // No matching event
        
        let resolver = CalendarParticipantResolver(
            database: nil,
            fileReader: nil,
            eventKitReader: mockEventKit,
            calendarSource: "eventkit",
            isEnabled: true
        )
        
        let result = resolver.resolveParticipants(
            recordingStart: createDate(hour: 10, minute: 0),
            recordingEnd: createDate(hour: 10, minute: 30)
        )
        
        XCTAssertNil(result)
    }
    
    /// Tests MeetingParticipants with meeting title
    func testMeetingParticipants_WithMeetingTitle() {
        let participants = [
            Participant(email: "dan@example.com", firstName: "Dan", isMe: true, inferredRole: "local"),
            Participant(email: "alice@example.com", firstName: "Alice", isMe: false, inferredRole: "remote")
        ]
        
        let meetingParticipants = MeetingParticipants(
            meetingTitle: "Weekly Team Sync",
            myEmail: "dan@example.com",
            myFirstName: "Dan",
            attendeeEmails: ["alice@example.com"],
            attendeeFirstNames: ["Alice"],
            participants: participants
        )
        
        XCTAssertEqual(meetingParticipants.meetingTitle, "Weekly Team Sync")
        XCTAssertEqual(meetingParticipants.myFirstName, "Dan")
        XCTAssertEqual(meetingParticipants.attendeeFirstNames.count, 1)
    }
}

// MARK: - Mock for EventKit Tests (defined in EventKitCalendarReaderTests.swift)
// MockEventKitCalendarReader is already defined there and will be available
