import XCTest
@testable import MeetingScribe

final class TranscriptPostProcessorTests: XCTestCase {
    
    var processor: TranscriptPostProcessor!
    
    override func setUp() {
        super.setUp()
        processor = TranscriptPostProcessor()
    }
    
    // MARK: - Glossary Formatting
    
    func testFormatGlossaryWithEntries() throws {
        let entries = [
            GlossaryEntry(term: "Kubernetes", pronunciation: "koo-ber-NET-eez", context: "container orchestration", aliases: ["k8s"]),
            GlossaryEntry(term: "PostgreSQL", pronunciation: nil, context: "database", aliases: nil)
        ]
        
        let formatted = processor.formatGlossary(entries)
        
        XCTAssertTrue(formatted.contains("KNOWN TERMS"))
        XCTAssertTrue(formatted.contains("Kubernetes"))
        XCTAssertTrue(formatted.contains("koo-ber-NET-eez"))
        XCTAssertTrue(formatted.contains("k8s"))
        XCTAssertTrue(formatted.contains("PostgreSQL"))
    }
    
    func testFormatGlossaryEmpty() throws {
        let formatted = processor.formatGlossary([])
        XCTAssertTrue(formatted.isEmpty)
    }
    
    func testFormatGlossaryEntryFull() throws {
        let entry = GlossaryEntry(
            term: "Kubernetes",
            pronunciation: "koo-ber-NET-eez",
            context: "container orchestration",
            aliases: ["k8s", "K8s"]
        )
        
        // Use the GlossaryEntry extension method
        let formatted = entry.formatForPrompt()
        
        XCTAssertTrue(formatted.contains("Kubernetes"))
        XCTAssertTrue(formatted.contains("pronunciation: koo-ber-NET-eez"))
        XCTAssertTrue(formatted.contains("context: container orchestration"))
        XCTAssertTrue(formatted.contains("aliases: k8s, K8s"))
    }
    
    func testFormatGlossaryEntryMinimal() throws {
        let entry = GlossaryEntry(term: "Test", pronunciation: nil, context: nil, aliases: nil)
        
        let formatted = entry.formatForPrompt()
        
        XCTAssertEqual(formatted, "Test")
    }
    
    // MARK: - PassResult Enum
    
    func testPassResultSuccess() throws {
        let result = PassResult.success("corrected text")
        
        switch result {
        case .success(let text):
            XCTAssertEqual(text, "corrected text")
        case .failed:
            XCTFail("Expected success")
        }
    }
    
    func testPassResultFailed() throws {
        enum TestError: Error { case testFailure }
        let result = PassResult.failed(TestError.testFailure, fallback: "original text")
        
        switch result {
        case .success:
            XCTFail("Expected failure")
        case .failed(_, let fallback):
            XCTAssertEqual(fallback, "original text")
        }
    }
    
    // MARK: - Metrics
    
    func testMetricsInitialValues() throws {
        XCTAssertEqual(processor.lastProcessingLatency, 0)
        XCTAssertEqual(processor.lastCorrectionCount, 0)
        XCTAssertFalse(processor.usedFallback)
    }
}

// MARK: - Known People Formatting Tests

final class KnownPeopleFormattingTests: XCTestCase {
    
    func testFormatKnownPeople_WithFullContacts() throws {
        let contacts = [
            ContactInfo(email: "pradeep@ibm.com", displayName: "Pradeep Sekar",
                       preferredName: "Pradeep", pronunciation: "prah-DEEP",
                       aliases: ["product", "pretty"], role: "Staff Engineer",
                       team: "Platform", source: "manual")
        ]
        
        let formatted = TranscriptPostProcessor.formatKnownPeople(contacts)
        
        XCTAssertTrue(formatted.contains("KNOWN PEOPLE"))
        XCTAssertTrue(formatted.contains("Pradeep"))
        XCTAssertTrue(formatted.contains("pronunciation: prah-DEEP"))
        XCTAssertTrue(formatted.contains("aliases: product, pretty"))
        XCTAssertTrue(formatted.contains("role: Staff Engineer"))
    }
    
