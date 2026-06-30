import XCTest
@testable import MeetingScribe

final class NotesLabelCleanerTests: XCTestCase {

    // MARK: - Basic Cleaning Tests

    func testCleanSingleSpeakerLabel() {
        let text = "SPEAKER_00 discussed the roadmap"
        let labelMap: [String: CanonicalName] = [
            "SPEAKER_00": CanonicalName(displayName: "Rachana", firstName: "Rachana",
                                        source: .voiceMatch, confidence: 0.9, email: nil)
        ]

        let cleaned = NotesLabelCleaner.clean(text, labelMap: labelMap)
        XCTAssertEqual(cleaned, "Rachana discussed the roadmap")
    }

    func testCleanMultipleSpeakerLabels() {
        let text = "SPEAKER_00: Let's start.\nSPEAKER_01: Good idea."
        let labelMap: [String: CanonicalName] = [
            "SPEAKER_00": CanonicalName(displayName: "Dan", firstName: "Dan",
                                        source: .voiceMatch, confidence: 0.9, email: nil),
            "SPEAKER_01": CanonicalName(displayName: "Rachana", firstName: "Rachana",
                                        source: .voiceMatch, confidence: 0.85, email: nil)
        ]

        let cleaned = NotesLabelCleaner.clean(text, labelMap: labelMap)
        XCTAssertEqual(cleaned, "Dan: Let's start.\nRachana: Good idea.")
    }

    // MARK: - Unidentified Speaker Tests

    func testCleanUnidentifiedSpeakerUsesNeutralLabel() {
        let text = "SPEAKER_00 spoke about the timeline."
        let labelMap: [String: CanonicalName] = [:]

        let cleaned = NotesLabelCleaner.clean(text, labelMap: labelMap)
        XCTAssertEqual(cleaned, "Speaker 1 spoke about the timeline.")
    }

    func testCleanUnidentifiedSpeakerWithHighNumber() {
        let text = "SPEAKER_05 had concerns."
        let labelMap: [String: CanonicalName] = [:]

        let cleaned = NotesLabelCleaner.clean(text, labelMap: labelMap)
        XCTAssertEqual(cleaned, "Speaker 6 had concerns.")
    }

    // MARK: - No Labels Tests

    func testCleanNoLabelsReturnsOriginal() {
        let text = "The team discussed the roadmap."
        let labelMap: [String: CanonicalName] = [
            "SPEAKER_00": CanonicalName(displayName: "Dan", firstName: "Dan",
                                        source: .voiceMatch, confidence: 0.9, email: nil)
        ]

        let cleaned = NotesLabelCleaner.clean(text, labelMap: labelMap)
        XCTAssertEqual(cleaned, "The team discussed the roadmap.")
    }

    // MARK: - Mixed Tests

    func testCleanMixedResolvedAndUnresolved() {
        let text = "SPEAKER_00 and SPEAKER_01 discussed the project. SPEAKER_02 joined later."
        let labelMap: [String: CanonicalName] = [
            "SPEAKER_00": CanonicalName(displayName: "Dan", firstName: "Dan",
                                        source: .voiceMatch, confidence: 0.9, email: nil),
            "SPEAKER_01": CanonicalName(displayName: "Rachana", firstName: "Rachana",
                                        source: .voiceMatch, confidence: 0.85, email: nil)
        ]

        let cleaned = NotesLabelCleaner.clean(text, labelMap: labelMap)
        XCTAssertEqual(cleaned, "Dan and Rachana discussed the project. Speaker 3 joined later.")
    }

    // MARK: - Display Name Map Tests

    func testCleanWithDisplayNameMap() {
        let text = "SPEAKER_00 presented the slides."
        let displayNameMap: [String: String] = ["SPEAKER_00": "Anando"]

        let cleaned = NotesLabelCleaner.clean(text, displayNameMap: displayNameMap)
        XCTAssertEqual(cleaned, "Anando presented the slides.")
    }

    func testCleanWithDisplayNameMapUnresolved() {
        let text = "SPEAKER_01 asked a question."
        let displayNameMap: [String: String] = [:]

        let cleaned = NotesLabelCleaner.clean(text, displayNameMap: displayNameMap)
        XCTAssertEqual(cleaned, "Speaker 2 asked a question.")
    }

    // MARK: - Edge Cases

    func testCleanEmptyString() {
        let cleaned = NotesLabelCleaner.clean("", labelMap: [:])
        XCTAssertEqual(cleaned, "")
    }

    func testCleanMultipleOccurrencesSameLabel() {
        let text = "SPEAKER_00 said this. Then SPEAKER_00 said that."
        let labelMap: [String: CanonicalName] = [
            "SPEAKER_00": CanonicalName(displayName: "Dan", firstName: "Dan",
                                        source: .voiceMatch, confidence: 0.9, email: nil)
        ]

        let cleaned = NotesLabelCleaner.clean(text, labelMap: labelMap)
        XCTAssertEqual(cleaned, "Dan said this. Then Dan said that.")
    }

    // MARK: - Sections Tests

    func testCleanMultipleSections() {
        let sections = [
            "SPEAKER_00 presented the roadmap.",
            "SPEAKER_01 raised concerns about the timeline."
        ]
        let labelMap: [String: CanonicalName] = [
            "SPEAKER_00": CanonicalName(displayName: "Dan", firstName: "Dan",
                                        source: .voiceMatch, confidence: 0.9, email: nil),
            "SPEAKER_01": CanonicalName(displayName: "Rachana", firstName: "Rachana",
                                        source: .voiceMatch, confidence: 0.85, email: nil)
        ]

        let cleaned = NotesLabelCleaner.clean(sections: sections, labelMap: labelMap)
        XCTAssertEqual(cleaned[0], "Dan presented the roadmap.")
        XCTAssertEqual(cleaned[1], "Rachana raised concerns about the timeline.")
    }
}