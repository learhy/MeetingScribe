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
        
        // Verify model exists and is a file (not a directory)
        var modelIsDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelPath.path, isDirectory: &modelIsDir),
              !modelIsDir.boolValue else {
            throw TranscriptionError.apiError(
                "Whisper model path is not a valid file: \(modelPath.path). " +
                "Please set modelPath to a specific .bin model file " +
                "(e.g., .../models/ggml-large-v3-turbo.bin)"
            )
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
    private let postProcessor: TranscriptPostProcessor
    
    init(config: ConfigManager = .shared) {
        self.config = config
        self.postProcessor = TranscriptPostProcessor(config: config)
    }
    
    func transcribe(audioFileURL: URL) async throws -> String {
        var transcript: String
        
        // Check if diarization is enabled
        if config.config.transcription.diarization.enabled {
            logger.info("Diarization enabled, attempting diarized transcription")
            do {
                let diarizedResult = try await transcribeWithDiarization(audioFileURL: audioFileURL)
                transcript = formatDiarizedTranscript(diarizedResult)
            } catch {
                logger.warning("Diarization failed, falling back to standard transcription: \(error.localizedDescription)")
                // Fall through to standard transcription
                let provider = try createProvider()
                transcript = try await provider.transcribe(audioFileURL: audioFileURL)
            }
        } else {
            // Standard transcription (no diarization)
            let provider = try createProvider()
            transcript = try await provider.transcribe(audioFileURL: audioFileURL)
        }
        
        // Apply LLM post-processing if enabled
        if config.config.transcription.postProcessing.enabled {
            logger.info("Applying LLM post-processing to transcript")
            do {
                transcript = try await postProcessor.process(transcript: transcript)
                logger.info("Post-processing completed successfully")
            } catch {
                logger.warning("Post-processing failed, using original transcript: \(error.localizedDescription)")
            }
        }
        
        return transcript
    }
    
    func transcribeWithDiarization(audioFileURL: URL) async throws -> DiarizedTranscript {
        let diarizationConfig = config.config.transcription.diarization
        
        // Log audio file metadata
        if let attrs = try? FileManager.default.attributesOfItem(atPath: audioFileURL.path),
           let fileSize = attrs[.size] as? Int64 {
            let fileSizeMB = Double(fileSize) / 1_000_000.0
            // Estimate duration: 48kHz, 16-bit stereo = ~192KB/sec
            let estimatedDuration = Double(fileSize) / 192_000.0
            let minutes = Int(estimatedDuration) / 60
            let seconds = Int(estimatedDuration) % 60
            logger.info("Audio file: \(audioFileURL.lastPathComponent) (\(String(format: "%.1f", fileSizeMB)) MB, ~\(minutes)m \(seconds)s)")
        }
        
        // Try bundled Python first, fall back to config
        let pythonPath: String
        if let bundled = config.bundledPythonPath {
            pythonPath = bundled
            logger.info("Using bundled Python at: \(bundled)")
        } else {
            pythonPath = diarizationConfig.pythonPath
            logger.info("Using system Python: \(pythonPath)")
        }
        
        // Try bundled script first, fall back to config
        let scriptPath: URL
        if let bundled = config.bundledScriptPath {
            scriptPath = URL(fileURLWithPath: bundled)
            logger.info("Using bundled diarization script")
        } else {
            scriptPath = config.expandPath(diarizationConfig.scriptPath)
            logger.info("Using diarization script from config: \(scriptPath.path)")
        }
        
        // Verify script exists
        guard FileManager.default.fileExists(atPath: scriptPath.path) else {
            throw TranscriptionError.apiError("Diarization script not found at: \(scriptPath.path)")
        }
        
        logger.info("Running fast diarization script: \(scriptPath.path)")
        
        // Build arguments for fast diarization (no HF token required)
        var arguments = [
            scriptPath.path,
            audioFileURL.path,
            "--whisper-model", diarizationConfig.whisperModel,
            "--distance-threshold", String(diarizationConfig.distanceThreshold)
        ]
        
        // Add initial prompt if configured
        if !diarizationConfig.initialPrompt.isEmpty {
            arguments.append(contentsOf: ["--initial-prompt", diarizationConfig.initialPrompt])
            logger.info("Using initial prompt for Whisper")
        }
        
        // Add vocabulary file if configured
        if !diarizationConfig.vocabularyFile.isEmpty {
            let vocabPath = config.expandPath(diarizationConfig.vocabularyFile)
            if FileManager.default.fileExists(atPath: vocabPath.path) {
                arguments.append(contentsOf: ["--vocabulary-file", vocabPath.path])
                logger.info("Using vocabulary file: \(vocabPath.path)")
            } else {
                logger.warning("Vocabulary file not found: \(vocabPath.path)")
            }
        }
        
        // Add smart prompt flags if enabled
        let smartPromptConfig = config.config.transcription.smartPrompt
        if smartPromptConfig.enabled {
            arguments.append("--smart-prompt")
            arguments.append(contentsOf: ["--speaker-db-path", config.expandPath(smartPromptConfig.speakerDbPath).path])
            
            if !smartPromptConfig.ragEndpoint.isEmpty {
                arguments.append(contentsOf: ["--rag-endpoint", smartPromptConfig.ragEndpoint])
            }
            
            if smartPromptConfig.enableIterativeRefinement {
                arguments.append("--iterative-refinement")
            }
            
            arguments.append(contentsOf: ["--quick-transcribe-seconds", String(smartPromptConfig.quickTranscribeSeconds)])
            
            logger.info("Smart prompt generation enabled (version \(smartPromptConfig.version))")
        }
        
        // Note: min/max speakers not supported by fast diarization
        // It auto-detects based on distance threshold
        
        // Create temporary output file
        let tempDir = FileManager.default.temporaryDirectory
        let outputFile = tempDir.appendingPathComponent("\(UUID().uuidString)_diarization.json")
        arguments.append(contentsOf: ["--output", outputFile.path])
        
        // Execute Python script
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = arguments
        
        // Set PYTHONUNBUFFERED to get real-time stderr output
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        // Buffer for incomplete lines
        var lineBuffer = ""
        let logger = self.logger  // Capture for closure
        
        // Stream stderr in real-time using readabilityHandler
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            
            if let output = String(data: data, encoding: .utf8) {
                lineBuffer += output
                
                // Process complete lines
                while let newlineIndex = lineBuffer.firstIndex(of: "\n") {
                    let line = String(lineBuffer[..<newlineIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                    lineBuffer = String(lineBuffer[lineBuffer.index(after: newlineIndex)...])
                    
                    if !line.isEmpty {
                        // Always log the raw line (don't silently swallow malformed output)
                        logger.info("[Diarization] \(line)")
                    }
                }
            }
        }
        
        do {
            try process.run()
            process.waitUntilExit()
            
            // Clean up the readability handler
            errorPipe.fileHandleForReading.readabilityHandler = nil
            
            // Log any remaining buffered content
            if !lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.info("[Diarization] \(lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines))")
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
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
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