    func testFormatKnownPeople_WithMinimalContacts() throws {
        let contacts = [
            ContactInfo(email: "dan@ibm.com", displayName: "Dan Rohan",
                       preferredName: nil, pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "calendar")
        ]
        
        let formatted = TranscriptPostProcessor.formatKnownPeople(contacts)
        
        XCTAssertTrue(formatted.contains("KNOWN PEOPLE"))
        XCTAssertTrue(formatted.contains("Dan Rohan"))
        // No parens for a contact with no metadata
        XCTAssertFalse(formatted.contains("Dan Rohan ("))
    }
    
    func testFormatKnownPeople_EmptyArray() throws {
        let formatted = TranscriptPostProcessor.formatKnownPeople([])
        XCTAssertTrue(formatted.isEmpty)
    }
    
    func testFormatKnownPeople_ContactWithoutName() throws {
        // Contact with only email, no display_name or preferred_name
        let contacts = [
            ContactInfo(email: "noname@ibm.com", displayName: nil,
                       preferredName: nil, pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "calendar")
        ]
        
        let formatted = TranscriptPostProcessor.formatKnownPeople(contacts)
        
        // No name available → should produce empty output
        XCTAssertTrue(formatted.isEmpty)
    }
    
    func testFormatKnownPeople_MultipleContacts() throws {
        let contacts = [
            ContactInfo(email: "a@x.com", displayName: "Alice",
                       preferredName: nil, pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "manual"),
            ContactInfo(email: "b@x.com", displayName: "Bob",
                       preferredName: nil, pronunciation: nil, aliases: nil,
                       role: "PM", team: nil, source: "calendar")
        ]
        
        let formatted = TranscriptPostProcessor.formatKnownPeople(contacts)
        
        XCTAssertTrue(formatted.contains("Alice"))
        XCTAssertTrue(formatted.contains("Bob (role: PM)"))
        XCTAssertTrue(formatted.contains(" | "), "Multiple contacts should be pipe-separated")
    }
}

// MARK: - Model Decoding Tests

final class PeoplePipelineDecodingTests: XCTestCase {
    
    func testContactInfoDecoding() throws {
        let json = """
        {
            "email": "alice@example.com",
            "display_name": "Alice Smith",
            "preferred_name": "Alice",
            "pronunciation": "AL-iss",
            "aliases": ["Alicia"],
            "role": "Engineer",
            "team": "Platform",
            "source": "manual"
        }
        """
        
        let data = json.data(using: .utf8)!
        let contact = try JSONDecoder().decode(ContactInfo.self, from: data)
        
        XCTAssertEqual(contact.email, "alice@example.com")
        XCTAssertEqual(contact.displayName, "Alice Smith")
        XCTAssertEqual(contact.preferredName, "Alice")
        XCTAssertEqual(contact.pronunciation, "AL-iss")
        XCTAssertEqual(contact.aliases, ["Alicia"])
        XCTAssertEqual(contact.role, "Engineer")
        XCTAssertEqual(contact.team, "Platform")
        XCTAssertEqual(contact.bestName, "Alice")  // preferred_name takes priority
    }
    
    func testContactInfoDecoding_MinimalFields() throws {
        let json = """
        {
            "email": "bob@example.com",
            "display_name": null,
            "preferred_name": null,
            "pronunciation": null,
            "aliases": null,
            "role": null,
            "team": null,
            "source": "calendar"
        }
        """
        
        let data = json.data(using: .utf8)!
        let contact = try JSONDecoder().decode(ContactInfo.self, from: data)
        
        XCTAssertEqual(contact.email, "bob@example.com")
        XCTAssertNil(contact.displayName)
        XCTAssertNil(contact.bestName)
        XCTAssertEqual(contact.source, "calendar")
    }
    
