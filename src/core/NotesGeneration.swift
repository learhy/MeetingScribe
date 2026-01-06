import Foundation

enum NotesGenerationError: Error {
    case apiError(String)
    case networkError(Error)
    case invalidResponse
    case promptLoadError
}

protocol LLMProvider {
    func generate(transcript: String, systemPrompt: String) async throws -> String
}

// MARK: - OpenAI Provider

class OpenAIProvider: LLMProvider {
    private let apiKey: String
    private let model: String
    private let logger = DualLogger(category: "OpenAI")
    private let timeoutSeconds: TimeInterval
    
    init(apiKey: String, model: String = "gpt-4", timeoutSeconds: TimeInterval = 120) {
        self.apiKey = apiKey
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }
    
    func generate(transcript: String, systemPrompt: String) async throws -> String {
        logger.info("Generating notes with OpenAI \(model)")
        
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Generate meeting notes from this transcript:\n\n\(transcript)"]
            ],
            "max_tokens": 4096
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: config)
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NotesGenerationError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                logger.error("API error (\(httpResponse.statusCode)): \(errorMessage)")
                throw NotesGenerationError.apiError(errorMessage)
            }
            
            struct OpenAIResponse: Codable {
                struct Choice: Codable {
                    struct Message: Codable {
                        let content: String
                    }
                    let message: Message
                }
                let choices: [Choice]
            }
            
            let decoder = JSONDecoder()
            let openAIResponse = try decoder.decode(OpenAIResponse.self, from: data)
            
            guard let notes = openAIResponse.choices.first?.message.content else {
                throw NotesGenerationError.invalidResponse
            }
            
            logger.info("Notes generated successfully")
            return notes
            
        } catch let error as NotesGenerationError {
            throw error
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            throw NotesGenerationError.networkError(error)
        }
    }
}

// MARK: - Anthropic Provider

class AnthropicProvider: LLMProvider {
    private let apiKey: String
    private let model: String
    private let logger = DualLogger(category: "Anthropic")
    private let timeoutSeconds: TimeInterval
    
    init(apiKey: String, model: String = "claude-4.5-sonnet", timeoutSeconds: TimeInterval = 120) {
        self.apiKey = apiKey
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }
    
    func generate(transcript: String, systemPrompt: String) async throws -> String {
        logger.info("Generating notes with Anthropic \(model)")
        
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.addValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": "Generate meeting notes from this transcript:\n\n\(transcript)"]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: config)
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NotesGenerationError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                logger.error("API error (\(httpResponse.statusCode)): \(errorMessage)")
                throw NotesGenerationError.apiError(errorMessage)
            }
            
            struct AnthropicResponse: Codable {
                struct Content: Codable {
                    let type: String
                    let text: String
                }
                let content: [Content]
            }
            
            let decoder = JSONDecoder()
            let anthropicResponse = try decoder.decode(AnthropicResponse.self, from: data)
            
            guard let notes = anthropicResponse.content.first?.text else {
                throw NotesGenerationError.invalidResponse
            }
            
            logger.info("Notes generated successfully")
            return notes
            
        } catch let error as NotesGenerationError {
            throw error
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            throw NotesGenerationError.networkError(error)
        }
    }
}

// MARK: - Ollama Provider

class OllamaProvider: LLMProvider {
    private let endpoint: String
    private let model: String
    private let logger = DualLogger(category: "Ollama")
    private let timeoutSeconds: TimeInterval
    
    init(endpoint: String = "http://localhost:11434", model: String = "llama3", timeoutSeconds: TimeInterval = 120) {
        self.endpoint = endpoint
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }
    
    func generate(transcript: String, systemPrompt: String) async throws -> String {
        logger.info("Generating notes with Ollama \(model)")
        
        let url = URL(string: "\(endpoint)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let prompt = "\(systemPrompt)\n\nGenerate meeting notes from this transcript:\n\n\(transcript)"
        
        let requestBody: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        let session = URLSession(configuration: config)
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NotesGenerationError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                logger.error("API error (\(httpResponse.statusCode)): \(errorMessage)")
                throw NotesGenerationError.apiError(errorMessage)
            }
            
            struct OllamaResponse: Codable {
                let response: String
            }
            
            let decoder = JSONDecoder()
            let ollamaResponse = try decoder.decode(OllamaResponse.self, from: data)
            
            logger.info("Notes generated successfully")
            return ollamaResponse.response
            
        } catch let error as NotesGenerationError {
            throw error
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            throw NotesGenerationError.networkError(error)
        }
    }
}

// MARK: - Notes Generation Service

class NotesGenerationService {
    private let logger = DualLogger(category: "NotesGeneration")
    private let config: ConfigManager
    private let timeoutSeconds: TimeInterval = 120
    
    init(config: ConfigManager = .shared) {
        self.config = config
    }
    
