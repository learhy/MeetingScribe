import XCTest
@testable import MeetingScribe

final class NameResolverTests: XCTestCase {

    // MARK: - Basic Resolution

    func testResolve_1to1_WithOneMatchedOneNil() {
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id1", name: "Dan", confidence: 0.9),
            "SPEAKER_01": nil
        ]
        let participants = MeetingParticipants(
            meetingTitle: nil,
            myEmail: "dan@x.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@x.com"],
            attendeeFirstNames: ["Rachana"],
            participants: [
                Participant(email: "dan@x.com", firstName: "Dan", isMe: true, inferredRole: "local"),
                Participant(email: "rachana@x.com", firstName: "Rachana", isMe: false, inferredRole: "remote")
            ]
        )

        let result = NameResolver.resolve(
            participants: participants, speakerMap: speakerMap, contacts: [], transcript: ""
        )

        XCTAssertEqual(result.labelMap["SPEAKER_00"]?.displayName, "Dan")
        XCTAssertEqual(result.labelMap["SPEAKER_01"]?.displayName, "Rachana")
        XCTAssertEqual(result.labelMap["SPEAKER_00"]?.source, .voiceMatch)
        XCTAssertEqual(result.labelMap["SPEAKER_01"]?.source, .calendar)
    }

    func testResolve_BothMatched() {
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id1", name: "Dan", confidence: 0.95),
            "SPEAKER_01": SpeakerIdentity(speakerId: "id2", name: "Rachana", confidence: 0.85)
        ]
        let participants = MeetingParticipants(
            meetingTitle: nil,
            myEmail: "dan@x.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@x.com"],
            attendeeFirstNames: ["Rachana"],
            participants: [
                Participant(email: "dan@x.com", firstName: "Dan", isMe: true, inferredRole: "local"),
                Participant(email: "rachana@x.com", firstName: "Rachana", isMe: false, inferredRole: "remote")
            ]
        )

        let result = NameResolver.resolve(
            participants: participants, speakerMap: speakerMap, contacts: [], transcript: ""
        )

        XCTAssertEqual(result.labelMap.count, 2)
        XCTAssertEqual(result.labelMap["SPEAKER_00"]?.displayName, "Dan")
        XCTAssertEqual(result.labelMap["SPEAKER_01"]?.displayName, "Rachana")
    }

    func testResolve_NoCalendarData() {
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id1", name: "Dan", confidence: 0.9)
        ]

        let result = NameResolver.resolve(
            participants: nil, speakerMap: speakerMap, contacts: [], transcript: ""
        )

        XCTAssertEqual(result.labelMap["SPEAKER_00"]?.displayName, "Dan")
        XCTAssertEqual(result.labelMap["SPEAKER_00"]?.source, .voiceMatch)
    }

    func testResolve_NoSpeakerMap() {
        let participants = MeetingParticipants(
            meetingTitle: nil,
            myEmail: "dan@x.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@x.com"],
            attendeeFirstNames: ["Rachana"],
            participants: [
                Participant(email: "dan@x.com", firstName: "Dan", isMe: true, inferredRole: "local"),
                Participant(email: "rachana@x.com", firstName: "Rachana", isMe: false, inferredRole: "remote")
            ]
        )

        let result = NameResolver.resolve(
            participants: participants, speakerMap: nil, contacts: [], transcript: ""
        )

        // No labels to resolve
        XCTAssertTrue(result.labelMap.isEmpty)
    }

    // MARK: - Voice Match Threshold

    func testResolve_BelowThreshold_NotResolved() {
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id1", name: "Dan", confidence: 0.3)
        ]

        let result = NameResolver.resolve(
            participants: nil, speakerMap: speakerMap, contacts: [], transcript: ""
        )

        // Below 0.6 threshold — should not be resolved
        XCTAssertNil(result.labelMap["SPEAKER_00"])
    }

    func testResolve_AtThreshold_Resolved() {
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id1", name: "Dan", confidence: 0.6)
        ]

        let result = NameResolver.resolve(
            participants: nil, speakerMap: speakerMap, contacts: [], transcript: ""
        )

        XCTAssertEqual(result.labelMap["SPEAKER_00"]?.displayName, "Dan")
    }

    // MARK: - Fuzzy Reconciliation

    func testReconcileName_RatchnaToRachana() {
        let contacts = [
            ContactInfo(email: "rachana@x.com", displayName: "Rachana Reddy",
                       preferredName: "Rachana", pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "calendar")
        ]
        let contactsByEmail = Dictionary(contacts.map { ($0.email.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let calendarByFirstName: [String: Participant] = [:]

        let result = NameResolver.reconcileName(
            voiceMatched: "Ratchna",
            contacts: contacts,
            contactsByEmail: contactsByEmail,
            calendarByFirstName: calendarByFirstName
        )

        // Should fuzzy-match "Ratchna" to "Rachana" via phonetic/Levenshtein
        XCTAssertEqual(result.name, "Rachana Reddy")
        XCTAssertEqual(result.source, .contacts)
    }

    func testReconcileName_ExactMatch() {
        let contacts = [
            ContactInfo(email: "dan@x.com", displayName: "Dan Rohan",
                       preferredName: "Dan", pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "manual")
        ]
        let contactsByEmail = Dictionary(contacts.map { ($0.email.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

        let result = NameResolver.reconcileName(
            voiceMatched: "Dan",
            contacts: contacts,
            contactsByEmail: contactsByEmail,
            calendarByFirstName: [:]
        )

        XCTAssertEqual(result.name, "Dan Rohan")
        XCTAssertEqual(result.source, .contacts)
        XCTAssertEqual(result.email, "dan@x.com")
    }

    func testReconcileName_NoMatch_UsesVoiceMatched() {
        let result = NameResolver.reconcileName(
            voiceMatched: "UnknownPerson",
            contacts: [],
            contactsByEmail: [:],
            calendarByFirstName: [:]
        )

        XCTAssertEqual(result.name, "UnknownPerson")
        XCTAssertEqual(result.source, .voiceMatch)
    }

    // MARK: - Known People List

    func testResolve_KnownPeopleIncludesContacts() {
        let contacts = [
            ContactInfo(email: "rachana@x.com", displayName: "Rachana Reddy",
                       preferredName: "Rachana", pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "calendar")
        ]
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id1", name: "Dan", confidence: 0.9)
        ]
        let participants = MeetingParticipants(
            meetingTitle: nil,
            myEmail: "dan@x.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@x.com"],
            attendeeFirstNames: ["Rachana"],
            participants: [
                Participant(email: "dan@x.com", firstName: "Dan", isMe: true, inferredRole: "local"),
                Participant(email: "rachana@x.com", firstName: "Rachana", isMe: false, inferredRole: "remote")
            ]
        )

        let result = NameResolver.resolve(
            participants: participants, speakerMap: speakerMap, contacts: contacts, transcript: ""
        )

        // Known people should include Rachana's contact (unmatched attendee with contact)
        XCTAssertTrue(result.knownPeople.contains { $0.email == "rachana@x.com" })
    }

    // MARK: - Attendees List

    func testAttendeesList_WithContactsDisplayNames() {
        let contacts = [
            ContactInfo(email: "rachana@x.com", displayName: "Rachana Reddy",
                       preferredName: "Rachana", pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "calendar")
        ]
        let participants = MeetingParticipants(
            meetingTitle: nil,
            myEmail: "dan@x.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@x.com"],
            attendeeFirstNames: ["Rachana"],
            participants: [
                Participant(email: "dan@x.com", firstName: "Dan", isMe: true, inferredRole: "local"),
                Participant(email: "rachana@x.com", firstName: "Rachana", isMe: false, inferredRole: "remote")
            ]
        )

        let attendees = NameResolver.attendeesList(
            participants: participants, labelMap: [:], contacts: contacts
        )

        // Should use contact display name "Rachana Reddy" not just "Rachana"
        XCTAssertTrue(attendees.contains("Rachana Reddy"))
        XCTAssertTrue(attendees.contains("Dan"))
    }

    func testAttendeesList_NoContacts_FallsBackToFirstNames() {
        let participants = MeetingParticipants(
            meetingTitle: nil,
            myEmail: "dan@x.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@x.com"],
            attendeeFirstNames: ["Rachana"],
            participants: [
                Participant(email: "dan@x.com", firstName: "Dan", isMe: true, inferredRole: "local"),
                Participant(email: "rachana@x.com", firstName: "Rachana", isMe: false, inferredRole: "remote")
            ]
        )

        let attendees = NameResolver.attendeesList(
            participants: participants, labelMap: [:], contacts: []
        )

        XCTAssertEqual(attendees, "Dan, Rachana")
    }

    func testAttendeesList_NoCalendar_UsesLabelMap() {
        let labelMap = [
            "SPEAKER_00": CanonicalName(displayName: "Dan Rohan", source: .voiceMatch, confidence: 0.9),
            "SPEAKER_01": CanonicalName(displayName: "Rachana Reddy", source: .contacts, confidence: 0.85)
        ]

        let attendees = NameResolver.attendeesList(
            participants: nil, labelMap: labelMap, contacts: []
        )

        XCTAssertTrue(attendees.contains("Dan Rohan"))
        XCTAssertTrue(attendees.contains("Rachana Reddy"))
    }

    func testAttendeesList_Empty() {
        let attendees = NameResolver.attendeesList(
            participants: nil, labelMap: [:], contacts: []
        )
        XCTAssertEqual(attendees, "")
    }

    // MARK: - 1:1 Fallback with "Me"

    func testResolve_1to1_MeFallback() {
        // One speaker is voice-matched (Dan), the other is unmatched
        // Calendar has 2 participants: Dan (me) and Rachana
        // The unmatched speaker should get Rachana via the 1:1 fallback
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id1", name: "Dan", confidence: 0.9),
            "SPEAKER_01": nil
        ]
        let participants = MeetingParticipants(
            meetingTitle: nil,
            myEmail: "dan@x.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@x.com"],
            attendeeFirstNames: ["Rachana"],
            participants: [
                Participant(email: "dan@x.com", firstName: "Dan", isMe: true, inferredRole: "local"),
                Participant(email: "rachana@x.com", firstName: "Rachana", isMe: false, inferredRole: "remote")
            ]
        )

        let result = NameResolver.resolve(
            participants: participants, speakerMap: speakerMap, contacts: [], transcript: ""
        )

        // SPEAKER_00 is voice-matched to Dan
        // SPEAKER_01 should get Rachana via the 1:1 fallback
        XCTAssertEqual(result.labelMap["SPEAKER_00"]?.displayName, "Dan")
        XCTAssertEqual(result.labelMap["SPEAKER_01"]?.displayName, "Rachana")
    }
}