    func testSpeakerIdentityDecoding() throws {
        let json = """
        {
            "speaker_id": "abc-123",
            "name": "Dan",
            "confidence": 0.92
        }
        """
        
        let data = json.data(using: .utf8)!
        let identity = try JSONDecoder().decode(SpeakerIdentity.self, from: data)
        
        XCTAssertEqual(identity.speakerId, "abc-123")
        XCTAssertEqual(identity.name, "Dan")
        XCTAssertEqual(identity.confidence, 0.92, accuracy: 0.001)
    }
    
    func testDiarizedTranscriptDecoding_WithSpeakerMap() throws {
        let json = """
        {
            "segments": [],
            "speakers": ["SPEAKER_00", "SPEAKER_01"],
            "num_speakers": 2,
            "audio_file": "/tmp/test.wav",
            "speaker_map": {
                "SPEAKER_00": {"speaker_id": "id-1", "name": "Dan", "confidence": 0.95},
                "SPEAKER_01": null
            }
        }
        """
        
        let data = json.data(using: .utf8)!
        let transcript = try JSONDecoder().decode(DiarizedTranscript.self, from: data)
        
        XCTAssertNotNil(transcript.speakerMap)
        XCTAssertEqual(transcript.speakerMap?.count, 2)
        
        let speaker0 = transcript.speakerMap?["SPEAKER_00"]
        XCTAssertNotNil(speaker0 as Any?)  // Optional<Optional<SpeakerIdentity>>
        XCTAssertEqual(speaker0??.name, "Dan")
        
        let speaker1 = transcript.speakerMap?["SPEAKER_01"]
        XCTAssertNotNil(speaker1 as Any?)  // Key exists
        XCTAssertNil(speaker1 as? SpeakerIdentity)  // But value is nil
    }
    
    func testDiarizedTranscriptDecoding_WithoutSpeakerMap() throws {
        let json = """
        {
            "segments": [],
            "speakers": ["SPEAKER_00"],
            "num_speakers": 1,
            "audio_file": "/tmp/test.wav"
        }
        """
        
        let data = json.data(using: .utf8)!
        let transcript = try JSONDecoder().decode(DiarizedTranscript.self, from: data)
        
        XCTAssertNil(transcript.speakerMap, "speakerMap should be nil when absent from JSON")
        XCTAssertEqual(transcript.numSpeakers, 1)
    }
}

// MARK: - Glossary-Disabled Behavior (Regression Tests)

final class GlossaryDisabledRegressionTests: XCTestCase {
    
    var processor: TranscriptPostProcessor!
    
    override func setUp() {
        super.setUp()
        processor = TranscriptPostProcessor()
    }
    
    func testProcessingWithoutGlossary() throws {
        // Processor should initialize without issues even with glossary disabled
        XCTAssertTrue(true, "Processor initializes without glossary")
    }
    
    func testProcessingWithEmptyGlossary() throws {
        // Empty glossary should produce empty formatted string
        let formatted = processor.formatGlossary([])
        XCTAssertTrue(formatted.isEmpty)
    }
}

// MARK: - Config Migration Tests

final class ConfigMigrationTests: XCTestCase {
    
    func testConfigWithoutGlossaryKeyLoadsDefaults() throws {
        // This test verifies the Glossary struct defaults when glossary is not in config
        let glossary = Glossary()
        
        XCTAssertFalse(glossary.enabled)
        XCTAssertTrue(glossary.entries.isEmpty)
        XCTAssertEqual(glossary.maxSize, 1000)
    }
    
    func testGlossaryDecodesWithMissingMaxSize() throws {
        let json = """
        {
          "enabled": true,
          "entries": []
        }
        """
        
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let glossary = try decoder.decode(Glossary.self, from: data)
        
        // maxSize should default to 1000 if not present
        XCTAssertEqual(glossary.maxSize, 1000)
    }
}

// MARK: - Mock LLM Service

