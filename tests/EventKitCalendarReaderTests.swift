import XCTest
@testable import MeetingScribe

// MARK: - Mock EventKit Calendar Reader

/// Mock implementation for testing CalendarParticipantResolver's EventKit integration
class MockEventKitCalendarReader: EventKitCalendarReaderProtocol {
    var accessGranted: Bool = true
    var meetingInfo: EventKitMeetingInfo?
    var requestAccessCallCount = 0
    var findMeetingCallCount = 0
    var lastRequestedStart: Date?
    var lastRequestedEnd: Date?
    
    func requestAccess() async -> Bool {
        requestAccessCallCount += 1
        return accessGranted
    }
    
    func findMeeting(overlapping start: Date, end: Date) -> EventKitMeetingInfo? {
        findMeetingCallCount += 1
        lastRequestedStart = start
        lastRequestedEnd = end
        return meetingInfo
    }
}

// MARK: - Test Cases

final class EventKitCalendarReaderTests: XCTestCase {
    
    // MARK: - Helper Methods
    
    private func createDate(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2024
        components.month = 1
        components.day = 15
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }
    
    // MARK: - Mock Integration Tests
    
    /// Test that mock returns meeting info correctly
    func testMockEventKitReader_ReturnsMeetingInfo() {
        let mock = MockEventKitCalendarReader()
        mock.meetingInfo = EventKitMeetingInfo(
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
        
        let result = mock.findMeeting(
            overlapping: createDate(hour: 10, minute: 5),
            end: createDate(hour: 10, minute: 30)
        )
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.title, "Weekly Team Sync")
        XCTAssertEqual(result?.attendees.count, 2)
        XCTAssertEqual(result?.location, "Conference Room A")
        XCTAssertEqual(mock.findMeetingCallCount, 1)
    }
    
    /// Test that mock returns nil when no meeting set
    func testMockEventKitReader_ReturnsNilWhenNoMeeting() {
        let mock = MockEventKitCalendarReader()
        mock.meetingInfo = nil
        
        let result = mock.findMeeting(
            overlapping: createDate(hour: 10, minute: 0),
            end: createDate(hour: 10, minute: 30)
        )
        
        XCTAssertNil(result)
        XCTAssertEqual(mock.findMeetingCallCount, 1)
    }
    
    /// Test access request tracking
    func testMockEventKitReader_TracksAccessRequests() async {
        let mock = MockEventKitCalendarReader()
        mock.accessGranted = true
        
        let granted = await mock.requestAccess()
        
        XCTAssertTrue(granted)
        XCTAssertEqual(mock.requestAccessCallCount, 1)
    }
    
    /// Test access denied scenario
    func testMockEventKitReader_AccessDenied() async {
        let mock = MockEventKitCalendarReader()
        mock.accessGranted = false
        
        let granted = await mock.requestAccess()
        
        XCTAssertFalse(granted)
    }
    
    // MARK: - EventKitAttendee Tests
    
    /// Test attendee with name
    func testEventKitAttendee_WithName() {
        let attendee = EventKitAttendee(
            email: "alice@example.com",
            name: "Alice Smith",
            isOrganizer: false
        )
        
        XCTAssertEqual(attendee.email, "alice@example.com")
        XCTAssertEqual(attendee.name, "Alice Smith")
        XCTAssertFalse(attendee.isOrganizer)
    }
    
    /// Test attendee without name
    func testEventKitAttendee_WithoutName() {
        let attendee = EventKitAttendee(
            email: "bob@example.com",
            name: nil,
            isOrganizer: true
        )
        
        XCTAssertEqual(attendee.email, "bob@example.com")
        XCTAssertNil(attendee.name)
        XCTAssertTrue(attendee.isOrganizer)
    }
    
    // MARK: - EventKitMeetingInfo Tests
    
    /// Test meeting info with all fields
    func testEventKitMeetingInfo_AllFields() {
        let attendees = [
            EventKitAttendee(email: "dan@example.com", name: "Dan", isOrganizer: true),
            EventKitAttendee(email: "alice@example.com", name: "Alice", isOrganizer: false),
            EventKitAttendee(email: "bob@example.com", name: nil, isOrganizer: false)
        ]
        
        let meetingInfo = EventKitMeetingInfo(
            title: "Project Review",
            startDate: createDate(hour: 14, minute: 0),
            endDate: createDate(hour: 15, minute: 0),
            location: "Zoom",
            attendees: attendees,
            calendarName: "Work Calendar"
        )
        
        XCTAssertEqual(meetingInfo.title, "Project Review")
        XCTAssertEqual(meetingInfo.location, "Zoom")
        XCTAssertEqual(meetingInfo.attendees.count, 3)
        XCTAssertEqual(meetingInfo.calendarName, "Work Calendar")
    }
    
    /// Test meeting info with minimal fields
    func testEventKitMeetingInfo_MinimalFields() {
        let meetingInfo = EventKitMeetingInfo(
            title: "Quick Call",
            startDate: createDate(hour: 9, minute: 0),
            endDate: createDate(hour: 9, minute: 30),
            location: nil,
            attendees: [],
            calendarName: "Calendar"
        )
        
        XCTAssertEqual(meetingInfo.title, "Quick Call")
        XCTAssertNil(meetingInfo.location)
        XCTAssertTrue(meetingInfo.attendees.isEmpty)
    }
}
