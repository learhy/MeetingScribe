import Foundation

/// Errors that can occur during transcript post-processing
enum PostProcessingError: Error {
    case apiError(String)
    case networkError(Error)
    case invalidResponse
    case noProviderConfigured
}

/// Result of a processing pass, supporting partial success with fallback
enum PassResult {
    case success(String)
    case failed(Error, fallback: String)
    
    var text: String {
        switch self {
        case .success(let text):
            return text
        case .failed(_, let fallback):
            return fallback
        }
    }
    
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// Service for post-processing transcripts using LLM to correct errors
class TranscriptPostProcessor {
    private let logger = DualLogger(category: "TranscriptPostProcessor")
    private let config: ConfigManager
    
    // Maximum characters per chunk to stay within LLM context limits
    private let maxChunkSize = 8000
    
    // Phonetic index for glossary filtering
    private var phoneticIndex = PhoneticIndex()
    private var indexBuilt = false
    
    /// Optional KNOWN PEOPLE section to inject into the correction prompt.
    /// Set before calling process() with contacts for current meeting participants.
    var knownPeopleContext: String?
    
    // Metrics for observability
    private(set) var lastProcessingLatency: TimeInterval = 0
    private(set) var lastCorrectionCount: Int = 0
    private(set) var usedFallback: Bool = false
    private(set) var lastFilteringMetrics: FilteringMetrics?
    
    /// Metrics from glossary filtering
    struct FilteringMetrics {
        let totalWords: Int
        let uniqueWords: Int
        let exactMatches: Int
        let phoneticMatches: Int
        let totalTerms: Int
        let tokenCount: Int
        let skippedCount: Int
        let elapsedMs: Double
    }
    
    init(config: ConfigManager = .shared) {
        self.config = config
        rebuildPhoneticIndex()
        
        // Listen for config changes to rebuild index
        config.onConfigChanged = { [weak self] in
            self?.rebuildPhoneticIndex()
        }
    }
    
    /// Rebuild the phonetic index from current glossary config
    func rebuildPhoneticIndex() {
        let glossaryConfig = config.config.transcription.glossary
        let entries = config.glossaryEntries
        if glossaryConfig.enabled && !entries.isEmpty {
            phoneticIndex.build(from: entries)
            indexBuilt = true
            logger.info("Phonetic index rebuilt with \(entries.count) entries")
        } else {
            indexBuilt = false
        }
    }
    
    /// Format contacts as a KNOWN PEOPLE section for injection into the correction prompt.
    /// Similar to formatGlossary() but for people names.
    static func formatKnownPeople(_ contacts: [ContactInfo]) -> String {
        guard !contacts.isEmpty else { return "" }
        
        let formatted = contacts.compactMap { contact -> String? in
            guard let name = contact.bestName else { return nil }
            
            var parts: [String] = []
            if let pronunciation = contact.pronunciation, !pronunciation.isEmpty {
                parts.append("pronunciation: \(pronunciation)")
            }
            if let aliases = contact.aliases, !aliases.isEmpty {
                parts.append("aliases: \(aliases.joined(separator: ", "))")
            }
            if let role = contact.role, !role.isEmpty {
                parts.append("role: \(role)")
            }
            
            if parts.isEmpty {
                return name
            } else {
                return "\(name) (\(parts.joined(separator: "; ")))"
            }
        }.joined(separator: " | ")
        
        guard !formatted.isEmpty else { return "" }
        
        return """
        
        ## KNOWN PEOPLE (correct to these names when phonetically similar)
        \(formatted)
        
        """
    }
    
    /// Format glossary entries for injection into prompt
    func formatGlossary(_ entries: [AppConfiguration.Transcription.GlossaryEntry]) -> String {
        guard !entries.isEmpty else { return "" }
        
        let formatted = entries.map { entry -> String in
            var parts: [String] = []
            if let pronunciation = entry.pronunciation, !pronunciation.isEmpty {
                parts.append("pronunciation: \(pronunciation)")
            }
            if let context = entry.context, !context.isEmpty {
                parts.append("context: \(context)")
            }
            if let aliases = entry.aliases, !aliases.isEmpty {
                parts.append("aliases: \(aliases.joined(separator: ", "))")
            }
            
            if parts.isEmpty {
                return entry.term
            } else {
                return "\(entry.term) (\(parts.joined(separator: "; ")))"
            }
        }.joined(separator: " | ")
        
        return """
        
        ## KNOWN TERMS (correct to these when phonetically similar)
        \(formatted)
        
        """
    }
    