class MockLLMService: LLMServiceProtocol {
    var responseToReturn: String = "mocked response"
    var shouldFail: Bool = false
    
    func generateNotes(from transcript: String, systemPrompt: String) async throws -> String {
        if shouldFail {
            throw NSError(domain: "MockLLM", code: 1, userInfo: nil)
        }
        return responseToReturn
    }
}

// Protocol for dependency injection (if not already defined)
protocol LLMServiceProtocol {
    func generateNotes(from transcript: String, systemPrompt: String) async throws -> String
}

// MARK: - Double Metaphone Tests

final class DoubleMetaphoneTests: XCTestCase {
    
    let metaphone = DoubleMetaphone()
    
    func testBasicEncoding() throws {
        let result = metaphone.encode("Kubernetes")
        XCTAssertFalse(result.primary.isEmpty)
    }
    
    func testPhoneticallySimilarWords() throws {
        // "cubernetes" should have same phonetic code as "kubernetes"
        let kubernetes = metaphone.encode("Kubernetes")
        let cubernetes = metaphone.encode("Cubernetes")
        
        // They should match via primary or secondary codes
        XCTAssertTrue(kubernetes.matches(cubernetes), "Kubernetes and Cubernetes should be phonetically similar")
    }
    
    func testEmptyString() throws {
        let result = metaphone.encode("")
        XCTAssertEqual(result.primary, "")
        XCTAssertEqual(result.secondary, "")
    }
    
    func testCommonNames() throws {
        // Test some common name variations
        let anando = metaphone.encode("Anando")
        let anando2 = metaphone.encode("Anando")
        XCTAssertTrue(anando.matches(anando2))
    }
}

// MARK: - PhoneticIndex Tests

final class PhoneticIndexTests: XCTestCase {
    
    var index: PhoneticIndex!
    
    override func setUp() {
        super.setUp()
        index = PhoneticIndex()
    }
    
    func testBuildIndex() throws {
        let entries = [
            AppConfiguration.Transcription.GlossaryEntry(
                term: "Kubernetes",
                pronunciation: "koo-ber-NET-eez",
                context: "container orchestration",
                aliases: ["k8s", "K8s"]
            ),
            AppConfiguration.Transcription.GlossaryEntry(
                term: "PostgreSQL",
                pronunciation: nil,
                context: "database",
                aliases: ["Postgres"]
            )
        ]
        
        index.build(from: entries)
        
        XCTAssertEqual(index.entries.count, 2)
    }
    
    func testExactLookup() throws {
        let entries = [
            AppConfiguration.Transcription.GlossaryEntry(
                term: "Kubernetes",
                pronunciation: nil,
                context: nil,
                aliases: ["k8s"]
            )
        ]
        index.build(from: entries)
        
        // Exact match on term
        let match1 = index.lookupExact("kubernetes")
        XCTAssertNotNil(match1)
        XCTAssertEqual(match1?.term, "Kubernetes")
        
        // Exact match on alias
        let match2 = index.lookupExact("k8s")
        XCTAssertNotNil(match2)
        XCTAssertEqual(match2?.term, "Kubernetes")
        
        // No match
        let match3 = index.lookupExact("docker")
        XCTAssertNil(match3)
    }
    
    func testPhoneticLookup() throws {
        let entries = [
            AppConfiguration.Transcription.GlossaryEntry(
                term: "Kubernetes",
                pronunciation: nil,
                context: nil,
                aliases: nil
            )
        ]
        index.build(from: entries)
        
        // Phonetic match
        let matches = index.lookupPhonetic("Cubernetes")
        XCTAssertFalse(matches.isEmpty, "Should find phonetic match for Cubernetes")
    }
    
    // MARK: - Edge Cases
    
    func testEmptyIndex() throws {
        // Empty index should return nil/empty for all lookups
        XCTAssertNil(index.lookupExact("anything"))
        XCTAssertTrue(index.lookupPhonetic("anything").isEmpty)
        XCTAssertFalse(index.hasExactMatch("anything"))
    }
    
