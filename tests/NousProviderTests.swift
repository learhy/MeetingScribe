import XCTest
@testable import MeetingScribe

final class NousProviderTests: XCTestCase {

    // MARK: - Config decoding

    func testConfigDecode_WithNousSection_ParsesAllFields() throws {
        let json = """
        {
          "provider": "nous",
          "nous": {
            "apiKey": "test-key",
            "model": "z-ai/glm-5.3-flash",
            "authTokenFile": "/tmp/token.json"
          }
        }
        """
        let data = Data(json.utf8)
        let llm = try JSONDecoder().decode(AppConfiguration.Notes.LLM.self, from: data)
        XCTAssertEqual(llm.provider, "nous")
        XCTAssertEqual(llm.nous.apiKey, "test-key")
        XCTAssertEqual(llm.nous.model, "z-ai/glm-5.3-flash")
        XCTAssertEqual(llm.nous.authTokenFile, "/tmp/token.json")
    }

    func testConfigDecode_WithoutNousSection_UsesDefaults() throws {
        // Configs written before the nous section existed must still decode,
        // and other provider fields must survive the round-trip.
        let json = """
        {
          "provider": "anthropic",
          "anthropic": { "apiKey": "sk-ant-test", "model": "claude-sonnet-4-5" }
        }
        """
        let data = Data(json.utf8)
        let llm = try JSONDecoder().decode(AppConfiguration.Notes.LLM.self, from: data)
        XCTAssertEqual(llm.provider, "anthropic")
        XCTAssertEqual(llm.anthropic.apiKey, "sk-ant-test")
        XCTAssertEqual(llm.nous.apiKey, "")
        XCTAssertEqual(llm.nous.model, "z-ai/glm-5.3-flash")
        XCTAssertEqual(llm.nous.authTokenFile, "")
    }

    func testConfigDecode_MissingProviderSections_UsesDefaults() throws {
        // Hand-edited minimal config: no llm sections at all
        let json = """
        { "provider": "nous" }
        """
        let data = Data(json.utf8)
        let llm = try JSONDecoder().decode(AppConfiguration.Notes.LLM.self, from: data)
        XCTAssertEqual(llm.provider, "nous")
        XCTAssertTrue(llm.nous.apiKey.isEmpty)
    }

    // MARK: - Reasoning stripping

    func testStripThinking_RemovesClosedBlocks() {
        let input = "<think>Let me analyze this transcript.</think>\n## Summary\nDiscussed roadmap."
        XCTAssertEqual(NousProvider.stripThinking(from: input), "## Summary\nDiscussed roadmap.")
    }

    func testStripThinking_MultipleBlocks() {
        let input = "<think>one</think>Answer A<think>two</think>Answer B"
        XCTAssertEqual(NousProvider.stripThinking(from: input), "Answer AAnswer B")
    }

    func testStripThinking_LeavesPlainText() {
        XCTAssertEqual(NousProvider.stripThinking(from: "Plain notes"), "Plain notes")
    }

    func testStripThinking_EmptyAfterStrip() {
        XCTAssertTrue(NousProvider.stripThinking(from: "<think>only reasoning</think>").isEmpty)
    }

    // MARK: - Token staleness

    func testIsTokenStale_NilOrEmpty_IsStale() {
        XCTAssertTrue(NousProvider.isTokenStale(nil))
        XCTAssertTrue(NousProvider.isTokenStale(""))
    }

    func testIsTokenStale_Garbage_IsStale() {
        XCTAssertTrue(NousProvider.isTokenStale("not-a-date"))
    }

    func testIsTokenStale_FutureTimestamp_IsFresh() {
        let future = Date().addingTimeInterval(3600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertFalse(NousProvider.isTokenStale(formatter.string(from: future)))
    }

    func testIsTokenStale_WithinSkew_IsStale() {
        // 60s from now is inside the default 300s refresh skew
        let soon = Date().addingTimeInterval(60)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertTrue(NousProvider.isTokenStale(formatter.string(from: soon)))
    }

    func testIsTokenStale_PastTimestamp_IsStale() {
        let past = Date().addingTimeInterval(-3600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertTrue(NousProvider.isTokenStale(formatter.string(from: past)))
    }

    func testIsTokenStale_PortalStyleOffsetFormat_Parses() {
        // Hermes' shared store uses "+00:00" offsets
        let future = Date().addingTimeInterval(3600)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: future)
        let stamp = String(format: "%04d-%02d-%02dT%02d:%02d:%02d+00:00",
                           comps.year!, comps.month!, comps.day!, comps.hour!, comps.minute!, comps.second!)
        XCTAssertFalse(NousProvider.isTokenStale(stamp), "portal-style ISO string must parse as fresh")
    }

    // MARK: - Live network test (opt-in)

    /// End-to-end: OAuth token file -> Nous inference API -> parsed content.
    /// Skipped unless explicitly requested:
    ///   NOUS_LIVE_TEST=1 xcrun swift test --filter MeetingScribeTests.NousProviderTests/testLiveNousGeneration
    func testLiveNousGeneration() async throws {
        guard ProcessInfo.processInfo.environment["NOUS_LIVE_TEST"] == "1" else {
            throw XCTSkip("Live Nous test disabled (set NOUS_LIVE_TEST=1)")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tokenFile = home.appendingPathComponent(".hermes/shared/nous_auth.json").path
        guard FileManager.default.fileExists(atPath: tokenFile) else {
            throw XCTSkip("No Nous token file at ~/.hermes/shared/nous_auth.json")
        }
        let provider = NousProvider(
            apiKey: "",
            model: "z-ai/glm-5.3-flash",
            authTokenFile: "~/.hermes/shared/nous_auth.json",
            timeoutSeconds: 60
        )
        let reply = try await provider.generate(
            userMessage: "Reply with exactly: NOUS-OK",
            systemPrompt: "You are a connectivity test. Reply with exactly: NOUS-OK"
        )
        XCTAssertTrue(reply.contains("NOUS-OK"), "unexpected reply: \(reply.prefix(200))")
    }
}
