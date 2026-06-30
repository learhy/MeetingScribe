import XCTest
@testable import MeetingScribe

final class TitleValidatorTests: XCTestCase {

    // MARK: - Validation Tests

    func testValidateValidTitle() {
        let result = TitleValidator.validate("Q3 Planning Discussion")
        XCTAssertEqual(result, "Q3 Planning Discussion")
    }

    func testValidateEmptyString() {
        let result = TitleValidator.validate("")
        XCTAssertNil(result)
    }

    func testValidateWhitespaceOnly() {
        let result = TitleValidator.validate("   \n\t  ")
        XCTAssertNil(result)
    }

    // MARK: - Refusal Pattern Tests

    func testValidateRefusalIDontSeeTranscript() {
        let result = TitleValidator.validate("I don't see a transcript in your message. Could you please provide...")
        XCTAssertNil(result)
    }

    func testValidateRefusalIDBeHappyToHelp() {
        let result = TitleValidator.validate("I'd be happy to help generate meeting notes, but I need the transcript.")
        XCTAssertNil(result)
    }

    func testValidateRefusalCouldYouPleaseProvide() {
        let result = TitleValidator.validate("Could you please provide the meeting transcript?")
        XCTAssertNil(result)
    }

    func testValidateRefusalOnceYouShare() {
        let result = TitleValidator.validate("Once you share the transcript, I'll generate the notes.")
        XCTAssertNil(result)
    }

    func testValidateRefusalUnableToGenerate() {
        let result = TitleValidator.validate("Unable to Generate Meeting Title")
        XCTAssertNil(result)
    }

    func testValidateRefusalCorrectionRequest() {
        let result = TitleValidator.validate("Meeting Transcript Correction Request [Pending]")
        XCTAssertNil(result)
    }

    func testValidateRefusalNoTranscript() {
        let result = TitleValidator.validate("No transcript provided for this meeting.")
        XCTAssertNil(result)
    }

    // MARK: - Meta Pattern Tests

    func testValidateMetaCorrectedTranscript() {
        let result = TitleValidator.validate("Here is the corrected transcript:")
        XCTAssertNil(result)
    }

    func testValidateMetaGeneratedNotes() {
        let result = TitleValidator.validate("Generated meeting notes:")
        XCTAssertNil(result)
    }

    func testValidateMetaMeetingNotesColon() {
        let result = TitleValidator.validate("Meeting notes: Q3 Planning")
        XCTAssertNil(result)
    }

    // MARK: - Fallback Chain Tests

    func testResolveLLMTitleValid() {
        let date = Date()
        let result = TitleValidator.resolve(
            llmTitle: "Q3 Roadmap Planning",
            calendarTitle: nil,
            date: date
        )
        XCTAssertEqual(result, "Q3 Roadmap Planning")
    }

    func testResolveLLMTitleInvalidFallsToCalendar() {
        let date = Date()
        let result = TitleValidator.resolve(
            llmTitle: "I don't see a transcript in your message.",
            calendarTitle: "Weekly Team Sync",
            date: date
        )
        XCTAssertEqual(result, "Weekly Team Sync")
    }

    func testResolveLLMTitleInvalidAndNoCalendarFallsToDate() {
        let date = Date()
        let result = TitleValidator.resolve(
            llmTitle: "Unable to Generate Meeting Title",
            calendarTitle: nil,
            date: date
        )

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let expected = "Meeting Notes - \(formatter.string(from: date))"
        XCTAssertEqual(result, expected)
    }

    func testResolveNilLLMTitleFallsToCalendar() {
        let date = Date()
        let result = TitleValidator.resolve(
            llmTitle: nil,
            calendarTitle: "1:1 with Anando",
            date: date
        )
        XCTAssertEqual(result, "1:1 with Anando")
    }

    func testResolveAllNilFallsToDate() {
        let date = Date()
        let result = TitleValidator.resolve(
            llmTitle: nil,
            calendarTitle: nil,
            date: date
        )

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let expected = "Meeting Notes - \(formatter.string(from: date))"
        XCTAssertEqual(result, expected)
    }

    // MARK: - Disambiguation Tests