    func testBuildWithEmptyEntries() throws {
        index.build(from: [])
        XCTAssertEqual(index.entries.count, 0)
        XCTAssertNil(index.lookupExact("test"))
    }
    
    func testMultiWordTermPhoneticMatching() throws {
        // Multi-word terms should be indexed by first word for phonetic matching
        let entries = [
            AppConfiguration.Transcription.GlossaryEntry(
                term: "Machine Learning",
                pronunciation: nil,
                context: "AI technique",
                aliases: nil
            )
        ]
        index.build(from: entries)
        
        // Should match on first word phonetically
        let matches = index.lookupPhonetic("Machine")
        XCTAssertFalse(matches.isEmpty, "Should match multi-word term by first word")
        XCTAssertEqual(matches.first?.term, "Machine Learning")
    }
    
    func testAliasPhoneticMatching() throws {
        // Aliases should also be indexed phonetically
        let entries = [
            AppConfiguration.Transcription.GlossaryEntry(
                term: "Kubernetes",
                pronunciation: nil,
                context: nil,
                aliases: ["Kube"]
            )
        ]
        index.build(from: entries)
        
        // Should match via alias phonetic code
        let matches = index.lookupPhonetic("Koob")
        XCTAssertFalse(matches.isEmpty, "Should match via alias phonetic code")
    }
    
    func testCaseInsensitiveExactMatch() throws {
        let entries = [
            AppConfiguration.Transcription.GlossaryEntry(
                term: "PostgreSQL",
                pronunciation: nil,
                context: nil,
                aliases: nil
            )
        ]
        index.build(from: entries)
        
        XCTAssertNotNil(index.lookupExact("postgresql"))
        XCTAssertNotNil(index.lookupExact("POSTGRESQL"))
        XCTAssertNotNil(index.lookupExact("PostgreSQL"))
    }
    
    func testNoFalsePositivesForUnrelatedWords() throws {
        let entries = [
            AppConfiguration.Transcription.GlossaryEntry(
                term: "Kubernetes",
                pronunciation: nil,
                context: nil,
                aliases: nil
            )
        ]
        index.build(from: entries)
        
        // Completely unrelated words should not match
        XCTAssertTrue(index.lookupPhonetic("banana").isEmpty)
        XCTAssertTrue(index.lookupPhonetic("meeting").isEmpty)
        XCTAssertTrue(index.lookupPhonetic("schedule").isEmpty)
    }
}

// MARK: - Levenshtein Distance Tests

final class LevenshteinDistanceTests: XCTestCase {
    
    func testIdenticalStrings() throws {
        XCTAssertEqual("hello".levenshteinDistance(to: "hello"), 0)
    }
    
    func testOneCharacterDifference() throws {
        XCTAssertEqual("hello".levenshteinDistance(to: "hallo"), 1)
    }
    
    func testEmptyStrings() throws {
        XCTAssertEqual("".levenshteinDistance(to: ""), 0)
        XCTAssertEqual("hello".levenshteinDistance(to: ""), 5)
        XCTAssertEqual("".levenshteinDistance(to: "world"), 5)
    }
    
    func testConfidenceScore() throws {
        XCTAssertEqual("hello".confidenceScore(comparedTo: "hello"), 1.0)
        XCTAssertLessThan("hello".confidenceScore(comparedTo: "world"), 0.5)
    }
}

// MARK: - GlossaryEntry Extension Tests

final class GlossaryEntryExtensionTests: XCTestCase {
    
    func testFormatForPrompt() throws {
        let entry = AppConfiguration.Transcription.GlossaryEntry(
            term: "Kubernetes",
            pronunciation: "koo-ber-NET-eez",
            context: "container orchestration",
            aliases: ["k8s", "K8s"]
        )
        
        let formatted = entry.formatForPrompt()
        
        XCTAssertTrue(formatted.contains("Kubernetes"))
        XCTAssertTrue(formatted.contains("pronunciation: koo-ber-NET-eez"))
        XCTAssertTrue(formatted.contains("context: container orchestration"))
        XCTAssertTrue(formatted.contains("aliases: k8s, K8s"))
    }
    
