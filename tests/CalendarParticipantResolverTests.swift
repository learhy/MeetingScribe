import XCTest
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
            isEnabled: true
        )
        
        let result = resolver.resolveParticipants(
            recordingStart: createDate(hour: 10, minute: 5),
            recordingEnd: createDate(hour: 10, minute: 35)
        )
        
        XCTAssertNil(result)
        XCTAssertEqual(mockFileReader.extractCallCount, 1)
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
        let participants = MeetingParticipants(
            myEmail: "dan.rohan@ibm.com",
            myFirstName: "Dan",
            attendeeEmails: ["pradeep.sekar1@ibm.com", "tim.messier@ibm.com"],
            attendeeFirstNames: ["Pradeep", "Tim"]
        )
        
        let context = participants.formatForLLMContext()
        
        XCTAssertTrue(context.contains("Dan (me)"))
        XCTAssertTrue(context.contains("Pradeep"))
        XCTAssertTrue(context.contains("Tim"))
        XCTAssertTrue(context.contains("Meeting participants:"))
        XCTAssertTrue(context.contains("SPEAKER_"))
    }
    
    func testMeetingParticipants_SoloMeeting() {
        let participants = MeetingParticipants(
            myEmail: "dan.rohan@ibm.com",
            myFirstName: "Dan",
            attendeeEmails: [],
            attendeeFirstNames: []
        )
        
        let context = participants.formatForLLMContext()
        XCTAssertTrue(context.contains("Dan (me)"))
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
