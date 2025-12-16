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
}
