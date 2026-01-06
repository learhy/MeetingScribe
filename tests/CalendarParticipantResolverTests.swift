import XCTest
@testable import MeetingScribe

final class CalendarParticipantResolverTests: XCTestCase {
    
    // MARK: - Email to Name Derivation Tests
    
    func testDeriveFirstNameFromStandardEmail() {
        // firstname.lastname@domain.com -> Firstname
        XCTAssertEqual(
            CalendarParticipantResolver.deriveFirstName(from: "dan.rohan@ibm.com"),
            "Dan"
        )
        XCTAssertEqual(
            CalendarParticipantResolver.deriveFirstName(from: "pradeep.sekar1@ibm.com"),
            "Pradeep"
        )
        XCTAssertEqual(
            CalendarParticipantResolver.deriveFirstName(from: "Katherine.Simmons1@ibm.com"),
            "Katherine"
        )
    }
    
    func testDeriveFirstNameFromUnderscoreEmail() {
        // firstname_lastname@domain.com -> Firstname
        XCTAssertEqual(
            CalendarParticipantResolver.deriveFirstName(from: "john_smith@example.com"),
            "John"
        )
    }
    
    func testDeriveFirstNameFromSingleWordEmail() {
        // username@domain.com -> Username
        XCTAssertEqual(
            CalendarParticipantResolver.deriveFirstName(from: "anando@ibm.com"),
            "Anando"
        )
    }
    
    func testDeriveFirstNameStripsNumbers() {
        // firstname1@domain.com -> Firstname
        XCTAssertEqual(
            CalendarParticipantResolver.deriveFirstName(from: "grace.k@ibm.com"),
            "Grace"
        )
    }
    
    func testDeriveFirstNameHandlesEmptyInput() {
        XCTAssertEqual(
            CalendarParticipantResolver.deriveFirstName(from: ""),
            ""
        )
    }
    
    func testDeriveFirstNameHandlesMalformedEmail() {
        // No @ symbol - just return capitalized input
        XCTAssertEqual(
            CalendarParticipantResolver.deriveFirstName(from: "noemail"),
            "Noemail"
        )
    }
    
    // MARK: - Email Extraction Tests
    
    func testExtractEmailsFromStrings() {
        let testStrings = """
        CRLC@
        Katherine.Simmons1@ibm.com
        chloe.li@ibm.com
        Dan.Rohan@ibm.com
        some random text
        Tim.Messier@ibm.com
        """
        
        let emails = CalendarParticipantResolver.extractEmails(from: testStrings)
        
        XCTAssertEqual(emails.count, 4)
        XCTAssertTrue(emails.contains("Katherine.Simmons1@ibm.com"))
        XCTAssertTrue(emails.contains("chloe.li@ibm.com"))
        XCTAssertTrue(emails.contains("Dan.Rohan@ibm.com"))
        XCTAssertTrue(emails.contains("Tim.Messier@ibm.com"))
    }
    
    func testExtractEmailsDeduplicates() {
        let testStrings = """
        dan.rohan@ibm.com
        something
        dan.rohan@ibm.com
        other.person@ibm.com
        """
        
        let emails = CalendarParticipantResolver.extractEmails(from: testStrings)
        
        // Should have only 2 unique emails
        XCTAssertEqual(emails.count, 2)
    }
    
    func testExtractEmailsHandlesEmpty() {
        let emails = CalendarParticipantResolver.extractEmails(from: "")
        XCTAssertEqual(emails.count, 0)
    }
    
    // MARK: - MeetingParticipants Tests
    
    func testMeetingParticipantsFormatsContextWithParticipants() {
        let participants = MeetingParticipants(
            myEmail: "dan.rohan@ibm.com",
            myFirstName: "Dan",
            attendeeEmails: ["pradeep.sekar1@ibm.com", "tim.messier@ibm.com"],
            attendeeFirstNames: ["Pradeep", "Tim"]
        )
        
        let context = participants.formatForLLMContext()
        
        XCTAssertTrue(context.contains("Dan"))
        XCTAssertTrue(context.contains("Pradeep"))
        XCTAssertTrue(context.contains("Tim"))
        XCTAssertTrue(context.contains("(me)") || context.contains("you are"))
    }
    
    func testMeetingParticipantsFormatsContextWithNoOtherParticipants() {
        let participants = MeetingParticipants(
            myEmail: "dan.rohan@ibm.com",
            myFirstName: "Dan",
            attendeeEmails: [],
            attendeeFirstNames: []
        )
        
        let context = participants.formatForLLMContext()
        
        // Should still mention "me"
        XCTAssertTrue(context.contains("Dan"))
    }
    
    // MARK: - Time Window Matching Tests
    
    func testTimeWindowOverlap() {
        // Recording: 10:00 - 10:30
        // Event: 10:00 - 11:00 -> should match
        let recordingStart = createDate(hour: 10, minute: 0)
        let recordingEnd = createDate(hour: 10, minute: 30)
        let eventStart = createDate(hour: 10, minute: 0)
        let eventEnd = createDate(hour: 11, minute: 0)
        
        XCTAssertTrue(
            CalendarParticipantResolver.timeWindowsOverlap(
                recordingStart: recordingStart,
                recordingEnd: recordingEnd,
                eventStart: eventStart,
                eventEnd: eventEnd
            )
        )
    }
    
    func testTimeWindowNoOverlap() {
        // Recording: 10:00 - 10:30
        // Event: 11:00 - 12:00 -> should not match
        let recordingStart = createDate(hour: 10, minute: 0)
        let recordingEnd = createDate(hour: 10, minute: 30)
        let eventStart = createDate(hour: 11, minute: 0)
        let eventEnd = createDate(hour: 12, minute: 0)
        
        XCTAssertFalse(
            CalendarParticipantResolver.timeWindowsOverlap(
                recordingStart: recordingStart,
                recordingEnd: recordingEnd,
                eventStart: eventStart,
                eventEnd: eventEnd
            )
        )
    }
    
    func testTimeWindowPartialOverlap() {
        // Recording: 10:15 - 10:45
        // Event: 10:00 - 10:30 -> should match (partial overlap)
        let recordingStart = createDate(hour: 10, minute: 15)
        let recordingEnd = createDate(hour: 10, minute: 45)
        let eventStart = createDate(hour: 10, minute: 0)
        let eventEnd = createDate(hour: 10, minute: 30)
        
        XCTAssertTrue(
            CalendarParticipantResolver.timeWindowsOverlap(
                recordingStart: recordingStart,
                recordingEnd: recordingEnd,
                eventStart: eventStart,
                eventEnd: eventEnd
            )
        )
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