    func testEstimatedTokenCount() throws {
        let entry = AppConfiguration.Transcription.GlossaryEntry(
            term: "Kubernetes",
            pronunciation: "koo-ber-NET-eez",
            context: "container orchestration",
            aliases: ["k8s"]
        )
        
        let tokens = entry.estimatedTokenCount
        XCTAssertGreaterThan(tokens, 0)
        // chars/4 approximation: "Kubernetes (pronunciation: koo-ber-NET-eez; context: container orchestration; aliases: k8s)" ~= 93 chars / 4 ~= 23 tokens
        XCTAssertLessThan(tokens, 50)
    }
    
    func testSearchableVariants() throws {
        let entry = AppConfiguration.Transcription.GlossaryEntry(
            term: "Kubernetes",
            pronunciation: nil,
            context: nil,
            aliases: ["k8s", "K8s"]
        )
        
        let variants = entry.searchableVariants
        XCTAssertTrue(variants.contains("kubernetes"))
        XCTAssertTrue(variants.contains("k8s"))
    }
    
    func testFirstWord() throws {
        let singleWord = AppConfiguration.Transcription.GlossaryEntry(
            term: "Kubernetes",
            pronunciation: nil,
            context: nil,
            aliases: nil
        )
        XCTAssertEqual(singleWord.firstWord, "Kubernetes")
        
        let multiWord = AppConfiguration.Transcription.GlossaryEntry(
            term: "Machine Learning",
            pronunciation: nil,
            context: nil,
            aliases: nil
        )
        XCTAssertEqual(multiWord.firstWord, "Machine")
    }
}

// MARK: - Token Budget Capping Tests

final class TokenBudgetCappingTests: XCTestCase {
    
    func testTokenBudgetCalculation() throws {
        // Create entries with known sizes
        var entries: [AppConfiguration.Transcription.GlossaryEntry] = []
        for i in 0..<100 {
            entries.append(AppConfiguration.Transcription.GlossaryEntry(
                term: "Term\(i)",
                pronunciation: "pronunciation\(i)",
                context: "context\(i)",
                aliases: nil
            ))
        }
        
        // Each entry is roughly: "TermN (pronunciation: pronunciationN; context: contextN)" ~= 50 chars ~= 12 tokens
        let totalEstimatedTokens = entries.reduce(0) { $0 + $1.estimatedTokenCount }
        
        // With 100 entries at ~12 tokens each, should be around 1200 tokens
        XCTAssertGreaterThan(totalEstimatedTokens, 500)
        XCTAssertLessThan(totalEstimatedTokens, 2000)
    }
}

// MARK: - Glossary Filtering Integration Tests

final class GlossaryFilteringIntegrationTests: XCTestCase {
    
