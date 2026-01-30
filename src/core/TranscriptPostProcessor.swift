import Foundation

/// Errors that can occur during transcript post-processing
enum PostProcessingError: Error {
    case apiError(String)
    case networkError(Error)
    case invalidResponse
    case noProviderConfigured
}

/// Service for post-processing transcripts using LLM to correct errors
class TranscriptPostProcessor {
    private let logger = DualLogger(category: "TranscriptPostProcessor")
    private let config: ConfigManager
    
    // Maximum characters per chunk to stay within LLM context limits
    private let maxChunkSize = 8000
    
    init(config: ConfigManager = .shared) {
        self.config = config
    }
    
    /// Process a transcript to correct transcription errors using the configured LLM
    func process(transcript: String) async throws -> String {
        let postProcessingConfig = config.config.transcription.postProcessing
        
        guard postProcessingConfig.enabled else {
            logger.info("Post-processing disabled, returning original transcript")
            return transcript
        }
        
        logger.info("Starting transcript post-processing")
        
        // Get the configured LLM provider
        let provider = try createProvider()
        let systemPrompt = postProcessingConfig.systemPrompt
        
        // For shorter transcripts, process in one go
        if transcript.count <= maxChunkSize {
            logger.info("Processing transcript in single chunk")
            return try await processChunk(transcript, provider: provider, systemPrompt: systemPrompt)
        }
        
        // For longer transcripts, split by speaker turns and process in chunks
        logger.info("Transcript too long (\(transcript.count) chars), processing in chunks")
        let chunks = splitTranscriptIntoChunks(transcript)
        logger.info("Split into \(chunks.count) chunks")
        
        var processedChunks: [String] = []
        for (index, chunk) in chunks.enumerated() {
            logger.info("Processing chunk \(index + 1)/\(chunks.count)")
            let processed = try await processChunk(chunk, provider: provider, systemPrompt: systemPrompt)
            processedChunks.append(processed)
        }
        
        let result = processedChunks.joined(separator: "\n")
        logger.info("Post-processing complete")
        return result
    }
    
    /// Process a single chunk of transcript
    private func processChunk(_ chunk: String, provider: LLMProvider, systemPrompt: String) async throws -> String {
        // Create a correction-specific user message
        let userMessage = """
        Please correct any transcription errors in the following meeting transcript. 
        Fix misspelled names, technical terms, and misheard words while preserving speaker labels and the original meaning.
        Return only the corrected transcript:

        \(chunk)
        """
        
        do {
            let corrected = try await provider.generate(transcript: userMessage, systemPrompt: systemPrompt)
            return corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.error("Error processing chunk: \(error.localizedDescription)")
            // Return original chunk if processing fails
            return chunk
        }
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
