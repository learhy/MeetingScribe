import XCTest
@testable import MeetingScribe

final class NotesLabelCleanerTests: XCTestCase {

    // MARK: - Basic Cleaning

    func testClean_ResolvedName() {
        let labelMap = [
            "SPEAKER_00": CanonicalName(displayName: "Rachana", source: .contacts, confidence: 0.9)
        ]
        let result = NotesLabelCleaner.clean("SPEAKER_00 discussed the roadmap", labelMap: labelMap)
        XCTAssertEqual(result, "Rachana discussed the roadmap")
    }

    func testClean_UnresolvedLabel_BecomesSpeakerN() {
        let result = NotesLabelCleaner.clean("SPEAKER_00 discussed the roadmap", labelMap: [:])
        XCTAssertEqual(result, "Speaker 0 discussed the roadmap")
    }

    func testClean_MultipleSpeakers() {
        let labelMap = [
            "SPEAKER_00": CanonicalName(displayName: "Rachana", source: .contacts, confidence: 0.9),
            "SPEAKER_01": CanonicalName(displayName: "Dan", source: .voiceMatch, confidence: 0.85)
        ]
        let result = NotesLabelCleaner.clean("SPEAKER_00 and SPEAKER_01 agreed on the plan", labelMap: labelMap)
        XCTAssertEqual(result, "Rachana and Dan agreed on the plan")
    }

    func testClean_NoLabels_NoChange() {
        let labelMap = [
            "SPEAKER_00": CanonicalName(displayName: "Rachana", source: .contacts, confidence: 0.9)
        ]
        let result = NotesLabelCleaner.clean("Dan and Rachana discussed the roadmap", labelMap: labelMap)
        XCTAssertEqual(result, "Dan and Rachana discussed the roadmap")
    }

    func testClean_MultipleOccurrences() {
        let labelMap = [
            "SPEAKER_00": CanonicalName(displayName: "Rachana", source: .contacts, confidence: 0.9)
        ]
        let result = NotesLabelCleaner.clean("SPEAKER_00 said X. Then SPEAKER_00 said Y.", labelMap: labelMap)
        XCTAssertEqual(result, "Rachana said X. Then Rachana said Y.")
    }

    // MARK: - Edge Cases

    func testClean_MixedResolvedAndUnresolved() {
        let labelMap = [
            "SPEAKER_00": CanonicalName(displayName: "Rachana", source: .contacts, confidence: 0.9)
        ]
        let result = NotesLabelCleaner.clean("SPEAKER_00 and SPEAKER_01 discussed the plan", labelMap: labelMap)
        XCTAssertEqual(result, "Rachana and Speaker 1 discussed the plan")
    }

    func testClean_EmptyString() {
        let result = NotesLabelCleaner.clean("", labelMap: [:])
        XCTAssertEqual(result, "")
    }

    func testClean_OnlySpeakerLabel() {
        let labelMap = [
            "SPEAKER_00": CanonicalName(displayName: "Dan", source: .voiceMatch, confidence: 0.9)
        ]
        let result = NotesLabelCleaner.clean("SPEAKER_00", labelMap: labelMap)
        XCTAssertEqual(result, "Dan")
    }

    // MARK: - cleanSummaryAndNotes

    func testCleanSummaryAndNotes_BothCleaned() {
        let labelMap = [
            "SPEAKER_00": CanonicalName(displayName: "Rachana", source: .contacts, confidence: 0.9)
        ]
        let result = NotesLabelCleaner.cleanSummaryAndNotes(
            summary: "SPEAKER_00 led the meeting",
            notes: "SPEAKER_00 presented the roadmap",
            labelMap: labelMap
        )
        XCTAssertEqual(result.summary, "Rachana led the meeting")
        XCTAssertEqual(result.notes, "Rachana presented the roadmap")
    }

    func testCleanSummaryAndNotes_NoLabels() {
        let result = NotesLabelCleaner.cleanSummaryAndNotes(
            summary: "Team discussed roadmap",
            notes: "Key decisions made",
            labelMap: [:]
        )
        XCTAssertEqual(result.summary, "Team discussed roadmap")
        XCTAssertEqual(result.notes, "Key decisions made")
    }

    // MARK: - Label Format Variations

    func testClean_Speaker00() {
        let labelMap = [
            "SPEAKER_00": CanonicalName(displayName: "Dan", source: .voiceMatch, confidence: 0.9)
        ]
        let result = NotesLabelCleaner.clean("SPEAKER_00 spoke", labelMap: labelMap)
        XCTAssertEqual(result, "Dan spoke")
    }

    func testClean_Speaker09() {
        let result = NotesLabelCleaner.clean("SPEAKER_09 spoke", labelMap: [:])
        XCTAssertEqual(result, "Speaker 9 spoke")
    }

    func testClean_PreservesSurroundingText() {
        let labelMap = [
            "SPEAKER_01": CanonicalName(displayName: "Rachana", source: .contacts, confidence: 0.9)
        ]
        let result = NotesLabelCleaner.clean("**Key Point:** SPEAKER_01 raised the concern about timelines.", labelMap: labelMap)
        XCTAssertEqual(result, "**Key Point:** Rachana raised the concern about timelines.")
    }
}