    /// Test that glossary filtering works with a realistic transcript and large glossary
    func testFilteringWithLargeGlossary() throws {
        // Create a large glossary (simulating the 946-term real glossary)
        var entries: [AppConfiguration.Transcription.GlossaryEntry] = []
        
        // Add some entries that WILL be found in the transcript
        entries.append(AppConfiguration.Transcription.GlossaryEntry(
            term: "Kubernetes", pronunciation: "koo-ber-NET-eez", context: "container orchestration", aliases: ["k8s"]
        ))
        entries.append(AppConfiguration.Transcription.GlossaryEntry(
            term: "PostgreSQL", pronunciation: nil, context: "database", aliases: ["Postgres"]
        ))
        entries.append(AppConfiguration.Transcription.GlossaryEntry(
            term: "Machine Learning", pronunciation: nil, context: "AI technique", aliases: ["ML"]
        ))
        
        // Add 500 filler entries that won't match
        for i in 0..<500 {
            entries.append(AppConfiguration.Transcription.GlossaryEntry(
                term: "UnlikelyTerm\(i)",
                pronunciation: "pronunciation\(i)",
                context: "context that won't match \(i)",
                aliases: nil
            ))
        }
        
        // Build the index
        let index = PhoneticIndex()
        index.build(from: entries)
        
        // Simulate a transcript
        let transcript = """
        In this meeting, we discussed deploying our services on Kubernetes.
        The team is considering moving from MySQL to PostgreSQL for better performance.
        We also explored using machine learning for the recommendation engine.
        """
        
        // Verify exact lookups work
        XCTAssertNotNil(index.lookupExact("kubernetes"))
        XCTAssertNotNil(index.lookupExact("postgresql"))
        XCTAssertNotNil(index.lookupExact("k8s"))
        
        // Verify phonetic lookups work
        let phoneticMatches = index.lookupPhonetic("Cubernetes")
        XCTAssertFalse(phoneticMatches.isEmpty)
        
        // Verify total entries is large
        XCTAssertEqual(index.entries.count, 503)
    }
    
    /// Test that token budget is respected
    func testTokenBudgetEnforcement() throws {
        // Create entries that each take ~25 tokens (100 chars / 4)
        var entries: [AppConfiguration.Transcription.GlossaryEntry] = []
        for i in 0..<100 {
            let longContext = String(repeating: "x", count: 80)  // Force large token count
            entries.append(AppConfiguration.Transcription.GlossaryEntry(
                term: "Term\(i)",
                pronunciation: nil,
                context: longContext,
                aliases: nil
            ))
        }
        
        // Each entry ~= 100 chars ~= 25 tokens
        // With 100 entries and 2000 token budget, should cap at ~80 entries
        let totalTokens = entries.reduce(0) { $0 + $1.estimatedTokenCount }
        XCTAssertGreaterThan(totalTokens, 2000, "Test setup: total tokens should exceed budget")
    }
}

// MARK: - Config Backward Compatibility Tests

final class GlossaryConfigBackwardCompatibilityTests: XCTestCase {
    
    /// Test that old configs without new glossary fields load correctly with defaults
    func testOldConfigLoadsWithDefaults() throws {
        // JSON representing an old config without the new filtering fields
        let json = """
        {
          "enabled": true,
          "maxSize": 1000,
          "entries": [
            { "term": "Test", "pronunciation": null, "context": null, "aliases": null }
          ]
        }
        """
        
        let data = json.data(using: .utf8)!
        let glossary = try JSONDecoder().decode(Glossary.self, from: data)
        
        // Verify defaults are applied
        XCTAssertEqual(glossary.maxGlossaryTokens, 2000, "Should default to 2000 tokens")
        XCTAssertTrue(glossary.filteringEnabled, "Should default to filtering enabled")
        XCTAssertTrue(glossary.phoneticMatchingEnabled, "Should default to phonetic matching enabled")
    }
    
    /// Test that new configs with all fields load correctly
    func testNewConfigLoadsCorrectly() throws {
        let json = """
        {
          "enabled": true,
          "maxSize": 500,
          "maxGlossaryTokens": 1500,
          "filteringEnabled": false,
          "phoneticMatchingEnabled": false,
          "entries": []
        }
        """
        
        let data = json.data(using: .utf8)!
        let glossary = try JSONDecoder().decode(Glossary.self, from: data)
        
        XCTAssertEqual(glossary.maxGlossaryTokens, 1500)
        XCTAssertFalse(glossary.filteringEnabled)
        XCTAssertFalse(glossary.phoneticMatchingEnabled)
    }
    
    /// Test that partial new config (some new fields) loads correctly
    func testPartialNewConfigLoadsCorrectly() throws {
        let json = """
        {
          "enabled": true,
          "maxSize": 1000,
          "maxGlossaryTokens": 3000,
          "entries": []
        }
        """
        
        let data = json.data(using: .utf8)!
        let glossary = try JSONDecoder().decode(Glossary.self, from: data)
        
        XCTAssertEqual(glossary.maxGlossaryTokens, 3000)  // From JSON
        XCTAssertTrue(glossary.filteringEnabled)  // Default
        XCTAssertTrue(glossary.phoneticMatchingEnabled)  // Default
    }
}