    /// Filter glossary entries to only include those relevant to the transcript
    /// Uses exact word-boundary matching and phonetic matching for efficiency
    func filterByTranscript(
        _ transcript: String,
        maxTokens: Int = 2000
    ) -> [AppConfiguration.Transcription.GlossaryEntry] {
        let startTime = Date()
        let glossaryConfig = config.config.transcription.glossary
        let entries = config.glossaryEntries
        
        // If filtering disabled, return all entries (legacy behavior)
        guard glossaryConfig.filteringEnabled else {
            logger.info("Glossary filtering disabled, using all \(entries.count) entries")
            return entries
        }
        
        // Tokenize and dedupe transcript words
        let words = transcript.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let uniqueWords = Set(words.map(String.init))
        
        logger.info("[Glossary] Filtering: \(words.count) transcript words, \(uniqueWords.count) unique")
        
        // Track matches with their match type for prioritization
        struct Match {
            let entry: AppConfiguration.Transcription.GlossaryEntry
            let isExact: Bool
            let confidence: Double
        }
        
        var matchesByTerm: [String: Match] = [:]
        var exactMatchCount = 0
        var phoneticMatchCount = 0
        
        // 1. Exact word-boundary matches (fast path)
        for word in uniqueWords {
            if let entry = phoneticIndex.lookupExact(word) {
                if matchesByTerm[entry.term] == nil {
                    matchesByTerm[entry.term] = Match(entry: entry, isExact: true, confidence: 1.0)
                    exactMatchCount += 1
                }
            }
        }
        
        // 2. Phonetic matches (if enabled)
        if glossaryConfig.phoneticMatchingEnabled && indexBuilt {
            for word in uniqueWords {
                // Skip very short words (likely noise)
                guard word.count >= 3 else { continue }
                
                let phoneticMatches = phoneticIndex.lookupPhonetic(word)
                for entry in phoneticMatches {
                    // Don't overwrite exact matches with phonetic ones
                    if matchesByTerm[entry.term] == nil {
                        let confidence = word.confidenceScore(comparedTo: entry.firstWord.lowercased())
                        // Only include if confidence is reasonable (avoid false positives)
                        if confidence >= 0.5 {
                            matchesByTerm[entry.term] = Match(entry: entry, isExact: false, confidence: confidence)
                            phoneticMatchCount += 1
                        }
                    }
                }
            }
        }
        
        logger.info("[Glossary] Matches: \(exactMatchCount) exact, \(phoneticMatchCount) phonetic")
        
        // Convert to array and sort: exact matches first, then by confidence
        var allMatches = Array(matchesByTerm.values)
        allMatches.sort { a, b in
            if a.isExact != b.isExact {
                return a.isExact  // Exact matches come first
            }
            return a.confidence > b.confidence  // Higher confidence first
        }
        
        // 3. Cap by token budget
        var result: [AppConfiguration.Transcription.GlossaryEntry] = []
        var totalTokens = 0
        var skippedCount = 0
        
        for match in allMatches {
            let entryTokens = match.entry.estimatedTokenCount
            if totalTokens + entryTokens <= maxTokens {
                result.append(match.entry)
                totalTokens += entryTokens
            } else {
                skippedCount += 1
            }
        }
        
        let elapsed = Date().timeIntervalSince(startTime) * 1000
        
        // Store metrics for observability
        lastFilteringMetrics = FilteringMetrics(
            totalWords: words.count,
            uniqueWords: uniqueWords.count,
            exactMatches: exactMatchCount,
            phoneticMatches: phoneticMatchCount,
            totalTerms: result.count,
            tokenCount: totalTokens,
            skippedCount: skippedCount,
            elapsedMs: elapsed
        )
        
        logger.info("[Glossary] Filtered: \(result.count) terms, \(totalTokens) tokens in \(String(format: "%.1f", elapsed))ms")
        
        if skippedCount > 0 {
            logger.info("[Glossary] Skipped: \(skippedCount) lower-confidence matches (token cap)")
        }
        
        return result
    }
    
