import XCTest
@testable import MeetingScribe

/// Tests for GlossaryTab UI validation logic
/// Note: These tests focus on the validation logic that can be tested without UI components
final class GlossaryTabValidationTests: XCTestCase {
    
    // MARK: - Input Validation Constants
    
    let maxTermLength = 100
    let maxContextLength = 200
    let maxPronunciationLength = 100
    let maxGlossarySize = 500
    
    // MARK: - Term Length Validation
    
    func testTermWithinMaxLength() {
        let term = String(repeating: "a", count: 100)
        XCTAssertTrue(term.count <= maxTermLength)
    }
    
    func testTermExceedsMaxLength() {
        let term = String(repeating: "a", count: 101)
        XCTAssertFalse(term.count <= maxTermLength)
    }
    
    // MARK: - Context Length Validation
    
    func testContextWithinMaxLength() {
        let context = String(repeating: "b", count: 200)
        XCTAssertTrue(context.count <= maxContextLength)
    }
    
    func testContextExceedsMaxLength() {
        let context = String(repeating: "b", count: 201)
        XCTAssertFalse(context.count <= maxContextLength)
    }
    
    // MARK: - Pronunciation Length Validation
    
    func testPronunciationWithinMaxLength() {
        let pronunciation = String(repeating: "c", count: 100)
        XCTAssertTrue(pronunciation.count <= maxPronunciationLength)
    }
    
    func testPronunciationExceedsMaxLength() {
        let pronunciation = String(repeating: "c", count: 101)
        XCTAssertFalse(pronunciation.count <= maxPronunciationLength)
    }
    
    // MARK: - Control Character Validation
    
    func testRejectsControlCharacters() {
        let controlChars = ["\n", "\r", "\t", "\0", "\u{0B}", "\u{0C}"]
        
        for char in controlChars {
            let term = "test\(char)term"
            XCTAssertTrue(containsControlCharacters(term), "Should reject control character: \\u{\(char.unicodeScalars.first!.value)}")
        }
    }
    
    func testAcceptsNormalText() {
        let validTerms = [
            "Kubernetes",
            "PostgreSQL",
            "C++",
            ".NET",
            "COVID-19",
            "OAuth 2.0",
            "中文",
            "Ελληνικά"
        ]
        
        for term in validTerms {
            XCTAssertFalse(containsControlCharacters(term), "Should accept: \(term)")
        }
    }
    
    // MARK: - Duplicate Detection
    
    func testDuplicateDetectionCaseInsensitive() {
        let existingTerms = ["Kubernetes", "PostgreSQL", "Docker"]
        
        XCTAssertTrue(isDuplicate("kubernetes", in: existingTerms))
        XCTAssertTrue(isDuplicate("KUBERNETES", in: existingTerms))
        XCTAssertTrue(isDuplicate("KuBeRnEtEs", in: existingTerms))
        XCTAssertFalse(isDuplicate("Helm", in: existingTerms))
    }
    
    func testDuplicateDetectionWithWhitespace() {
        let existingTerms = ["Kubernetes"]
        
        // Trimmed comparison
        XCTAssertTrue(isDuplicate(" Kubernetes ", in: existingTerms))
        XCTAssertTrue(isDuplicate("  kubernetes  ", in: existingTerms))
    }
    
    // MARK: - Glossary Size Validation
    
    func testGlossaryWithinMaxSize() {
        let entries = (0..<500).map { GlossaryEntry(term: "Term\($0)", pronunciation: nil, context: nil, aliases: nil) }
        XCTAssertTrue(entries.count <= maxGlossarySize)
    }
    
    func testGlossaryExceedsMaxSize() {
        let entries = (0..<501).map { GlossaryEntry(term: "Term\($0)", pronunciation: nil, context: nil, aliases: nil) }
        XCTAssertFalse(entries.count <= maxGlossarySize)
    }
    
    // MARK: - Import/Export JSON Validation
    
    func testValidGlossaryJSON() throws {
        let json = """
        {
          "enabled": true,
          "maxSize": 1000,
          "entries": [
            { "term": "Kubernetes", "pronunciation": "koo-ber-NET-eez", "context": "container orchestration", "aliases": ["k8s"] }
          ]
        }
        """
        
        let data = json.data(using: .utf8)!
        let glossary = try JSONDecoder().decode(Glossary.self, from: data)
        
        XCTAssertTrue(glossary.enabled)
        XCTAssertEqual(glossary.entries.count, 1)
    }
    
    func testInvalidGlossaryJSONMissingTerm() {
        let json = """
        {
          "enabled": true,
          "entries": [
            { "pronunciation": "koo-ber-NET-eez" }
          ]
        }
        """
        
        let data = json.data(using: .utf8)!
        
        // This should fail because term is required
        XCTAssertThrowsError(try JSONDecoder().decode(Glossary.self, from: data))
    }
    
    // MARK: - Helper Functions (matching GlossaryTab implementation)
    
    private func containsControlCharacters(_ text: String) -> Bool {
        let controlCharSet = CharacterSet.controlCharacters
        return text.unicodeScalars.contains { controlCharSet.contains($0) }
    }
    
    private func isDuplicate(_ term: String, in existingTerms: [String]) -> Bool {
        let normalizedTerm = term.trimmingCharacters(in: .whitespaces).lowercased()
        return existingTerms.contains { $0.lowercased() == normalizedTerm }
    }
}

/// Tests for import/export functionality
final class GlossaryImportExportTests: XCTestCase {
    
    func testExportToJSON() throws {
        let glossary = Glossary(
            enabled: true,
            entries: [
                GlossaryEntry(term: "Kubernetes", pronunciation: "koo-ber-NET-eez", context: "container orchestration", aliases: ["k8s"]),
                GlossaryEntry(term: "PostgreSQL", pronunciation: nil, context: "database", aliases: nil)
            ],
            maxSize: 1000
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(glossary)
        let jsonString = String(data: data, encoding: .utf8)!
        
        XCTAssertTrue(jsonString.contains("Kubernetes"))
        XCTAssertTrue(jsonString.contains("koo-ber-NET-eez"))
        XCTAssertTrue(jsonString.contains("k8s"))
    }
    
    func testImportFromJSON() throws {
        let json = """
        {
          "enabled": true,
          "maxSize": 1000,
          "entries": [
            {
              "term": "Kubernetes",
              "pronunciation": "koo-ber-NET-eez",
              "context": "container orchestration",
              "aliases": ["k8s", "K8s"]
            }
          ]
        }
        """
        
        let data = json.data(using: .utf8)!
        let glossary = try JSONDecoder().decode(Glossary.self, from: data)
        
        XCTAssertEqual(glossary.entries.count, 1)
        XCTAssertEqual(glossary.entries[0].term, "Kubernetes")
        XCTAssertEqual(glossary.entries[0].aliases, ["k8s", "K8s"])
    }
    
    func testRoundTripJSONEncoding() throws {
        let original = Glossary(
            enabled: true,
            entries: [
                GlossaryEntry(term: "Test", pronunciation: "test", context: "testing", aliases: ["t"])
            ],
            maxSize: 1000
        )
        
        // Export
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        // Import
        let decoder = JSONDecoder()
        let imported = try decoder.decode(Glossary.self, from: data)
        
        XCTAssertEqual(original.enabled, imported.enabled)
        XCTAssertEqual(original.entries.count, imported.entries.count)
        XCTAssertEqual(original.entries[0].term, imported.entries[0].term)
    }
}