    func testIsBareOneOnOnePattern() {
        XCTAssertTrue(TitleValidator.isBareOneOnOnePattern("Dan/Anando 1:1"))
        XCTAssertTrue(TitleValidator.isBareOneOnOnePattern("Dan/Rachana 1:1"))
        XCTAssertTrue(TitleValidator.isBareOneOnOnePattern("Dan/Aman/Krishnan 1:1"))
    }

    func testIsNotBareOneOnOnePattern() {
        XCTAssertFalse(TitleValidator.isBareOneOnOnePattern("Q3 Planning Discussion"))
        XCTAssertFalse(TitleValidator.isBareOneOnOnePattern("Dan/Anando 1:1: PEDM Discussion"))
        XCTAssertFalse(TitleValidator.isBareOneOnOnePattern("Weekly Team Sync"))
    }

    func testDisambiguateWithTopic() {
        let date = Date()
        let result = TitleValidator.disambiguate(
            title: "Dan/Anando 1:1",
            topic: "PEDM vs Agentic Prioritization",
            date: date
        )
        XCTAssertEqual(result, "Dan/Anando 1:1: PEDM vs Agentic Prioritization")
    }

    func testDisambiguateWithNilTopic() {
        let date = Date()
        let result = TitleValidator.disambiguate(
            title: "Dan/Anando 1:1",
            topic: nil,
            date: date
        )

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        let expected = "Dan/Anando 1:1 - \(formatter.string(from: date))"
        XCTAssertEqual(result, expected)
    }

    func testDisambiguateWithEmptyTopic() {
        let date = Date()
        let result = TitleValidator.disambiguate(
            title: "Dan/Anando 1:1",
            topic: "",
            date: date
        )

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        let expected = "Dan/Anando 1:1 - \(formatter.string(from: date))"
        XCTAssertEqual(result, expected)
    }

    func testDisambiguateNonBarePatternUnchanged() {
        let date = Date()
        let result = TitleValidator.disambiguate(
            title: "Q3 Planning Discussion",
            topic: "Some topic",
            date: date
        )
        XCTAssertEqual(result, "Q3 Planning Discussion")
    }

    // MARK: - Topic Extraction Tests

    func testExtractTopicFromSummary() {
        let summary = "The team discussed the Q3 roadmap priorities and aligned on the PEDM framework."
        let topic = TitleValidator.extractTopic(from: summary)
        XCTAssertEqual(topic, "The team discussed the Q3 roadmap priorities and aligned on the PEDM framework")
    }

    func testExtractTopicFromBulletPoint() {
        let summary = "- Discussed the roadmap priorities for Q3"
        let topic = TitleValidator.extractTopic(from: summary)
        XCTAssertEqual(topic, "Discussed the roadmap priorities for Q3")
    }

    func testExtractTopicFromMultiline() {
        let summary = "First line topic\nSecond line content\nThird line"
        let topic = TitleValidator.extractTopic(from: summary)
        XCTAssertEqual(topic, "First line topic")
    }

    func testExtractTopicFromEmpty() {
        let topic = TitleValidator.extractTopic(from: "")
        XCTAssertNil(topic)
    }

    func testExtractTopicFromWhitespace() {
        let topic = TitleValidator.extractTopic(from: "  \n  \t  ")
        XCTAssertNil(topic)
    }

    // MARK: - Edge Cases

    func testValidateLongTitleThatIsASentence() {
        let longTitle = "This is a very long title that goes on and on and is clearly a sentence rather than a meeting title because it contains way too many words to be a proper concise title"
        let result = TitleValidator.validate(longTitle)
        // Over 120 chars and looks like a sentence
        XCTAssertNil(result)
    }

    func testValidateTitleWithQuotes() {
        let result = TitleValidator.validate("\"Q3 Planning\"")
        XCTAssertEqual(result, "Q3 Planning")
    }

    func testValidateTitleWithSingleQuotes() {
        let result = TitleValidator.validate("'Q3 Planning'")
        XCTAssertEqual(result, "Q3 Planning")
    }

    func testValidateShortTitleWithPeriod() {
        // Short titles ending in period should be valid
        let result = TitleValidator.validate("Q3 Planning.")
        XCTAssertEqual(result, "Q3 Planning.")
    }
}