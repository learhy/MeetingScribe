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

// MARK: - Local Whisper Provider

class LocalWhisperProvider: TranscriptionProvider {
    private let whisperBinaryPath: URL
    private let modelPath: URL
    private let logger = DualLogger(category: "LocalWhisper")
    
    init(modelPath: URL, whisperBinaryPath: URL? = nil) {
        self.modelPath = modelPath
        
        // Default to whisper.cpp in adjacent project if not specified
        if let customPath = whisperBinaryPath {
            self.whisperBinaryPath = customPath
        } else {
            // Try to find whisper.cpp in sibling directory
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            let softwareProjects = homeDir.appendingPathComponent("My Drive/software_projects")
            self.whisperBinaryPath = softwareProjects
                .appendingPathComponent("whisper.cpp")
                .appendingPathComponent("main")
        }
    }
    
    func transcribe(audioFileURL: URL) async throws -> String {
        logger.info("Starting local Whisper transcription...")
        logger.info("Binary: \(whisperBinaryPath.path)")
        logger.info("Model: \(modelPath.path)")
        logger.info("Audio: \(audioFileURL.path)")
        
        // Verify whisper binary exists
        guard FileManager.default.fileExists(atPath: whisperBinaryPath.path) else {
            throw TranscriptionError.apiError("Whisper binary not found at: \(whisperBinaryPath.path)")
        }
        
        // Verify model exists
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw TranscriptionError.apiError("Whisper model not found at: \(modelPath.path)")
        }
        
        // Verify audio file exists
        guard FileManager.default.fileExists(atPath: audioFileURL.path) else {
            throw TranscriptionError.invalidAudioFile
        }
        
        // Create temporary output directory
        let tempDir = FileManager.default.temporaryDirectory
        let outputPrefix = tempDir.appendingPathComponent(UUID().uuidString)
        
        // Run whisper.cpp
        // Command: ./main -m model.bin -f audio.wav -otxt -of output_prefix
        let process = Process()
        process.executableURL = whisperBinaryPath
        process.arguments = [
            "-m", modelPath.path,           // Model file
            "-f", audioFileURL.path,        // Audio file
            "-otxt",                        // Output as text
            "-of", outputPrefix.path,       // Output file prefix
            "--no-timestamps",              // Don't include timestamps in output
            "-t", "4"                       // Use 4 threads
        ]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let exitCode = process.terminationStatus
            
            // Log stderr output for debugging
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                logger.info("Whisper stderr: \(errorOutput)")
            }
            
            guard exitCode == 0 else {
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? "Unknown error"
                throw TranscriptionError.apiError("Whisper failed with exit code \(exitCode): \(output)")
            }
            
            // Read the output file
            let outputFile = URL(fileURLWithPath: "\(outputPrefix.path).txt")
            
            guard FileManager.default.fileExists(atPath: outputFile.path) else {
                throw TranscriptionError.invalidResponse
            }
            
            let transcript = try String(contentsOf: outputFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Clean up temporary file
            try? FileManager.default.removeItem(at: outputFile)
            
            guard !transcript.isEmpty else {
                throw TranscriptionError.invalidResponse
            }
            
            logger.info("Local transcription completed successfully")
            return transcript
            
        } catch let error as TranscriptionError {
            throw error
        } catch {
            logger.error("Local Whisper error: \(error.localizedDescription)")
            throw TranscriptionError.networkError(error)
        }
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
            let binaryPath = config.expandPath(transcriptionConfig.local.whisperBinaryPath)
            return LocalWhisperProvider(modelPath: modelPath, whisperBinaryPath: binaryPath)
            
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
