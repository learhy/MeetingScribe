import XCTest
@testable import MeetingScribe

final class GlossaryEntryTests: XCTestCase {
    
    // MARK: - Basic Encoding/Decoding
    
    func testGlossaryEntryEncodesAndDecodes() throws {
        let entry = GlossaryEntry(
            term: "Kubernetes",
            pronunciation: "koo-ber-NET-eez",
            context: "container orchestration",
            aliases: ["k8s", "K8s"]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(GlossaryEntry.self, from: data)
        
        XCTAssertEqual(decoded.term, "Kubernetes")
        XCTAssertEqual(decoded.pronunciation, "koo-ber-NET-eez")
        XCTAssertEqual(decoded.context, "container orchestration")
        XCTAssertEqual(decoded.aliases, ["k8s", "K8s"])
    }
    
    func testGlossaryEntryWithNilOptionals() throws {
        let entry = GlossaryEntry(
            term: "Simple",
            pronunciation: nil,
            context: nil,
            aliases: nil
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(GlossaryEntry.self, from: data)
        
        XCTAssertEqual(decoded.term, "Simple")
        XCTAssertNil(decoded.pronunciation)
        XCTAssertNil(decoded.context)
        XCTAssertNil(decoded.aliases)
    }
    
    // MARK: - Special Characters
    
    func testGlossaryEntryWithSpecialChars() throws {
        let entry = GlossaryEntry(
            term: "C++",
            pronunciation: "see-plus-plus",
            context: "programming language",
            aliases: ["cpp"]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(GlossaryEntry.self, from: data)
        
        XCTAssertEqual(decoded.term, "C++")
    }
    
    func testGlossaryEntryWithDotNet() throws {
        let entry = GlossaryEntry(
            term: ".NET",
            pronunciation: "dot-net",
            context: "Microsoft framework",
            aliases: ["dotnet", "dotNET"]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(GlossaryEntry.self, from: data)
        
        XCTAssertEqual(decoded.term, ".NET")
        XCTAssertEqual(decoded.aliases, ["dotnet", "dotNET"])
    }
    
    func testGlossaryEntryWithCOVID() throws {
        let entry = GlossaryEntry(
            term: "COVID-19",
            pronunciation: "KOH-vid nine-teen",
            context: "coronavirus disease",
            aliases: ["COVID", "coronavirus"]
        )
        
        XCTAssertEqual(entry.term, "COVID-19")
    }
    
    // MARK: - Unicode
    
    func testGlossaryEntryWithUnicode() throws {
        let entry = GlossaryEntry(
            term: "中文",
            pronunciation: "zhong-wen",
            context: "Chinese language",
            aliases: nil
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(GlossaryEntry.self, from: data)
        
        XCTAssertEqual(decoded.term, "中文")
    }
    
    func testGlossaryEntryWithGreek() throws {
        let entry = GlossaryEntry(
            term: "Ελληνικά",
            pronunciation: "el-lee-nee-KAH",
            context: "Greek language",
            aliases: ["Greek"]
        )
        
        XCTAssertEqual(entry.term, "Ελληνικά")
    }
}

final class GlossaryTests: XCTestCase {
    
    // MARK: - Basic Structure
    
    func testGlossaryEncodesAndDecodes() throws {
        let glossary = Glossary(
            enabled: true,
            entries: [
                GlossaryEntry(term: "Kubernetes", pronunciation: nil, context: nil, aliases: ["k8s"]),
                GlossaryEntry(term: "PostgreSQL", pronunciation: nil, context: nil, aliases: nil)
            ],
            maxSize: 1000
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(glossary)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Glossary.self, from: data)
        
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.entries.count, 2)
        XCTAssertEqual(decoded.maxSize, 1000)
    }
    
    func testGlossaryDefaultValues() throws {
        let glossary = Glossary()
        
        XCTAssertFalse(glossary.enabled)
        XCTAssertTrue(glossary.entries.isEmpty)
        XCTAssertEqual(glossary.maxSize, 1000)
    }
    
    func testEmptyGlossary() throws {
        let glossary = Glossary(enabled: false, entries: [], maxSize: 1000)
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(glossary)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Glossary.self, from: data)
        
        XCTAssertFalse(decoded.enabled)
        XCTAssertTrue(decoded.entries.isEmpty)
    }
    
    // MARK: - JSON Parsing from File Format
    
    func testGlossaryFromExampleJSON() throws {
        let json = """
        {
          "enabled": true,
          "maxSize": 1000,
          "entries": [
            {
              "term": "Kubernetes",
              "pronunciation": "koo-ber-NET-eez",
              "context": "container orchestration platform",
              "aliases": ["k8s", "K8s"]
            },
            {
              "term": "PostgreSQL",
              "pronunciation": "POST-gres-cue-ell",
              "context": "relational database management system",
              "aliases": ["Postgres", "pg"]
            }
          ]
        }
        """
        
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let glossary = try decoder.decode(Glossary.self, from: data)
        
        XCTAssertTrue(glossary.enabled)
        XCTAssertEqual(glossary.entries.count, 2)
        XCTAssertEqual(glossary.entries[0].term, "Kubernetes")
        XCTAssertEqual(glossary.entries[0].aliases, ["k8s", "K8s"])
        XCTAssertEqual(glossary.entries[1].term, "PostgreSQL")
    }
    
    // MARK: - Backward Compatibility
    
    func testGlossaryMissingOptionalFields() throws {
        // JSON without pronunciation, context, or aliases
        let json = """
        {
          "enabled": true,
          "entries": [
            { "term": "Kubernetes" },
            { "term": "Docker" }
          ]
        }
        """
        
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let glossary = try decoder.decode(Glossary.self, from: data)
        
        XCTAssertTrue(glossary.enabled)
        XCTAssertEqual(glossary.entries.count, 2)
        XCTAssertNil(glossary.entries[0].pronunciation)
        XCTAssertNil(glossary.entries[0].context)
        XCTAssertNil(glossary.entries[0].aliases)
    }
}

final class GlossaryValidationTests: XCTestCase {
    
    // MARK: - Length Validation (for UI/GlossaryTab)
    
    func testTermMaxLength() {
        // 100 characters is the max
        let longTerm = String(repeating: "a", count: 100)
        let entry = GlossaryEntry(term: longTerm, pronunciation: nil, context: nil, aliases: nil)
        XCTAssertEqual(entry.term.count, 100)
    }
    
    func testContextMaxLength() {
        // 200 characters is the max
        let longContext = String(repeating: "b", count: 200)
        let entry = GlossaryEntry(term: "Test", pronunciation: nil, context: longContext, aliases: nil)
        XCTAssertEqual(entry.context?.count, 200)
    }
    
    func testPronunciationMaxLength() {
        // 100 characters is the max
        let longPronunciation = String(repeating: "c", count: 100)
        let entry = GlossaryEntry(term: "Test", pronunciation: longPronunciation, context: nil, aliases: nil)
        XCTAssertEqual(entry.pronunciation?.count, 100)
    }
}
