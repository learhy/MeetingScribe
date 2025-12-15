import Foundation

enum TranscriptionError: Error {
    case invalidAudioFile
    case apiError(String)
    case networkError(Error)
    case invalidResponse
}

protocol TranscriptionProvider {
    func transcribe(audioFileURL: URL) async throws -> String
}

// MARK: - OpenAI Whisper Provider

class OpenAIWhisperProvider: TranscriptionProvider {
    private let apiKey: String
    private let model: String
    private let logger = DualLogger(category: "OpenAIWhisper")
    
    init(apiKey: String, model: String = "whisper-1") {
        self.apiKey = apiKey
        self.model = model
    }
    
    func transcribe(audioFileURL: URL) async throws -> String {
        logger.info("Transcribing audio file: \(audioFileURL.lastPathComponent)")
        
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // Create multipart form data
        let boundary = UUID().uuidString
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let httpBody = createMultipartBody(
            boundary: boundary,
            audioFileURL: audioFileURL,
            model: model
        )
        request.httpBody = httpBody
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranscriptionError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                logger.error("API error (\(httpResponse.statusCode)): \(errorMessage)")
                throw TranscriptionError.apiError(errorMessage)
            }
            
            struct WhisperResponse: Codable {
                let text: String
            }
            
            let decoder = JSONDecoder()
            let whisperResponse = try decoder.decode(WhisperResponse.self, from: data)
            
            logger.info("Transcription completed successfully")
            return whisperResponse.text
            
        } catch let error as TranscriptionError {
            throw error
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            throw TranscriptionError.networkError(error)
        }
    }
    
    private func createMultipartBody(boundary: String, audioFileURL: URL, model: String) -> Data {
        var body = Data()
        
        // Add model parameter
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("\(model)\r\n")
        
        // Add file parameter
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioFileURL.lastPathComponent)\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        
        if let fileData = try? Data(contentsOf: audioFileURL) {
            body.append(fileData)
        }
        
        body.append("\r\n")
        body.append("--\(boundary)--\r\n")
        
        return body
    }
}

// MARK: - Local Whisper Provider (Placeholder)

class LocalWhisperProvider: TranscriptionProvider {
    private let modelPath: URL
    private let logger = DualLogger(category: "LocalWhisper")
    
    init(modelPath: URL) {
        self.modelPath = modelPath
    }
    
    func transcribe(audioFileURL: URL) async throws -> String {
        logger.warning("Local Whisper not yet implemented - using placeholder")
        // TODO: Implement local whisper.cpp integration
        throw TranscriptionError.apiError("Local Whisper not implemented")
    }
}

// MARK: - Transcription Service

class TranscriptionService {
    private let logger = DualLogger(category: "TranscriptionService")
    private let config: ConfigManager
    
    init(config: ConfigManager = .shared) {
        self.config = config
    }
    
    func transcribe(audioFileURL: URL) async throws -> String {
        let provider = try createProvider()
        return try await provider.transcribe(audioFileURL: audioFileURL)
    }
    
    private func createProvider() throws -> TranscriptionProvider {
        let transcriptionConfig = config.config.transcription
        
        switch transcriptionConfig.provider {
        case "openai":
            let apiKey = try SecretsManager.shared.retrieveSecret(
                forKey: transcriptionConfig.openai.apiKeyKeychainItem
            )
            return OpenAIWhisperProvider(
                apiKey: apiKey,
                model: transcriptionConfig.openai.model
            )
            
        case "local":
            let modelPath = config.expandPath(transcriptionConfig.local.modelPath)
            return LocalWhisperProvider(modelPath: modelPath)
            
        default:
            logger.warning("Unknown provider '\(transcriptionConfig.provider)', falling back to OpenAI")
            let apiKey = try SecretsManager.shared.retrieveSecret(
                forKey: transcriptionConfig.openai.apiKeyKeychainItem
            )
            return OpenAIWhisperProvider(
                apiKey: apiKey,
                model: transcriptionConfig.openai.model
            )
        }
    }
}

// MARK: - Data Extension

extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
