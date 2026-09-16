import XCTest
@testable import MeetingScribe

// P2-2: calendar-primed speaker attribution + presentation rules.
// [needs-Mac-build] — exercised on the Mac build; the same rules are mirrored
// in tools/eval/p2_logic.py for the Linux host regression suite.
final class P2AttributionTests: XCTestCase {

    private func participants(_ specs: [(String, String, Bool)]) -> MeetingParticipants {
        let people = specs.map { email, first, isMe in
            Participant(email: email, firstName: first, isMe: isMe, inferredRole: nil)
        }
        let emails = specs.filter { !$0.2 }.map { $0.0 }
        let names = specs.filter { !$0.2 }.map { $0.1 }
        let meEmail = specs.first(where: { $0.2 })?.0 ?? ""
        let meName = specs.first(where: { $0.2 })?.1 ?? ""
        return MeetingParticipants(
            meetingTitle: nil,
            myEmail: meEmail,
            myFirstName: meName,
            attendeeEmails: emails,
            attendeeFirstNames: names,
            participants: people
        )
    }

    // MARK: - 1:1 calendar-inference is APPLIED

    func testOneToOneInferenceAppliedToLabelMap() {
        let participants = participants([("dan@x.com", "Dan", true), ("rachana@x.com", "Rachana", false)])
        let speakerMap: [String: SpeakerIdentity?] = ["SPEAKER_00": SpeakerIdentity(speakerId: "s0", name: "Dan", confidence: 0.9), "SPEAKER_01": nil]

        let (labelMap, _) = NameResolver.resolve(
            participants: participants, speakerMap: speakerMap, contacts: [], transcript: "")

        // P2-2: the logged-only fallback is now APPLIED — SPEAKER_01 gets Rachana.
        let resolved = labelMap["SPEAKER_01"]
        XCTAssertNotNil(resolved, "1:1 fallback must assign the sole unmatched attendee")
        XCTAssertEqual(resolved?.firstName, "Rachana")
        XCTAssertEqual(resolved?.email, "rachana@x.com")
        XCTAssertEqual(resolved?.basis, .calendarInference)
    }

    func testVoiceMatchBasisIsVoice() {
        let participants = participants([("dan@x.com", "Dan", true), ("rachana@x.com", "Rachana", false)])
        let speakerMap: [String: SpeakerIdentity?] = ["SPEAKER_00": SpeakerIdentity(speakerId: "s0", name: "Rachana", confidence: 0.85)]

        let (labelMap, _) = NameResolver.resolve(
            participants: participants, speakerMap: speakerMap, contacts: [], transcript: "")

        XCTAssertEqual(labelMap["SPEAKER_00"]?.basis, .voiceMatch)
        XCTAssertNil(labelMap["SPEAKER_01"])
    }

    func testNoOneToOneInferenceInMultiSpeakerMeeting() {
        // 2 unmatched speakers + 1 unmatched attendee — must NOT infer.
        let participants = participants([
            ("dan@x.com", "Dan", true), ("rachana@x.com", "Rachana", false),
            ("a@x.com", "Amy", false), ("b@x.com", "Bob", false)])
        let speakerMap: [String: SpeakerIdentity?] = ["SPEAKER_00": nil, "SPEAKER_01": nil]

        let (labelMap, _) = NameResolver.resolve(
            participants: participants, speakerMap: speakerMap, contacts: [], transcript: "")

        XCTAssertNil(labelMap["SPEAKER_00"])
        XCTAssertNil(labelMap["SPEAKER_01"])
    }

    func testBelowThresholdVoiceMatchStaysUnmatched() {
        let participants = participants([("dan@x.com", "Dan", true), ("rachana@x.com", "Rachana", false)])
        let speakerMap: [String: SpeakerIdentity?] = ["SPEAKER_00": SpeakerIdentity(speakerId: "s0", name: "Rachana", confidence: 0.4)]

        let (labelMap, _) = NameResolver.resolve(
            participants: participants, speakerMap: speakerMap, contacts: [], transcript: "")

        // Below 0.6 threshold -> treated as unmatched -> 1:1 inference applies.
        XCTAssertEqual(labelMap["SPEAKER_00"]?.basis, .calendarInference)
    }

    // MARK: - Assignment-basis logging

    func testAssignmentBasisLineFormat() {
        let voice = NameResolver.assignmentBasisLine(
            label: "SPEAKER_00", name: "Rachana Reddy", basis: .voiceMatch, confidence: 0.85, detail: "voice match (speaker DB)")
        XCTAssertTrue(voice.contains("SPEAKER_00 → Rachana Reddy basis=voice"), voice)

        let inferred = NameResolver.assignmentBasisLine(
            label: "SPEAKER_01", name: "Rachana", basis: .calendarInference, confidence: 0.7, detail: "1:1 fallback")
        XCTAssertTrue(inferred.contains("basis=calendar-inference"), inferred)
    }

    // MARK: - Presentation rules

    func testCalendarInferredNameRendersWithLikelySuffix() {
        let labelMap: [String: CanonicalName] = [
            "SPEAKER_00": CanonicalName(displayName: "Rachana Reddy", source: .voiceMatch, confidence: 0.85),
            "SPEAKER_01": CanonicalName(displayName: "Krishnan", source: .calendar, confidence: 0.7, basis: .calendarInference),
        ]
        let out = VerificationPass.normalizeLabels(
            "SPEAKER_00 opened. SPEAKER_01 agreed.", labelMap: labelMap)
        XCTAssertTrue(out.contains("Rachana Reddy opened."), out)
        XCTAssertTrue(out.contains("Krishnan (likely) agreed."), out)
        XCTAssertFalse(out.contains("SPEAKER_"))
    }

    func testUnresolvedLabelsRenderAsSpeakerN() {
        let labelMap: [String: CanonicalName] = [:]
        let out = NotesLabelCleaner.clean("SPEAKER_02 raised a concern", labelMap: labelMap)
        XCTAssertEqual(out, "Speaker 2 raised a concern")
    }

    func testRawLabelsNeverReachSummaryOrNotes() {
        let labelMap: [String: CanonicalName] = [
            "SPEAKER_00": CanonicalName(displayName: "Dan Rohan", source: .calendar, confidence: 0.7, basis: .calendarInference),
        ]
        let cleaned = NotesLabelCleaner.cleanSummaryAndNotes(
            summary: "SPEAKER_00 summarized the plan. SPEAKER_01 disagreed.",
            notes: "- SPEAKER_00 action item\n- SPEAKER_01 follow-up",
            labelMap: labelMap)
        XCTAssertFalse(cleaned.summary.contains("SPEAKER_"))
        XCTAssertFalse(cleaned.notes.contains("SPEAKER_"))
        XCTAssertTrue(cleaned.summary.contains("Dan Rohan (likely)"))
        XCTAssertTrue(cleaned.summary.contains("Speaker 1"))
    }
}
