import Foundation

enum NotesGenerationError: Error {
    case apiError(String)
    case networkError(Error)
    case invalidResponse
    case promptLoadError
}

protocol LLMProvider {
    /// Generate a response from the LLM. The userMessage is passed directly to the model.
    func generate(userMessage: String, systemPrompt: String) async throws -> String
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
    
    func generate(userMessage: String, systemPrompt: String) async throws -> String {
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
                ["role": "user", "content": userMessage]
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
    
    func generate(userMessage: String, systemPrompt: String) async throws -> String {
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
                ["role": "user", "content": userMessage]
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
    
    func generate(userMessage: String, systemPrompt: String) async throws -> String {
        logger.info("Generating notes with Ollama \(model)")
        
        let url = URL(string: "\(endpoint)/api/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let prompt = "\(systemPrompt)\n\n\(userMessage)"
        
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

// MARK: - Nous Provider

/// Nous Research inference portal (OpenAI-compatible chat completions).
///
/// Auth resolves per call, in this order:
/// 1. Static `apiKey` (portal API key) when non-empty.
/// 2. OAuth token file (`authTokenFile`): JSON with access_token, refresh_token,
///    client_id, expires_at, portal_base_url, inference_base_url. Stale tokens
///    are refreshed via the portal and written back atomically (0600).
class NousProvider: LLMProvider {
    static let defaultInferenceBase = "https://inference-api.nousresearch.com/v1"
    static let defaultPortalBase = "https://portal.nousresearch.com"
    static let defaultModel = "z-ai/glm-5.3-flash"

    private let apiKey: String
    private let model: String
    private let authTokenFile: String
    private let logger = DualLogger(category: "Nous")
    private let timeoutSeconds: TimeInterval

    /// Serializes token refreshes across provider instances (the service
    /// constructs a fresh provider per call). Refresh tokens may be
    /// single-use, so concurrent refreshes must not race.
    private static let refreshLock = NSLock()

    init(apiKey: String = "", model: String = NousProvider.defaultModel,
         authTokenFile: String = "", timeoutSeconds: TimeInterval = 120) {
        self.apiKey = apiKey
        self.model = model
        self.authTokenFile = authTokenFile
        self.timeoutSeconds = timeoutSeconds
    }

    struct TokenState: Codable {
        let access_token: String
        let refresh_token: String?
        let client_id: String?
        let expires_at: String?
        let portal_base_url: String?
        let inference_base_url: String?
    }

    func generate(userMessage: String, systemPrompt: String) async throws -> String {
        logger.info("Generating notes with Nous \(model)")

        let token = try resolveBearerToken()
        let data: Data
        do {
            data = try await postChatCompletions(bearer: token, systemPrompt: systemPrompt, userMessage: userMessage)
        } catch let httpError as NousHTTPError {
            // A rotated/revoked token surfaces as 401/403: force one refresh and retry.
            logger.warning("Bearer rejected (HTTP \(httpError.statusCode)); forcing refresh and retrying once")
            let refreshed = try refreshNow(force: true)
            data = try await postChatCompletions(bearer: refreshed, systemPrompt: systemPrompt, userMessage: userMessage)
        }
        return try parseContent(data)
    }

    // MARK: - Auth resolution

    private func resolveBearerToken() throws -> String {
        if !apiKey.isEmpty {
            return apiKey
        }
        guard !authTokenFile.isEmpty else {
            throw NotesGenerationError.apiError(
                "Nous auth not configured — set notes.llm.nous.apiKey or notes.llm.nous.authTokenFile in ~/.meetingscribe/config.json")
        }
        return try refreshNow(force: false)
    }

    private func tokenFileURL() -> URL {
        let expanded = NSString(string: authTokenFile).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// Load the token file, refreshing when stale (or when `force`).
    /// Re-checks the file inside the lock so a refresh by another process
    /// (or provider instance) is honored instead of double-refreshing.
    private func refreshNow(force: Bool) throws -> String {
        try NousProvider.withRefreshLock {
            let url = tokenFileURL()
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NotesGenerationError.apiError("Nous auth token file not found: \(authTokenFile)")
            }
            let data = try Data(contentsOf: url)
            let state = try JSONDecoder().decode(TokenState.self, from: data)

            if !force, !NousProvider.isTokenStale(state.expires_at) {
                return state.access_token
            }

            let portal = (state.portal_base_url ?? NousProvider.defaultPortalBase).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !portal.isEmpty, let refresh = state.refresh_token, !refresh.isEmpty else {
                // Nothing to refresh with; if the stored token still looks valid, use it.
                if let exp = state.expires_at, !NousProvider.isTokenStale(exp) {
                    return state.access_token
                }
                throw NotesGenerationError.apiError("Nous access token is stale and no refresh token is available in \(authTokenFile)")
            }

            logger.info("Refreshing Nous access token via portal")
            var request = URLRequest(url: URL(string: "\(portal)/api/oauth/token")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = [
                URLQueryItem(name: "grant_type", value: "refresh_token"),
                URLQueryItem(name: "client_id", value: state.client_id ?? "hermes-cli"),
                URLQueryItem(name: "refresh_token", value: refresh)
            ]
            request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 30
            let session = URLSession(configuration: config)

            let respData: Data
            let resp: URLResponse
            do {
                // Synchronous request: refreshNow holds the refresh lock across
                // the call by design (refresh tokens may be single-use).
                let semaphore = DispatchSemaphore(value: 0)
                var outData: Data?
                var outResp: URLResponse?
                var outError: Error?
                let task = session.dataTask(with: request) { data, response, error in
                    outData = data
                    outResp = response
                    outError = error
                    semaphore.signal()
                }
                task.resume()
                semaphore.wait()
                if let error = outError {
                    throw NotesGenerationError.networkError(error)
                }
                guard let d = outData, let r = outResp else {
                    throw NotesGenerationError.invalidResponse
                }
                respData = d
                resp = r
            } catch let error as NotesGenerationError {
                throw error
            }
            guard let httpResponse = resp as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let detail = String(data: respData, encoding: .utf8) ?? ""
                logger.error("Token refresh failed: \(detail.prefix(300))")
                throw NotesGenerationError.apiError("Nous token refresh failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1))")
            }

            struct RefreshResponse: Codable {
                let access_token: String
                let refresh_token: String?
                let expires_in: Int?
            }
            let refreshResp = try JSONDecoder().decode(RefreshResponse.self, from: respData)

            var newState: [String: Any] = [
                "access_token": refreshResp.access_token,
                "refresh_token": refreshResp.refresh_token ?? refresh,
                "client_id": state.client_id ?? "hermes-cli",
                "expires_at": NousProvider.isoString(from: Date().addingTimeInterval(TimeInterval(refreshResp.expires_in ?? 3600))),
                "portal_base_url": state.portal_base_url ?? NousProvider.defaultPortalBase,
                "inference_base_url": state.inference_base_url ?? NousProvider.defaultInferenceBase
            ]
            if let scope = try? JSONDecoder().decode([String: String].self, from: respData)["scope"] {
                newState["scope"] = scope
            }

            let out = try JSONSerialization.data(withJSONObject: newState, options: [.prettyPrinted, .sortedKeys])
            let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
            try out.write(to: tmp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
            if !FileManager.default.fileExists(atPath: url.path) {
                // replaceItemAt can fail across volumes; fall back to remove+rename
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            logger.info("Nous access token refreshed and written back")
            return refreshResp.access_token
        }
    }

    /// Errors thrown for auth-retryable HTTP statuses.
    struct NousHTTPError: Error {
        let statusCode: Int
    }

    private func postChatCompletions(bearer: String, systemPrompt: String, userMessage: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(NousProvider.defaultInferenceBase)/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.addValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
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
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    throw NousHTTPError(statusCode: httpResponse.statusCode)
                }
                throw NotesGenerationError.apiError(errorMessage)
            }
            return data
        } catch let error as NotesGenerationError {
            throw error
        } catch let error as NousHTTPError {
            throw error
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            throw NotesGenerationError.networkError(error)
        }
    }

    private struct OpenAIResponse: Codable {
        struct Choice: Codable {
            struct Message: Codable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private func parseContent(_ data: Data) throws -> String {
        let decoded: OpenAIResponse
        do {
            decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        } catch {
            logger.error("Response decode failed: \(error.localizedDescription)")
            throw NotesGenerationError.invalidResponse
        }
        guard let raw = decoded.choices.first?.message.content else {
            throw NotesGenerationError.invalidResponse
        }
        let notes = NousProvider.stripThinking(from: raw)
        guard !notes.isEmpty else {
            logger.error("Empty notes content from Nous (reasoning-only response?)")
            throw NotesGenerationError.invalidResponse
        }
        logger.info("Notes generated successfully")
        return notes
    }

    // MARK: - Static helpers (unit-testable)

    /// Reasoning models (GLM/DeepSeek families) may wrap chain-of-thought in
    /// <think>...</think> before the answer. Notes must never contain it.
    static func stripThinking(from text: String) -> String {
        var out = text
        if let regex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>\\s*", options: []) {
            out = regex.stringByReplacingMatches(in: out, options: [], range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the token is missing, unparseable, or expires within `skew`.
    static func isTokenStale(_ expiresAt: String?, now: Date = Date(), skew: TimeInterval = 300) -> Bool {
        guard let expiresAt = expiresAt, !expiresAt.isEmpty else { return true }
        let formatters: [ISO8601DateFormatter] = {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return [plain, fractional]
        }()
        for formatter in formatters {
            if let date = formatter.date(from: expiresAt) {
                return date.timeIntervalSince(now) < skew
            }
        }
        return true
    }

    private static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func withRefreshLock<T>(_ body: () throws -> T) throws -> T {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        return try body()
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
            let userMessage = "Generate meeting notes from this transcript:\n\n\(transcript)"
            let notes = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await provider.generate(userMessage: userMessage, systemPrompt: systemPrompt)
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
                    try await provider.generate(userMessage: context, systemPrompt: titlePrompt)
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
    
    /// P1-2: provider access for the verification second pass.
    /// Returns nil (rather than throwing) when no LLM is configured, so the
    /// verification pass can degrade gracefully to deterministic label
    /// normalization only.
    func makeProviderIfConfigured() -> LLMProvider? {
        let notesConfig = config.config.notes.llm
        switch notesConfig.provider {
        case "openai":
            return notesConfig.openai.apiKey.isEmpty ? nil : OpenAIProvider(apiKey: notesConfig.openai.apiKey, model: notesConfig.openai.model, timeoutSeconds: 180)
        case "anthropic":
            return notesConfig.anthropic.apiKey.isEmpty ? nil : AnthropicProvider(apiKey: notesConfig.anthropic.apiKey, model: notesConfig.anthropic.model, timeoutSeconds: 180)
        case "ollama":
            return OllamaProvider(endpoint: notesConfig.ollama.endpoint, model: notesConfig.ollama.model, timeoutSeconds: 300)
        case "nous":
            let nous = notesConfig.nous
            if nous.apiKey.isEmpty && nous.authTokenFile.isEmpty {
                return nil
            }
            return NousProvider(apiKey: nous.apiKey, model: nous.model, authTokenFile: nous.authTokenFile, timeoutSeconds: 180)
        default:
            return nil
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

        case "nous":
            let nous = notesConfig.nous
            guard !nous.apiKey.isEmpty || !nous.authTokenFile.isEmpty else {
                throw NotesGenerationError.apiError("Nous auth not configured — set notes.llm.nous.apiKey or notes.llm.nous.authTokenFile in ~/.meetingscribe/config.json")
            }
            return NousProvider(apiKey: nous.apiKey, model: nous.model, authTokenFile: nous.authTokenFile, timeoutSeconds: timeoutSeconds)

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
        
        CRITICAL: Generate exactly ONE cohesive document with the following structure, regardless of transcript length:
        - Summary (at the top)
        - Key Points (all points in ONE section)
        - Action Items (if any - in ONE section)
        - Decisions (if any - in ONE section)
        - Next Steps (if any - in ONE section)
        
        DO NOT create multiple "Meeting Notes" sections or repeat headers. Process the entire transcript and consolidate all information into a single, unified document with the structure above.
        
        Be concise but comprehensive. Focus on actionable information.
        """
    }
}
