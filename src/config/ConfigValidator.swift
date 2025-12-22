import Foundation

/// Represents a validation error with user-friendly message
struct ValidationError {
    let field: String
    let message: String
}

/// Validates configuration values and returns user-friendly error messages
class ConfigValidator {
    
    // MARK: - Field-Level Validators
    
    /// Validate that a string is not empty
    static func validateNonEmpty(_ value: String, field: String) -> ValidationError? {
        if value.trimmingCharacters(in: .whitespaces).isEmpty {
            return ValidationError(field: field, message: "\(field) cannot be empty")
        }
        return nil
    }
    
    /// Validate that a path exists
    static func validatePathExists(_ path: String, field: String) -> ValidationError? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: expandedPath) {
            return ValidationError(field: field, message: "\(field): Path does not exist")
        }
        return nil
    }
    
    /// Validate that a path is a directory
    static func validateIsDirectory(_ path: String, field: String) -> ValidationError? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                return ValidationError(field: field, message: "\(field): Must be a directory")
            }
        }
        return nil
    }
    
    /// Validate that a path is executable
    static func validateIsExecutable(_ path: String, field: String) -> ValidationError? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        if !FileManager.default.isExecutableFile(atPath: expandedPath) {
            return ValidationError(field: field, message: "\(field): File is not executable")
        }
        return nil
    }
    
    /// Validate URL format
    static func validateURL(_ urlString: String, field: String) -> ValidationError? {
        if URL(string: urlString) == nil {
            return ValidationError(field: field, message: "\(field): Invalid URL format")
        }
        return nil
    }
    
    /// Validate integer is positive
    static func validatePositive(_ value: Int, field: String) -> ValidationError? {
        if value <= 0 {
            return ValidationError(field: field, message: "\(field): Must be greater than 0")
        }
        return nil
    }
    
    /// Validate integer is within range
    static func validateRange(_ value: Int, min: Int, max: Int, field: String) -> ValidationError? {
        if value < min || value > max {
            return ValidationError(field: field, message: "\(field): Must be between \(min) and \(max)")
        }
        return nil
    }
    
    /// Validate double is within range
    static func validateRange(_ value: Double, min: Double, max: Double, field: String) -> ValidationError? {
        if value < min || value > max {
            return ValidationError(field: field, message: "\(field): Must be between \(min) and \(max)")
        }
        return nil
    }
    
    // MARK: - Section Validators
    
    /// Validate audio configuration
    static func validateAudio(_ audio: AppConfiguration.Audio) -> [ValidationError] {
        var errors: [ValidationError] = []
        
        // Sample rate must be positive
        if let error = validatePositive(audio.sampleRate, field: "Sample Rate") {
            errors.append(error)
        }
        
        // Bit depth must be 8, 16, 24, or 32
        if ![8, 16, 24, 32].contains(audio.bitDepth) {
            errors.append(ValidationError(field: "Bit Depth", message: "Bit Depth must be 8, 16, 24, or 32"))
        }
        
        // Channels must be 1 or 2
        if ![1, 2].contains(audio.channels) {
            errors.append(ValidationError(field: "Channels", message: "Channels must be 1 (Mono) or 2 (Stereo)"))
        }
        
        // Output directory must not be empty
        if let error = validateNonEmpty(audio.outputDirectory, field: "Output Directory") {
            errors.append(error)
        }
        
        return errors
    }
    
    /// Validate detection configuration
    static func validateDetection(_ detection: AppConfiguration.Detection) -> [ValidationError] {
        var errors: [ValidationError] = []
        
        // Poll interval must be >= 1
        if detection.pollInterval < 1.0 {
            errors.append(ValidationError(field: "Poll Interval", message: "Poll Interval must be at least 1 second"))
        }
        
        // Confidence threshold must be 0-100
        if let error = validateRange(detection.confidenceThreshold, min: 0, max: 100, field: "Confidence Threshold") {
            errors.append(error)
        }
        
        // Debounce checks must be >= 1
        if let error = validatePositive(detection.debounceChecks, field: "Debounce Checks") {
            errors.append(error)
        }
        
        return errors
    }
    
    /// Validate transcription configuration
    static func validateTranscription(_ transcription: AppConfiguration.Transcription) -> [ValidationError] {
        var errors: [ValidationError] = []
        
        // Validate based on selected provider
        switch transcription.provider {
        case "local":
            if let error = validateNonEmpty(transcription.local.whisperBinaryPath, field: "Whisper Binary Path") {
                errors.append(error)
            }
            if let error = validateNonEmpty(transcription.local.modelPath, field: "Model Path") {
                errors.append(error)
            }
            
        case "openai":
            if let error = validateNonEmpty(transcription.openai.apiKey, field: "OpenAI API Key") {
                errors.append(error)
            }
            if let error = validateNonEmpty(transcription.openai.model, field: "OpenAI Model") {
                errors.append(error)
            }
            
        default:
            errors.append(ValidationError(field: "Provider", message: "Invalid transcription provider"))
        }
        
        // Validate diarization if enabled
        if transcription.diarization.enabled {
            if let error = validateNonEmpty(transcription.diarization.pythonPath, field: "Python Path") {
                errors.append(error)
            }
            if let error = validateNonEmpty(transcription.diarization.scriptPath, field: "Diarization Script Path") {
                errors.append(error)
            }
            if let error = validateRange(transcription.diarization.distanceThreshold, min: 0.0, max: 1.0, field: "Distance Threshold") {
                errors.append(error)
            }
        }
        
        return errors
    }
    
    /// Validate notes configuration
    static func validateNotes(_ notes: AppConfiguration.Notes) -> [ValidationError] {
        var errors: [ValidationError] = []
        
        // Template file must not be empty
        if let error = validateNonEmpty(notes.templateFile, field: "Template File") {
            errors.append(error)
        }
        
        // Validate LLM provider
        switch notes.llm.provider {
        case "openai":
            if let error = validateNonEmpty(notes.llm.openai.apiKey, field: "OpenAI API Key") {
                errors.append(error)
            }
            if let error = validateNonEmpty(notes.llm.openai.model, field: "OpenAI Model") {
                errors.append(error)
            }
            
        case "anthropic":
            if let error = validateNonEmpty(notes.llm.anthropic.apiKey, field: "Anthropic API Key") {
                errors.append(error)
            }
            if let error = validateNonEmpty(notes.llm.anthropic.model, field: "Anthropic Model") {
                errors.append(error)
            }
            
        case "ollama":
            if let error = validateNonEmpty(notes.llm.ollama.endpoint, field: "Ollama Endpoint") {
                errors.append(error)
            }
            if let error = validateURL(notes.llm.ollama.endpoint, field: "Ollama Endpoint") {
                errors.append(error)
            }
            if let error = validateNonEmpty(notes.llm.ollama.model, field: "Ollama Model") {
                errors.append(error)
            }
            
        default:
            errors.append(ValidationError(field: "LLM Provider", message: "Invalid LLM provider"))
        }
        
        // Validate backend-specific settings
        switch notes.backend {
        case "bear":
            if notes.bear.tags.isEmpty {
                errors.append(ValidationError(field: "Bear Tags", message: "At least one tag is required"))
            }
            if let error = validateNonEmpty(notes.bear.fallbackDirectory, field: "Bear Fallback Directory") {
                errors.append(error)
            }
            
        default:
            errors.append(ValidationError(field: "Notes Backend", message: "Invalid notes backend"))
        }
        
        return errors
    }
    
    /// Validate entire configuration
    static func validateConfiguration(_ config: AppConfiguration) -> [ValidationError] {
        var errors: [ValidationError] = []
        
        errors.append(contentsOf: validateAudio(config.audio))
        errors.append(contentsOf: validateDetection(config.detection))
        errors.append(contentsOf: validateTranscription(config.transcription))
        errors.append(contentsOf: validateNotes(config.notes))
        
        return errors
    }
}