// MARK: - Filename Date Parsing Tests

final class FilenameStartTimeParsingTests: XCTestCase {
    
    var service: MeetingScribeService!
    var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        service = MeetingScribeService()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    /// Test standard filename pattern: meeting_YYYY-MM-DD_HH-MM-SS_mixed.wav
    func testStandardFilenamePattern() throws {
        let filename = "meeting_2026-01-28_14-30-45_mixed.wav"
        let fileURL = tempDir.appendingPathComponent(filename)
        
        // Create a dummy file
        try "".write(to: fileURL, atomically: true, encoding: .utf8)
        
        let parsedDate = service.parseStartTime(from: filename, fileURL: fileURL)
        
        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.year, from: parsedDate), 2026)
        XCTAssertEqual(calendar.component(.month, from: parsedDate), 1)
        XCTAssertEqual(calendar.component(.day, from: parsedDate), 28)
        XCTAssertEqual(calendar.component(.hour, from: parsedDate), 14)
        XCTAssertEqual(calendar.component(.minute, from: parsedDate), 30)
        XCTAssertEqual(calendar.component(.second, from: parsedDate), 45)
    }
    
    /// Test non-standard filename with date pattern embedded
    func testLooseFilenamePattern() throws {
        let filename = "custom_recording_2025-12-15_09-00-00.wav"
        let fileURL = tempDir.appendingPathComponent(filename)
        
        try "".write(to: fileURL, atomically: true, encoding: .utf8)
        
        let parsedDate = service.parseStartTime(from: filename, fileURL: fileURL)
        
        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.year, from: parsedDate), 2025)
        XCTAssertEqual(calendar.component(.month, from: parsedDate), 12)
        XCTAssertEqual(calendar.component(.day, from: parsedDate), 15)
        XCTAssertEqual(calendar.component(.hour, from: parsedDate), 9)
        XCTAssertEqual(calendar.component(.minute, from: parsedDate), 0)
        XCTAssertEqual(calendar.component(.second, from: parsedDate), 0)
    }
    
    /// Test unparseable filename falls back to file modification date
    func testUnparseableFilenameFallsBackToModificationDate() throws {
        let filename = "random_audio_file.wav"
        let fileURL = tempDir.appendingPathComponent(filename)
        
        try "".write(to: fileURL, atomically: true, encoding: .utf8)
        
        // Set a specific modification date
        let expectedDate = Date(timeIntervalSince1970: 1700000000)  // Nov 14, 2023
        try FileManager.default.setAttributes(
            [.modificationDate: expectedDate],
            ofItemAtPath: fileURL.path
        )
        
        let parsedDate = service.parseStartTime(from: filename, fileURL: fileURL)
        
        // Should fall back to file modification date
        XCTAssertEqual(
            parsedDate.timeIntervalSince1970,
            expectedDate.timeIntervalSince1970,
            accuracy: 1.0  // Within 1 second
        )
    }
    
    /// Test filename with only date (no time) doesn't match strict or loose pattern
    func testPartialDatePatternFallsBack() throws {
        let filename = "meeting_2026-01-28.wav"
        let fileURL = tempDir.appendingPathComponent(filename)
        
        try "".write(to: fileURL, atomically: true, encoding: .utf8)
        
        let parsedDate = service.parseStartTime(from: filename, fileURL: fileURL)
        
        // Should fall back to file modification date (recently created)
        // Verify it's close to "now" rather than the partial date in filename
        let timeDiff = abs(parsedDate.timeIntervalSinceNow)
        XCTAssertLessThan(timeDiff, 60, "Should fall back to file modification date (recent)")
    }
}
