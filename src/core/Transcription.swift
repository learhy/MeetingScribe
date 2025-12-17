import Foundation
import AVFoundation

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
        
        // Resample audio to 16kHz (required by whisper.cpp)
        let resampledURL = try await resampleAudio(audioFileURL: audioFileURL)
        defer {
            // Clean up resampled file
            try? FileManager.default.removeItem(at: resampledURL)
        }
        
        // Create temporary output directory
        let tempDir = FileManager.default.temporaryDirectory
        let outputPrefix = tempDir.appendingPathComponent(UUID().uuidString)
        
        // Run whisper.cpp with resampled audio
        // Command: ./main -m model.bin -f audio.wav -otxt -of output_prefix
        let process = Process()
        process.executableURL = whisperBinaryPath
        process.arguments = [
            "-m", modelPath.path,           // Model file
            "-f", resampledURL.path,        // Audio file (16kHz)
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
    
    private func resampleAudio(audioFileURL: URL) async throws -> URL {
        logger.info("Resampling audio to 16kHz for whisper.cpp...")
        
        // Create temporary file for resampled audio
        let tempDir = FileManager.default.temporaryDirectory
        let resampledURL = tempDir.appendingPathComponent("\(UUID().uuidString)_16k.wav")
        
        // Use ffmpeg for reliable resampling
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-i", audioFileURL.path,        // Input file
            "-ar", "16000",                 // Sample rate: 16kHz
            "-ac", "1",                     // Channels: mono
            "-c:a", "pcm_s16le",            // Codec: 16-bit PCM
            "-y",                           // Overwrite output file
            resampledURL.path               // Output file
        ]
        
        // Redirect stdin/stdout/stderr to prevent ffmpeg from hanging
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw TranscriptionError.apiError("ffmpeg resampling failed with exit code \(process.terminationStatus)")
        }
        
        logger.info("Audio resampled to 16kHz at: \(resampledURL.path)")
        return resampledURL
    }
}

// MARK: - Transcription Service

struct DiarizedSegment: Codable {
    let start: Double
    let end: Double
    let speaker: String
    let text: String
}

struct DiarizedTranscript: Codable {
    let segments: [DiarizedSegment]
    let speakers: [String]
    let numSpeakers: Int
    let audioFile: String
    
    enum CodingKeys: String, CodingKey {
        case segments
        case speakers
        case numSpeakers = "num_speakers"
        case audioFile = "audio_file"
    }
}

class TranscriptionService {
    private let logger = DualLogger(category: "TranscriptionService")
    private let config: ConfigManager
    
    init(config: ConfigManager = .shared) {
        self.config = config
    }
    
    func transcribe(audioFileURL: URL) async throws -> String {
        // Check if diarization is enabled
        if config.config.transcription.diarization.enabled {
            logger.info("Diarization enabled, attempting diarized transcription")
            do {
                let diarizedResult = try await transcribeWithDiarization(audioFileURL: audioFileURL)
                return formatDiarizedTranscript(diarizedResult)
            } catch {
                logger.warning("Diarization failed, falling back to standard transcription: \(error.localizedDescription)")
                // Fall through to standard transcription
            }
        }
        
        // Standard transcription (no diarization)
        let provider = try createProvider()
        return try await provider.transcribe(audioFileURL: audioFileURL)
    }
    
    func transcribeWithDiarization(audioFileURL: URL) async throws -> DiarizedTranscript {
        let diarizationConfig = config.config.transcription.diarization
        
        // Validate HuggingFace token
        guard !diarizationConfig.hfToken.isEmpty else {
            throw TranscriptionError.apiError("HuggingFace token not configured. Add it to ~/.meetingscribe/config.json under transcription.diarization.hfToken")
        }
        
        let pythonPath = diarizationConfig.pythonPath
        let scriptPath = config.expandPath(diarizationConfig.scriptPath)
        
        // Verify script exists
        guard FileManager.default.fileExists(atPath: scriptPath.path) else {
            throw TranscriptionError.apiError("Diarization script not found at: \(scriptPath.path)")
        }
        
        logger.info("Running diarization script: \(scriptPath.path)")
        
        // Build arguments
        var arguments = [
            scriptPath.path,
            audioFileURL.path,
            "--hf-token", diarizationConfig.hfToken,
            "--whisper-model", diarizationConfig.whisperModel
        ]
        
        if let minSpeakers = diarizationConfig.minSpeakers {
            arguments.append(contentsOf: ["--min-speakers", String(minSpeakers)])
        }
        if let maxSpeakers = diarizationConfig.maxSpeakers {
            arguments.append(contentsOf: ["--max-speakers", String(maxSpeakers)])
        }
        
        // Create temporary output file
        let tempDir = FileManager.default.temporaryDirectory
        let outputFile = tempDir.appendingPathComponent("\(UUID().uuidString)_diarization.json")
        arguments.append(contentsOf: ["--output", outputFile.path])
        
        // Execute Python script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = arguments
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            // Log stderr for debugging
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                logger.info("Diarization stderr: \(errorOutput)")
            }
            
            guard process.terminationStatus == 0 else {
                throw TranscriptionError.apiError("Diarization script failed with exit code \(process.terminationStatus)")
            }
            
            // Read output JSON
            guard FileManager.default.fileExists(atPath: outputFile.path) else {
                throw TranscriptionError.invalidResponse
            }
            
            let jsonData = try Data(contentsOf: outputFile)
            let decoder = JSONDecoder()
            let result = try decoder.decode(DiarizedTranscript.self, from: jsonData)
            
            // Clean up temporary file
            try? FileManager.default.removeItem(at: outputFile)
            
            logger.info("Diarization completed: \(result.numSpeakers) speakers detected")
            return result
            
        } catch let error as TranscriptionError {
            throw error
        } catch {
            logger.error("Diarization error: \(error.localizedDescription)")
            throw TranscriptionError.networkError(error)
        }
    }
    
    private func formatDiarizedTranscript(_ diarized: DiarizedTranscript) -> String {
        var formatted = ""
        
        for segment in diarized.segments {
            formatted += "\(segment.speaker): \(segment.text)\n"
        }
        
        return formatted.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func createProvider() throws -> TranscriptionProvider {
        let transcriptionConfig = config.config.transcription
        
        switch transcriptionConfig.provider {
        case "openai":
            let apiKey = transcriptionConfig.openai.apiKey
            guard !apiKey.isEmpty else {
                throw TranscriptionError.apiError("OpenAI API key not configured. Add it to ~/.meetingscribe/config.json")
            }
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
            let apiKey = transcriptionConfig.openai.apiKey
            guard !apiKey.isEmpty else {
                throw TranscriptionError.apiError("OpenAI API key not configured. Add it to ~/.meetingscribe/config.json")
            }
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
