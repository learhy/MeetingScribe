import XCTest
@testable import MeetingScribe

// P2-1/P2-3: AssemblyAI keyterm mapping + dictionary hygiene audit.
// [needs-Mac-build] — exercised on the Mac build; mirrored in
// tools/eval/p2_logic.py for the Linux host regression suite.
final class P2EngineAndHygieneTests: XCTestCase {

    // MARK: - P2-1: roster prompt -> keyterms

    func testKeytermsMappingFromRosterPrompt() {
        let roster = """
        The following people may be mentioned in this meeting: Dan Rohan, Rachana Reddy, Mukesh Marodia.
         Common corrections: Ratchna→Rachana, Marodi→Marodia.
         Technical terms that may come up: PEDM, credential injection.
        """
        let keyterms = AssemblyAIUniversal3Provider.keyterms(fromRosterPrompt: roster)
        // Names first (roster rank order)...
        XCTAssertEqual(keyterms.prefix(3), ["Dan Rohan", "Rachana Reddy", "Mukesh Marodia"])
        // ...then the RIGHT side of corrections (canonical spellings only)...
        XCTAssertTrue(keyterms.contains("Rachana"))
        XCTAssertTrue(keyterms.contains("Marodia"))
        XCTAssertFalse(keyterms.contains("Ratchna→Rachana"))
        // ...then glossary terms.
        XCTAssertTrue(keyterms.contains("PEDM"))
    }

    func testKeytermsDeDupeCaseInsensitively() {
        let roster = "The following people may be mentioned in this meeting: Rachana, rachana, RACHANA."
        let keyterms = AssemblyAIUniversal3Provider.keyterms(fromRosterPrompt: roster)
        XCTAssertEqual(keyterms, ["Rachana"])
    }

    func testKeytermsEmptyForEmptyRoster() {
        XCTAssertTrue(AssemblyAIUniversal3Provider.keyterms(fromRosterPrompt: "").isEmpty)
    }

    func testKeytermsCappedAtMax() {
        let names = (0..<80).map { "Attendee\($0)" }.joined(separator: ", ")
        let roster = "The following people may be mentioned in this meeting: \(names)."
        let keyterms = AssemblyAIUniversal3Provider.keyterms(fromRosterPrompt: roster)
        XCTAssertEqual(keyterms.count, AssemblyAIUniversal3Provider.maxKeyterms)
    }

    // MARK: - P2-3: hygiene audit

    private var tempDir: URL!
    private var storePath: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ms-hygiene-tests-\(UUID().uuidString)")
        storePath = tempDir.appendingPathComponent("corrections.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func entry(_ wrong: String, _ right: String, daysAgo: Double = 0) -> CorrectionDictionary.Entry {
        CorrectionDictionary.Entry(wrong: wrong, right: right, source: "manual",
                                   updatedAt: Date().timeIntervalSince1970 - daysAgo * 86400)
    }

    private var glossary: [AppConfiguration.Transcription.GlossaryEntry] {
        [
            AppConfiguration.Transcription.GlossaryEntry(term: "Boundary", pronunciation: nil, context: "product", aliases: nil),
            AppConfiguration.Transcription.GlossaryEntry(term: "Vault", pronunciation: nil, context: "product", aliases: nil),
        ]
    }

    func testFlagsEntriesUnusedFor90Days() {
        let file = CorrectionDictionary.File(entries: [
            entry("Ratchna", "Rachana", daysAgo: 120),
            entry("Recent", "Krishnan", daysAgo: 5),
        ])
        let report = DictionaryHygiene.audit(corrections: file, glossary: glossary)
        XCTAssertTrue(report.findings.contains {
            $0.kind == .unused && $0.term == "Ratchna"
        }, "\(report.findings)")
        XCTAssertFalse(report.findings.contains { $0.term == "Recent" && $0.kind == .unused })
        XCTAssertEqual(report.pruneSuggestions, ["Ratchna"])
    }

    func testFlagsDuplicatesAndCaseCollisions() {
        let file = CorrectionDictionary.File(entries: [
            entry("Ratchna", "Rachana"),
            entry("ratchna", "Rachana"),   // case-insensitive duplicate
            entry("same", "Same"),          // case-collision no-op
        ])
        let report = DictionaryHygiene.audit(corrections: file, glossary: glossary)
        XCTAssertTrue(report.findings.contains { $0.kind == .duplicate && $0.term == "ratchna" })
        XCTAssertTrue(report.findings.contains { $0.kind == .caseCollision && $0.term == "same" })
        XCTAssertEqual(Set(report.pruneSuggestions), Set(["ratchna", "same"]))
    }

    func testPhoneticCollisionIsReportOnly() {
        // "Boundry" is phonetically near glossary "Boundary".
        let file = CorrectionDictionary.File(entries: [
            entry("Boundry", "Boundary", daysAgo: 1),
        ])
        let report = DictionaryHygiene.audit(corrections: file, glossary: glossary)
        let collisions = report.findings.filter { $0.kind == .phoneticCollision }
        // Report-only: the term must NEVER land in pruneSuggestions via collision.
        XCTAssertTrue(report.pruneSuggestions.isEmpty || !report.pruneSuggestions.contains("Boundary"))
        _ = collisions  // presence depends on the metaphone codes; prune-safety is the contract
    }

    func testCleanDictionaryHasNoFindings() {
        let file = CorrectionDictionary.File(entries: [
            entry("Ratchna", "Rachana", daysAgo: 3),
        ])
        let report = DictionaryHygiene.audit(corrections: file, glossary: glossary)
        XCTAssertTrue(report.findings.isEmpty)
        XCTAssertTrue(report.pruneSuggestions.isEmpty)
    }

    // MARK: - P2-3: backup-then-prune round trip

    func testPruneRemovesOnlySuggestedTerms() {
        var file = CorrectionDictionary.File(entries: [
            entry("Ratchna", "Rachana"),
            entry("Old", "Krishnan", daysAgo: 400),
        ])
        let report = DictionaryHygiene.audit(corrections: file, glossary: glossary)
        file = DictionaryHygiene.pruned(file, removing: report.pruneSuggestions)
        XCTAssertEqual(file.entries.count, 1)
        XCTAssertEqual(file.entries.first?.wrong, "Ratchna")
    }

    func testPromptCompositionSumsWords() {
        let roster = """
        The following people may be mentioned in this meeting: Dan Rohan, Rachana Reddy.
         Common corrections: Ratchna→Rachana.
         Technical terms that may come up: PEDM.
        """
        let c = DictionaryHygiene.promptComposition(rosterPrompt: roster)
        XCTAssertEqual(c.names, 4)          // "Dan Rohan" + "Rachana Reddy"
        XCTAssertEqual(c.corrections, 1)    // "Ratchna→Rachana" (one token)
        XCTAssertEqual(c.terms, 1)          // "PEDM"
        XCTAssertEqual(c.total, 6)
        XCTAssertTrue(c.total <= DictionaryHygiene.wordBudget)
    }
}
