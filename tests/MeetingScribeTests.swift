import XCTest
@testable import MeetingScribe

final class MeetingScribeTests: XCTestCase {
    func testGeneratedNotesParserSplitsSummaryAndNotes() throws {
        let input = """
        # Meeting Notes: Kubernetes Rollout - Eastern Washington

        ## Summary
        Brief coordination meeting led by Dan.

        ## Key Points
        - Point A
        - Point B

        ## Action Items
        - Dan: follow up
        """

        let result = GeneratedNotesParser.split(input)

        XCTAssertEqual(result.summary, "Brief coordination meeting led by Dan.")
        XCTAssertFalse(result.notes.contains("## Summary"))
        XCTAssertFalse(result.notes.lowercased().contains("meeting notes"))
        XCTAssertTrue(result.notes.contains("## Key Points"))
        XCTAssertTrue(result.notes.contains("## Action Items"))
    }

    func testGeneratedNotesParserWithoutSummaryKeepsContentAsNotes() throws {
        let input = """
        # Meeting Notes: Something

        - Bullet 1
        - Bullet 2
        """

        let result = GeneratedNotesParser.split(input)

        XCTAssertEqual(result.summary, "")
        XCTAssertTrue(result.notes.contains("- Bullet 1"))
        XCTAssertFalse(result.notes.lowercased().contains("meeting notes"))
    }

    // MARK: - Preamble Stripping Tests

    func testGeneratedNotesParserStripsHereIsTheCorrectedTranscript() throws {
        let input = """
        Here is the corrected transcript:

        ## Summary
        The meeting covered Q3 planning.

        ## Notes
        - Key decisions made
        """

        let result = GeneratedNotesParser.split(input)

        XCTAssertEqual(result.summary, "The meeting covered Q3 planning.")
        XCTAssertFalse(result.notes.lowercased().contains("here is the corrected transcript"))
        XCTAssertFalse(result.summary.lowercased().contains("here is the corrected transcript"))
    }

    func testGeneratedNotesParserStripsOnceYouShareTranscript() throws {
        let input = """
        Once you share the transcript, I'll generate the notes.

        ## Summary
        Roadmap discussion happened.

        ## Notes
        - Point A
        """

        let result = GeneratedNotesParser.split(input)

        XCTAssertEqual(result.summary, "Roadmap discussion happened.")
        XCTAssertFalse(result.summary.lowercased().contains("once you share"))
    }

    func testGeneratedNotesParserStripsIdBeHappyToHelp() throws {
        let input = """
        I'd be happy to help generate meeting notes, but I don't see a transcript.

        ## Summary
        Actual summary here.

        ## Notes
        - Real content
        """

        let result = GeneratedNotesParser.split(input)

        XCTAssertEqual(result.summary, "Actual summary here.")
        XCTAssertFalse(result.summary.lowercased().contains("happy to help"))
    }

    func testGeneratedNotesParserStripsBelowAreMeetingNotes() throws {
        let input = """
        Below are the meeting notes:

        ## Summary
        Sprint review notes.

        ## Notes
        - Sprint completed
        """

        let result = GeneratedNotesParser.split(input)

        XCTAssertEqual(result.summary, "Sprint review notes.")
        XCTAssertFalse(result.summary.lowercased().contains("below are"))
    }

    func testGeneratedNotesParserStripsSureHereAreMeetingNotes() throws {
        let input = """
        Sure, here are the meeting notes:

        ## Summary
        Architecture discussion.

        ## Notes
        - Design approved
        """

        let result = GeneratedNotesParser.split(input)

        XCTAssertEqual(result.summary, "Architecture discussion.")
        XCTAssertFalse(result.summary.lowercased().contains("sure, here are"))
    }
}