    /// Process a transcript to correct transcription errors using the configured LLM
    func process(transcript: String) async throws -> String {
        let postProcessingConfig = config.config.transcription.postProcessing
        let glossaryConfig = config.config.transcription.glossary
        let glossaryEntries = config.glossaryEntries
        
        guard postProcessingConfig.enabled else {
            logger.info("Post-processing disabled, returning original transcript")
            return transcript
        }
        
        logger.info("Starting transcript post-processing")
        let startTime = Date()
        usedFallback = false
        
        // Get the configured LLM provider
        let provider = try createProvider()
        
        // Build system prompt with optional glossary injection
        var systemPrompt = postProcessingConfig.systemPrompt
        if glossaryConfig.enabled && !glossaryEntries.isEmpty {
            // Filter glossary to relevant terms for this transcript
            let filteredEntries = filterByTranscript(transcript, maxTokens: glossaryConfig.maxGlossaryTokens)
            
            if !filteredEntries.isEmpty {
                let glossaryText = formatGlossary(filteredEntries)
                systemPrompt = systemPrompt + glossaryText
                logger.info("Injected \(filteredEntries.count) filtered glossary terms (from \(glossaryEntries.count) total)")
            } else {
                logger.info("No relevant glossary terms found for this transcript")
            }
        }
        
        // Inject KNOWN PEOPLE section if available
        if let peopleContext = knownPeopleContext, !peopleContext.isEmpty {
            systemPrompt = systemPrompt + peopleContext
            logger.info("Injected KNOWN PEOPLE context into correction prompt")
        }
        
        // For shorter transcripts, process in one go
        if transcript.count <= maxChunkSize {
            logger.info("Processing transcript in single chunk")
            let result = await processChunkWithFallback(transcript, provider: provider, systemPrompt: systemPrompt)
            lastProcessingLatency = Date().timeIntervalSince(startTime)
            
            if case .failed = result {
                usedFallback = true
            }
            
            // Count corrections by comparing original vs result
            lastCorrectionCount = countDifferences(original: transcript, corrected: result.text)
            logger.info("Post-processing complete in \(String(format: "%.1f", lastProcessingLatency))s, \(lastCorrectionCount) potential corrections")
            
            return result.text
        }
        
        // For longer transcripts, split by speaker turns and process in chunks
        logger.info("Transcript too long (\(transcript.count) chars), processing in chunks")
        let chunks = splitTranscriptIntoChunks(transcript)
        logger.info("Split into \(chunks.count) chunks")
        
        var processedChunks: [String] = []
        for (index, chunk) in chunks.enumerated() {
            logger.info("Processing chunk \(index + 1)/\(chunks.count)")
            let result = await processChunkWithFallback(chunk, provider: provider, systemPrompt: systemPrompt)
            if case .failed = result {
                usedFallback = true
            }
            processedChunks.append(result.text)
        }
        
        let finalResult = processedChunks.joined(separator: "\n")
        lastProcessingLatency = Date().timeIntervalSince(startTime)
        lastCorrectionCount = countDifferences(original: transcript, corrected: finalResult)
        logger.info("Post-processing complete in \(String(format: "%.1f", lastProcessingLatency))s, \(lastCorrectionCount) potential corrections")
        
        return finalResult
    }
    
    /// Process a single chunk with fallback on error
    private func processChunkWithFallback(_ chunk: String, provider: LLMProvider, systemPrompt: String) async -> PassResult {
        // Create a correction-specific user message
        let userMessage = """
        Please correct any transcription errors in the following meeting transcript. 
        Fix misspelled names, technical terms, and misheard words while preserving speaker labels and the original meaning.
        Return only the corrected transcript:

        \(chunk)
        """
        
        do {
            let corrected = try await provider.generate(userMessage: userMessage, systemPrompt: systemPrompt)
            return .success(corrected.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            logger.error("Error processing chunk: \(error.localizedDescription), using fallback")
            return .failed(error, fallback: chunk)
        }
    }
    
    /// Count approximate number of word differences between original and corrected text
    private func countDifferences(original: String, corrected: String) -> Int {
        let originalWords = Set(original.lowercased().split(separator: " ").map(String.init))
        let correctedWords = Set(corrected.lowercased().split(separator: " ").map(String.init))
        return originalWords.symmetricDifference(correctedWords).count
    }
    
    /// Split a transcript into chunks, trying to keep speaker turns intact
    private func splitTranscriptIntoChunks(_ transcript: String) -> [String] {
        var chunks: [String] = []
        var currentChunk = ""
        
        // Split by lines (each line is typically a speaker turn)
        let lines = transcript.components(separatedBy: "\n")
        
        for line in lines {
            // If adding this line would exceed the limit, save current chunk and start new one
            if currentChunk.count + line.count + 1 > maxChunkSize && !currentChunk.isEmpty {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                currentChunk = ""
            }
            
            if !line.isEmpty {
                if !currentChunk.isEmpty {
                    currentChunk += "\n"
                }
                currentChunk += line
            }
        }
        
        // Don't forget the last chunk
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        return chunks
    }
    
    /// Create the appropriate LLM provider based on configuration
    private func createProvider() throws -> LLMProvider {
        let llmConfig = config.config.notes.llm
        
        switch llmConfig.provider {
        case "openai":
            guard !llmConfig.openai.apiKey.isEmpty else {
                throw PostProcessingError.noProviderConfigured
            }
            return OpenAIProvider(
                apiKey: llmConfig.openai.apiKey,
                model: llmConfig.openai.model,
                timeoutSeconds: 180
            )
            
        case "anthropic":
            guard !llmConfig.anthropic.apiKey.isEmpty else {
                throw PostProcessingError.noProviderConfigured
            }
            return AnthropicProvider(
                apiKey: llmConfig.anthropic.apiKey,
                model: llmConfig.anthropic.model,
                timeoutSeconds: 180
            )
            
        case "ollama":
            return OllamaProvider(
                endpoint: llmConfig.ollama.endpoint,
                model: llmConfig.ollama.model,
                timeoutSeconds: 300
            )
            
        default:
            logger.error("Unknown LLM provider: \(llmConfig.provider)")
            throw PostProcessingError.noProviderConfigured
        }
    }
}