    func generateNotes(transcript: String, participantContext: String? = nil) async throws -> String {
        var systemPrompt = try loadSystemPrompt()
        
        // Inject participant context if available
        if let context = participantContext, !context.isEmpty {
            systemPrompt = systemPrompt + "\n\n" + context
            logger.info("Injected participant context into system prompt")
        }
        
        let provider = try createProvider()

        let start = Date()
        logger.info("Notes generation started (timeout=\(Int(timeoutSeconds))s)")

        do {
            let timeoutSeconds = self.timeoutSeconds
            let notes = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await provider.generate(transcript: transcript, systemPrompt: systemPrompt)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    throw NotesGenerationError.apiError("Notes generation timed out after \(Int(timeoutSeconds))s")
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            let elapsed = Date().timeIntervalSince(start)
            logger.info("Notes generation finished in \(String(format: "%.1f", elapsed))s")
            return notes
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            logger.error("Notes generation failed after \(String(format: "%.1f", elapsed))s: \(error.localizedDescription)")
            throw error
        }
    }
    
    func generateTitle(transcript: String, summary: String) async throws -> String {
        let provider = try createProvider()
        let titleTimeout: TimeInterval = 30
        
        let start = Date()
        logger.info("Title generation started (timeout=\(Int(titleTimeout))s)")
        
        // Use first 2000 chars of transcript + summary as context
        let transcriptPrefix = String(transcript.prefix(2000))
        let context = "Summary: \(summary)\n\nTranscript excerpt: \(transcriptPrefix)"
        
        let titlePrompt = "Generate a brief, descriptive 3-7 word meeting title from the following content. Return only the title, no quotes or extra formatting."
        
        do {
            let title = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await provider.generate(transcript: context, systemPrompt: titlePrompt)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(titleTimeout))
                    throw NotesGenerationError.apiError("Title generation timed out after \(Int(titleTimeout))s")
                }
                
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
            
            let elapsed = Date().timeIntervalSince(start)
            logger.info("Title generation finished in \(String(format: "%.1f", elapsed))s")
            
            // Sanitize title
            let sanitized = title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "'", with: "")
                .prefix(100)
            
            return String(sanitized)
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            logger.warning("Title generation failed after \(String(format: "%.1f", elapsed))s: \(error.localizedDescription)")
            throw error
        }
    }
    
    private func loadSystemPrompt() throws -> String {
        let promptPath = config.expandPath(config.config.notes.llm.systemPromptFile)
        
        guard FileManager.default.fileExists(atPath: promptPath.path) else {
            // Return default prompt if file doesn't exist
            return defaultSystemPrompt
        }
        
        do {
            return try String(contentsOf: promptPath, encoding: .utf8)
        } catch {
            logger.warning("Failed to load custom prompt, using default")
            return defaultSystemPrompt
        }
    }
    
    private func createProvider() throws -> LLMProvider {
        let notesConfig = config.config.notes.llm
        
        switch notesConfig.provider {
        case "openai":
            let apiKey = notesConfig.openai.apiKey
            guard !apiKey.isEmpty else {
                throw NotesGenerationError.apiError("OpenAI API key not configured in ~/.meetingscribe/config.json")
            }
            return OpenAIProvider(apiKey: apiKey, model: notesConfig.openai.model, timeoutSeconds: timeoutSeconds)
            
        case "anthropic":
            let apiKey = notesConfig.anthropic.apiKey
            guard !apiKey.isEmpty else {
                throw NotesGenerationError.apiError("Anthropic API key not configured in ~/.meetingscribe/config.json")
            }
            return AnthropicProvider(apiKey: apiKey, model: notesConfig.anthropic.model, timeoutSeconds: timeoutSeconds)
            
        case "ollama":
            return OllamaProvider(endpoint: notesConfig.ollama.endpoint, model: notesConfig.ollama.model, timeoutSeconds: timeoutSeconds)
            
        default:
            logger.warning("Unknown provider '\(notesConfig.provider)', falling back to Anthropic")
            let apiKey = notesConfig.anthropic.apiKey
            guard !apiKey.isEmpty else {
                throw NotesGenerationError.apiError("Anthropic API key not configured in ~/.meetingscribe/config.json")
            }
            return AnthropicProvider(apiKey: apiKey, model: notesConfig.anthropic.model, timeoutSeconds: timeoutSeconds)
        }
    }
    
    private var defaultSystemPrompt: String {
        """
        You are a professional meeting notes assistant. Your task is to generate clear, concise, and well-structured meeting notes from transcripts.
        
        Guidelines:
        1. Start with a brief summary (2-3 sentences) of the meeting's purpose and outcome
        2. Extract key discussion points as bullet points
        3. Identify action items with owners (if mentioned)
        4. List any decisions made
        5. Note any follow-up meetings or deadlines
        6. Use clear, professional language
        7. Format output in Markdown
        
        Structure:
        - Summary
        - Key Points
        - Action Items (if any)
        - Decisions (if any)
        - Next Steps (if any)
        
        Be concise but comprehensive. Focus on actionable information.
        """
    }
}
