import XCTest
@testable import MeetingScribe

final class NameResolverTests: XCTestCase {

    // MARK: - Basic Resolution Tests

    func testResolveWithVoiceMatchOnly() {
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id-1", name: "Dan", confidence: 0.9),
            "SPEAKER_01": SpeakerIdentity(speakerId: "id-2", name: "Rachana", confidence: 0.85)
        ]

        let result = NameResolver.resolve(
            participants: nil,
            speakerMap: speakerMap,
            contacts: [],
            transcript: ""
        )

        XCTAssertEqual(result.labelMap["SPEAKER_00"]?.displayName, "Dan")
        XCTAssertEqual(result.labelMap["SPEAKER_01"]?.displayName, "Rachana")
        XCTAssertEqual(result.labelMap["SPEAKER_00"]?.source, .voiceMatch)
    }

    func testResolveWithLowConfidenceVoiceMatch() {
        // Below threshold (0.6) — should not be resolved by voice
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id-1", name: "Dan", confidence: 0.4)
        ]

        let result = NameResolver.resolve(
            participants: nil,
            speakerMap: speakerMap,
            contacts: [],
            transcript: ""
        )

        // Low confidence voice match should not produce a label mapping
        XCTAssertNil(result.labelMap["SPEAKER_00"])
    }

    func testResolve1On1CalendarFallback() {
        // One speaker matched by voice, one not — calendar has the other attendee
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id-1", name: "Dan", confidence: 0.9),
            "SPEAKER_01": nil
        ]

        let participants = MeetingParticipants(
            meetingTitle: "1:1",
            myEmail: "dan@example.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@example.com"],
            attendeeFirstNames: ["Rachana"],
            participants: [
                Participant(email: "dan@example.com", firstName: "Dan", isMe: true, inferredRole: "local"),
                Participant(email: "rachana@example.com", firstName: "Rachana", isMe: false, inferredRole: "remote")
            ]
        )

        let result = NameResolver.resolve(
            participants: participants,
            speakerMap: speakerMap,
            contacts: [],
            transcript: ""
        )

        // SPEAKER_00 should be Dan (voice match)
        XCTAssertEqual(result.labelMap["SPEAKER_00"]?.displayName, "Dan")

        // SPEAKER_01 should be Rachana (calendar fallback)
        XCTAssertEqual(result.labelMap["SPEAKER_01"]?.displayName, "Rachana")
        XCTAssertEqual(result.labelMap["SPEAKER_01"]?.source, .calendar)
    }

    func testResolveWithContactsEnrichment() {
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id-1", name: "Dan", confidence: 0.9),
            "SPEAKER_01": nil
        ]

        let participants = MeetingParticipants(
            meetingTitle: "1:1",
            myEmail: "dan@example.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@example.com"],
            attendeeFirstNames: ["Rachana"],
            participants: [
                Participant(email: "dan@example.com", firstName: "Dan", isMe: true, inferredRole: "local"),
                Participant(email: "rachana@example.com", firstName: "Rachana", isMe: false, inferredRole: "remote")
            ]
        )

        let contacts = [
            ContactInfo(email: "rachana@example.com", displayName: "Rachana Reddy",
                       preferredName: "Rachana", pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "manual")
        ]

        let result = NameResolver.resolve(
            participants: participants,
            speakerMap: speakerMap,
            contacts: contacts,
            transcript: ""
        )

        // SPEAKER_01 should use the contact's display name
        XCTAssertEqual(result.labelMap["SPEAKER_01"]?.displayName, "Rachana Reddy")
        XCTAssertEqual(result.labelMap["SPEAKER_01"]?.source, .contacts)
    }

    // MARK: - Fuzzy Reconciliation Tests

    func testReconcileName_RatchnaToRachana() {
        // Voice-matched "Ratchna" should be reconciled to "Rachana" from contacts
        let contacts = [
            ContactInfo(email: "rachana@example.com", displayName: "Rachana Reddy",
                       preferredName: "Rachana", pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "manual")
        ]

        let contactsByFirstName = ["rachana": contacts[0]]

        let reconciled = NameResolver.reconcileName(
            voiceMatched: "Ratchna",
            contacts: contacts,
            contactsByEmail: ["rachana@example.com": contacts[0]],
            contactsByFirstName: contactsByFirstName
        )

        XCTAssertEqual(reconciled.displayName, "Rachana Reddy")
        XCTAssertEqual(reconciled.source, .contacts)
    }

    func testReconcileName_SaptanaToSapta() {
        let contacts = [
            ContactInfo(email: "sapta@example.com", displayName: "Saptaparni Das",
                       preferredName: "Sapta", pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "manual")
        ]

        let contactsByFirstName = ["sapta": contacts[0]]

        let reconciled = NameResolver.reconcileName(
            voiceMatched: "Saptana",
            contacts: contacts,
            contactsByEmail: ["sapta@example.com": contacts[0]],
            contactsByFirstName: contactsByFirstName
        )

        // "Saptana" vs "Sapta" — distance is 2 (add "na"), within threshold
        XCTAssertEqual(reconciled.displayName, "Saptaparni Das")
        XCTAssertEqual(reconciled.source, .contacts)
    }

    func testReconcileName_NoCloseMatch() {
        let contacts = [
            ContactInfo(email: "rachana@example.com", displayName: "Rachana Reddy",
                       preferredName: "Rachana", pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "manual")
        ]

        let reconciled = NameResolver.reconcileName(
            voiceMatched: "Mukesh",
            contacts: contacts,
            contactsByEmail: ["rachana@example.com": contacts[0]],
            contactsByFirstName: ["rachana": contacts[0]]
        )

        // "Mukesh" is too different from "Rachana" — keep voice-matched name
        XCTAssertEqual(reconciled.displayName, "Mukesh")
        XCTAssertEqual(reconciled.source, .voiceMatch)
    }

    func testReconcileName_ExactMatch() {
        let contacts = [
            ContactInfo(email: "anando@example.com", displayName: "Anando Gupta",
                       preferredName: "Anando", pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "manual")
        ]

        let reconciled = NameResolver.reconcileName(
            voiceMatched: "Anando",
            contacts: contacts,
            contactsByEmail: ["anando@example.com": contacts[0]],
            contactsByFirstName: ["anando": contacts[0]]
        )

        XCTAssertEqual(reconciled.displayName, "Anando Gupta")
        XCTAssertEqual(reconciled.source, .contacts)
    }

    // MARK: - Known People List Tests

    func testKnownPeopleIncludesVoiceMatchedNames() {
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id-1", name: "Mukesh", confidence: 0.9)
        ]

        let result = NameResolver.resolve(
            participants: nil,
            speakerMap: speakerMap,
            contacts: [],
            transcript: ""
        )

        // Known people should include the voice-matched name as a synthetic contact
        XCTAssertTrue(result.knownPeople.contains { $0.displayName == "Mukesh" })
    }

    func testKnownPeopleIncludesCalendarParticipants() {
        let participants = MeetingParticipants(
            meetingTitle: "Team Sync",
            myEmail: "dan@example.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@example.com"],
            attendeeFirstNames: ["Rachana"],
            participants: [
                Participant(email: "dan@example.com", firstName: "Dan", isMe: true, inferredRole: "local"),
                Participant(email: "rachana@example.com", firstName: "Rachana", isMe: false, inferredRole: "remote")
            ]
        )

        let result = NameResolver.resolve(
            participants: participants,
            speakerMap: nil,
            contacts: [],
            transcript: ""
        )

        XCTAssertTrue(result.knownPeople.contains { $0.bestName == "Rachana" })
    }

    // MARK: - Attendees List Tests

    func testAttendeesListUsesDisplayNames() {
        let participants = MeetingParticipants(
            meetingTitle: "1:1",
            myEmail: "dan@example.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@example.com"],
            attendeeFirstNames: ["Rachana"],
            participants: [
                Participant(email: "dan@example.com", firstName: "Dan", isMe: true, inferredRole: "local"),
                Participant(email: "rachana@example.com", firstName: "Rachana", isMe: false, inferredRole: "remote")
            ]
        )

        let labelMap: [String: CanonicalName] = [
            "SPEAKER_00": CanonicalName(displayName: "Dan Rohan", firstName: "Dan", source: .contacts, confidence: 0.9, email: "dan@example.com"),
            "SPEAKER_01": CanonicalName(displayName: "Rachana Reddy", firstName: "Rachana", source: .contacts, confidence: 0.85, email: "rachana@example.com")
        ]

        let attendees = NameResolver.attendeesList(participants: participants, labelMap: labelMap)

        XCTAssertTrue(attendees.contains("Dan Rohan"))
        XCTAssertTrue(attendees.contains("Rachana Reddy"))
    }

    func testAttendeesListNoSpeakerLabels() {
        let participants = MeetingParticipants(
            meetingTitle: "1:1",
            myEmail: "dan@example.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@example.com"],
            attendeeFirstNames: ["Rachana"],
            participants: [
                Participant(email: "dan@example.com", firstName: "Dan", isMe: true, inferredRole: "local"),
                Participant(email: "rachana@example.com", firstName: "Rachana", isMe: false, inferredRole: "remote")
            ]
        )

        let attendees = NameResolver.attendeesList(participants: participants, labelMap: [:])

        // Should use calendar first names, no SPEAKER_XX
        XCTAssertTrue(attendees.contains("Dan"))
        XCTAssertTrue(attendees.contains("Rachana"))
        XCTAssertFalse(attendees.contains("SPEAKER"))
    }

    func testAttendeesListEmptyParticipants() {
        let attendees = NameResolver.attendeesList(participants: nil, labelMap: [:])
        XCTAssertEqual(attendees, "")
    }

    // MARK: - Neutral Label Tests

    func testNeutralLabelConversion() {
        XCTAssertEqual(CanonicalName.neutralLabel(for: "SPEAKER_00"), "Speaker 1")
        XCTAssertEqual(CanonicalName.neutralLabel(for: "SPEAKER_01"), "Speaker 2")
        XCTAssertEqual(CanonicalName.neutralLabel(for: "SPEAKER_12"), "Speaker 13")
    }

    func testNeutralLabelNonStandardFormat() {
        // Non-standard label should be capitalized
        XCTAssertEqual(CanonicalName.neutralLabel(for: "UNKNOWN_SPEAKER"), "Unknown Speaker")
    }

    // MARK: - Group Call Tests

    func testGroupCallUnambiguousAssignment() {
        // 3 speakers, none voice-matched, 3 calendar participants
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": nil,
            "SPEAKER_01": nil,
            "SPEAKER_02": nil
        ]

        let participants = MeetingParticipants(
            meetingTitle: "Team Sync",
            myEmail: "dan@example.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@example.com", "anando@example.com"],
            attendeeFirstNames: ["Rachana", "Anando"],
            participants: [
                Participant(email: "dan@example.com", firstName: "Dan", isMe: true, inferredRole: nil),
                Participant(email: "rachana@example.com", firstName: "Rachana", isMe: false, inferredRole: nil),
                Participant(email: "anando@example.com", firstName: "Anando", isMe: false, inferredRole: nil)
            ]
        )

        let result = NameResolver.resolve(
            participants: participants,
            speakerMap: speakerMap,
            contacts: [],
            transcript: ""
        )

        // All three speakers should be assigned
        XCTAssertEqual(result.labelMap.count, 3)
        let assignedNames = Set(result.labelMap.values.map { $0.firstName })
        XCTAssertTrue(assignedNames.contains("Dan"))
        XCTAssertTrue(assignedNames.contains("Rachana"))
        XCTAssertTrue(assignedNames.contains("Anando"))
    }

    // MARK: - No Speaker Map Tests

    func testResolveWithNoSpeakerMap() {
        let participants = MeetingParticipants(
            meetingTitle: "Solo meeting",
            myEmail: "dan@example.com",
            myFirstName: "Dan",
            attendeeEmails: [],
            attendeeFirstNames: [],
            participants: [
                Participant(email: "dan@example.com", firstName: "Dan", isMe: true, inferredRole: "local")
            ]
        )

        let result = NameResolver.resolve(
            participants: participants,
            speakerMap: nil,
            contacts: [],
            transcript: ""
        )

        // No speaker labels to map, but knownPeople should include calendar participant
        XCTAssertTrue(result.labelMap.isEmpty)
        XCTAssertTrue(result.knownPeople.contains { $0.bestName == "Dan" })
    }
}