import XCTest
@testable import MeetingScribe

final class TitleValidatorTests: XCTestCase {

    // MARK: - validate()

    func testValidate_ValidTitle() {
        let result = TitleValidator.validate("Q3 Roadmap Discussion")
        XCTAssertEqual(result, "Q3 Roadmap Discussion")
    }

    func testValidate_EmptyString() {
        XCTAssertNil(TitleValidator.validate(""))
    }

    func testValidate_WhitespaceOnly() {
        XCTAssertNil(TitleValidator.validate("   "))
    }

    func testValidate_TooShort() {
        XCTAssertNil(TitleValidator.validate("AB"))
    }

    func testValidate_RefusalText_HappyToHelp() {
        XCTAssertNil(TitleValidator.validate("I'd be happy to help generate meeting notes, but I don't see a transcript"))
    }

    func testValidate_RefusalText_DontSeeTranscript() {
        XCTAssertNil(TitleValidator.validate("I don't see a transcript in your message. Could you please provide it?"))
    }

    func testValidate_RefusalText_UnableToGenerate() {
        XCTAssertNil(TitleValidator.validate("Unable to Generate Meeting Title"))
    }

    func testValidate_RefusalText_CorrectionRequest() {
        XCTAssertNil(TitleValidator.validate("Meeting Transcript Correction Request [Pending]"))
    }

    func testValidate_RefusalText_OnceYouShare() {
        XCTAssertNil(TitleValidator.validate("Once you share the transcript, I'll generate notes"))
    }

    func testValidate_LongSentence() {
        // A long sentence ending with period is not a title
        let longSentence = "This is a very long sentence that describes what happened in the meeting in great detail and goes on for a while."
        XCTAssertNil(TitleValidator.validate(longSentence))
    }

    func testValidate_QuotesStripped() {
        let result = TitleValidator.validate("\"Q3 Planning\"")
        XCTAssertEqual(result, "Q3 Planning")
    }

    func testValidate_SingleQuotesStripped() {
        let result = TitleValidator.validate("'Q3 Planning'")
        XCTAssertEqual(result, "Q3 Planning")
    }

    func testValidate_TruncationAt100Chars() {
        let long = String(repeating: "A", count: 120)
        let result = TitleValidator.validate(long)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.count <= 100)
    }

    // MARK: - resolve()

    func testResolve_CalendarTitlePrimary() {
        let date = Date()
        let result = TitleValidator.resolve(
            llmTitle: "Some LLM Title",
            calendarTitle: "Q3 Planning Session",
            date: date
        )
        XCTAssertEqual(result, "Q3 Planning Session")
    }

    func testResolve_LLMWhenNoCalendar() {
        let date = Date()
        let result = TitleValidator.resolve(
            llmTitle: "Sprint Review Notes",
            calendarTitle: nil,
            date: date
        )
        XCTAssertEqual(result, "Sprint Review Notes")
    }

    func testResolve_LLMRefusalFallsBackToDate() {
        let date = Date()
        let result = TitleValidator.resolve(
            llmTitle: "I'd be happy to help generate meeting notes",
            calendarTitle: nil,
            date: date
        )
        XCTAssertTrue(result.hasPrefix("Meeting Notes - "))
    }

    func testResolve_BothInvalid_FallsBackToDate() {
        let date = Date()
        let result = TitleValidator.resolve(
            llmTitle: "Unable to Generate Meeting Title",
            calendarTitle: "",
            date: date
        )
        XCTAssertTrue(result.hasPrefix("Meeting Notes - "))
    }

    func testResolve_EmptyCalendar_UsesLLM() {
        let date = Date()
        let result = TitleValidator.resolve(
            llmTitle: "Architecture Review",
            calendarTitle: "",
            date: date
        )
        XCTAssertEqual(result, "Architecture Review")
    }

    // MARK: - disambiguate()

    func testDisambiguate_BarePatternWithTopic() {
        let date = Date()
        let result = TitleValidator.disambiguate(
            title: "Dan/Anando 1:1",
            topic: "PEDM vs Agentic Prioritization",
            date: date
        )
        XCTAssertEqual(result, "Dan/Anando 1:1: PEDM vs Agentic Prioritization")
    }

    func testDisambiguate_BarePatternNoTopic_AppendsDate() {
        let date = Date()
        let result = TitleValidator.disambiguate(
            title: "Dan/Rachana 1:1",
            topic: nil,
            date: date
        )
        XCTAssertTrue(result.hasPrefix("Dan/Rachana 1:1 - "))
    }

    func testDisambiguate_NotBarePattern_NoChange() {
        let date = Date()
        let result = TitleValidator.disambiguate(
            title: "Q3 Roadmap Planning",
            topic: "Some topic",
            date: date
        )
        XCTAssertEqual(result, "Q3 Roadmap Planning")
    }

    func testDisambiguate_BarePatternWithSpaces() {
        let date = Date()
        let result = TitleValidator.disambiguate(
            title: "Dan / Anando 1:1",
            topic: "Roadmap discussion",
            date: date
        )
        XCTAssertEqual(result, "Dan / Anando 1:1: Roadmap discussion")
    }

    func testDisambiguate_EmptyTopic_AppendsDate() {
        let date = Date()
        let result = TitleValidator.disambiguate(
            title: "Dan/Lauren 1:1",
            topic: "",
            date: date
        )
        XCTAssertTrue(result.hasPrefix("Dan/Lauren 1:1 - "))
    }

    func testDisambiguate_LongTopic_Truncated() {
        let date = Date()
        let longTopic = String(repeating: "Topic content. ", count: 20)
        let result = TitleValidator.disambiguate(
            title: "Dan/Anando 1:1",
            topic: longTopic,
            date: date
        )
        // Should take just the first sentence
        XCTAssertTrue(result.hasPrefix("Dan/Anando 1:1: "))
        // The topic part should be reasonable length (not the full 300+ chars)
        let topicPart = String(result.dropFirst("Dan/Anando 1:1: ".count))
        XCTAssertTrue(topicPart.count < 100)
    }
}