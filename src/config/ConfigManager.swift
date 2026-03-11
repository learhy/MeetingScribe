import Foundation

// Type aliases for convenience and test compatibility
typealias GlossaryEntry = AppConfiguration.Transcription.GlossaryEntry
typealias Glossary = AppConfiguration.Transcription.Glossary

struct AppConfiguration: Codable {
    struct Detection: Codable {
        var pollInterval: Double = 2.0
        var debounceChecks: Int = 2
        var confidenceThreshold: Int = 85
    }
    
    struct Audio: Codable {
        var outputDirectory: String = "~/Documents/MeetingScribe/recordings/"
        var sampleRate: Int = 48000
        var bitDepth: Int = 16
        var channels: Int = 2
        var mixMode: String = "stereo_separated"  // "stereo_separated" | "mono_mixed"
        var microphoneEnabled: Bool = true  // Explicit mic toggle (ANDed with OS permission)
        var systemGain: Double = 1.0  // Per-channel volume for system audio
        var micGain: Double = 1.0  // Per-channel volume for microphone audio
        
        // Custom decoder for backwards compatibility with existing config files
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            outputDirectory = try container.decodeIfPresent(String.self, forKey: .outputDirectory) ?? "~/Documents/MeetingScribe/recordings/"
            sampleRate = try container.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 48000
            bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth) ?? 16
            channels = try container.decodeIfPresent(Int.self, forKey: .channels) ?? 2
            mixMode = try container.decodeIfPresent(String.self, forKey: .mixMode) ?? "stereo_separated"
            microphoneEnabled = try container.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? true
            systemGain = try container.decodeIfPresent(Double.self, forKey: .systemGain) ?? 1.0
            micGain = try container.decodeIfPresent(Double.self, forKey: .micGain) ?? 1.0
        }
        
        init() {}
        
        private enum CodingKeys: String, CodingKey {
            case outputDirectory, sampleRate, bitDepth, channels
            case mixMode, microphoneEnabled, systemGain, micGain
        }
    }
    
    struct Transcription: Codable {
        var provider: String = "local"  // "openai" | "local"
        
        struct OpenAI: Codable {
            var apiKey: String = ""
            var model: String = "whisper-1"
        }
        
        struct Local: Codable {
            var modelPath: String = ""
            var whisperBinaryPath: String = ""
        }
        
        struct Diarization: Codable {
            var enabled: Bool = false
            var minSpeakers: Int? = nil
            var maxSpeakers: Int? = nil
            var hfToken: String = ""  // No longer required for fast diarization
            var pythonPath: String = "python3"
            var scriptPath: String = "/Applications/MeetingScribe.app/Contents/Resources/scripts/diarize_audio_fast.py"
            var whisperModel: String = "turbo"  // tiny, base, small, medium, large, turbo
            var distanceThreshold: Double = 0.25  // Cosine DISTANCE threshold (1 - similarity). 0.25 = merge if similarity > 0.75. Range: 0.15-0.40
            var vocabularyFile: String = ""  // Optional path to vocabulary file with domain terms
            var initialPrompt: String = ""  // Optional initial prompt for Whisper (e.g., "Glossary: QBR, MBR, GTM")
        }
        
        struct SmartPrompt: Codable {
            var enabled: Bool = false
            var version: Int = 1  // Increment when behavior changes significantly
            var speakerDbPath: String = "~/.meetingscribe/speaker.db"
            var ragEndpoint: String = ""  // Empty = disabled
            var quickTranscribeSeconds: Double = 45.0
            var cacheConfidenceThreshold: Double = 0.8
            var enableIterativeRefinement: Bool = true  // Two-pass quick transcription
            
            // Custom decoder for backwards compatibility
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
                version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
                speakerDbPath = try container.decodeIfPresent(String.self, forKey: .speakerDbPath) ?? "~/.meetingscribe/speaker.db"
                ragEndpoint = try container.decodeIfPresent(String.self, forKey: .ragEndpoint) ?? ""
                quickTranscribeSeconds = try container.decodeIfPresent(Double.self, forKey: .quickTranscribeSeconds) ?? 45.0
                cacheConfidenceThreshold = try container.decodeIfPresent(Double.self, forKey: .cacheConfidenceThreshold) ?? 0.8
                enableIterativeRefinement = try container.decodeIfPresent(Bool.self, forKey: .enableIterativeRefinement) ?? true
            }
            
            init() {}
            
            init(enabled: Bool = false, version: Int = 1, speakerDbPath: String = "~/.meetingscribe/speaker.db",
                 ragEndpoint: String = "", quickTranscribeSeconds: Double = 45.0,
                 cacheConfidenceThreshold: Double = 0.8, enableIterativeRefinement: Bool = true) {
                self.enabled = enabled
                self.version = version
                self.speakerDbPath = speakerDbPath
                self.ragEndpoint = ragEndpoint
                self.quickTranscribeSeconds = quickTranscribeSeconds
                self.cacheConfidenceThreshold = cacheConfidenceThreshold
                self.enableIterativeRefinement = enableIterativeRefinement
            }
            
            private enum CodingKeys: String, CodingKey {
                case enabled, version, speakerDbPath, ragEndpoint, quickTranscribeSeconds
                case cacheConfidenceThreshold, enableIterativeRefinement
            }
        }
        
        struct PostProcessing: Codable {
            var enabled: Bool = false
            var systemPrompt: String = "You are a transcript correction assistant. Your task is to fix obvious transcription errors in the following meeting transcript while preserving the original meaning and speaker labels. Fix misspelled names, technical terms, and words that were clearly misheard. Do not add, remove, or rephrase content - only correct errors. Return only the corrected transcript without explanations."
        }
        
        struct GlossaryEntry: Codable {
            var term: String
            var pronunciation: String?
            var context: String?
            var aliases: [String]?
        }
        
        struct Glossary: Codable {
            var enabled: Bool = false
            var entries: [GlossaryEntry] = []  // Legacy: kept for migration, ignored after glossary.json exists
            var maxSize: Int = 1000
            var maxGlossaryTokens: Int = 2000  // Token budget for filtered glossary injection
            var filteringEnabled: Bool = true  // false = inject full glossary (legacy behavior)
            var phoneticMatchingEnabled: Bool = true  // false = exact match only
            
            // Custom decoder to handle backwards compatibility with existing config files
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
                entries = try container.decodeIfPresent([GlossaryEntry].self, forKey: .entries) ?? []
                maxSize = try container.decodeIfPresent(Int.self, forKey: .maxSize) ?? 1000
                maxGlossaryTokens = try container.decodeIfPresent(Int.self, forKey: .maxGlossaryTokens) ?? 2000
                filteringEnabled = try container.decodeIfPresent(Bool.self, forKey: .filteringEnabled) ?? true
                phoneticMatchingEnabled = try container.decodeIfPresent(Bool.self, forKey: .phoneticMatchingEnabled) ?? true
            }
            
            init() {}
            
            init(enabled: Bool = false, entries: [GlossaryEntry] = [], maxSize: Int = 1000,
                 maxGlossaryTokens: Int = 2000, filteringEnabled: Bool = true, phoneticMatchingEnabled: Bool = true) {
                self.enabled = enabled
                self.entries = entries
                self.maxSize = maxSize
                self.maxGlossaryTokens = maxGlossaryTokens
                self.filteringEnabled = filteringEnabled
                self.phoneticMatchingEnabled = phoneticMatchingEnabled
            }
            
            private enum CodingKeys: String, CodingKey {
                case enabled, entries, maxSize, maxGlossaryTokens, filteringEnabled, phoneticMatchingEnabled
            }
        }
        
        /// Standalone glossary file structure — entries live here, not in config.json
        struct GlossaryFile: Codable {
            var entries: [GlossaryEntry] = []
            
            init() {}
            init(entries: [GlossaryEntry]) {
                self.entries = entries
            }
        }
        
        var openai: OpenAI = OpenAI()
        var local: Local = Local()
        var diarization: Diarization = Diarization()
        var postProcessing: PostProcessing = PostProcessing()
        var glossary: Glossary = Glossary()
        var smartPrompt: SmartPrompt = SmartPrompt()
    }
    
    struct Notes: Codable {
        struct LLM: Codable {
            var provider: String = "anthropic"  // "openai" | "anthropic" | "ollama"
            
            struct OpenAI: Codable {
                var apiKey: String = ""
                var model: String = "gpt-4"
            }
            
            struct Anthropic: Codable {
                var apiKey: String = ""
                var model: String = "claude-sonnet-4-5"
            }
            
            struct Ollama: Codable {
                var endpoint: String = "http://localhost:11434"
                var model: String = "llama3"
            }
            
            var openai: OpenAI = OpenAI()
            var anthropic: Anthropic = Anthropic()
            var ollama: Ollama = Ollama()
            var systemPromptFile: String = "~/.meetingscribe/prompts/default.txt"
        }
        
        var llm: LLM = LLM()
        var templateFile: String = "~/.meetingscribe/templates/default.md"
        var backend: String = "bear"  // "bear" | "notion" | "obsidian"
        
        struct Bear: Codable {
            var tags: [String] = ["#meetings", "#teams"]
            var fallbackDirectory: String = "~/Documents/MeetingScribe/notes/"
        }
        
        var bear: Bear = Bear()
    }
    
    struct UI: Codable {
        var showNotifications: Bool = true
        var notifyOnStart: Bool = true
        var notifyOnEnd: Bool = true
        var autoRecordingEnabled: Bool = true
    }
    
    struct Participants: Codable {
        var enabled: Bool = true
        var calendarSource: String = "eventkit"  // "eventkit" | "outlook" | "both"
        var eventKitCalendarName: String = "Calendar"
        var outlookDatabasePath: String = "~/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile/Data/"
        var debugLogging: Bool = false
    }
    
    var version: String = "1.0"
    var detection: Detection = Detection()
    var audio: Audio = Audio()
    var transcription: Transcription = Transcription()
    var notes: Notes = Notes()
    var ui: UI = UI()
    var participants: Participants = Participants()
}

class ConfigManager {
    static let shared = ConfigManager()
    
    private let logger = DualLogger(category: "ConfigManager")
    private let configPath: URL
    private let glossaryPath: URL
    private(set) var config: AppConfiguration
    private(set) var glossaryEntries: [GlossaryEntry] = []
    
    /// Callback triggered when configuration is saved
    var onConfigChanged: (() -> Void)?
    
    private init() {
        // Config file path
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let configDir = homeDir.appendingPathComponent(".meetingscribe")
        self.configPath = configDir.appendingPathComponent("config.json")
        self.glossaryPath = configDir.appendingPathComponent("glossary.json")
        
        // Load or create default config
        if let loadedConfig = Self.loadConfig(from: configPath) {
            self.config = loadedConfig
        } else {
            self.config = AppConfiguration()
            Self.saveConfig(config, to: configPath)
        }
        
        // Load glossary from standalone file, migrating from config.json if needed
        loadGlossary()
    }
    
    private static func loadConfig(from url: URL) -> AppConfiguration? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(AppConfiguration.self, from: data)
        } catch {
            print("Error loading config: \(error)")
            return nil
        }
    }
    
    private static func saveConfig(_ config: AppConfiguration, to url: URL) {
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Error saving config: \(error)")
        }
    }
    
    func reload() {
        if let loadedConfig = Self.loadConfig(from: configPath) {
            self.config = loadedConfig
            logger.info("Configuration reloaded")
        }
        loadGlossary()
    }
    
    func save() {
        // Strip entries from config before saving — they live in glossary.json now
        var configToSave = config
        configToSave.transcription.glossary.entries = []
        Self.saveConfig(configToSave, to: configPath)
        logger.info("Configuration saved")
        onConfigChanged?()
    }
    
    func updateAndSave(_ newConfig: AppConfiguration) {
        self.config = newConfig
        save()
    }
    
    // MARK: - Glossary Persistence
    
    /// Load glossary entries from standalone file, migrating from config.json if needed
    private func loadGlossary() {
        if let glossaryFile = Self.loadGlossaryFile(from: glossaryPath) {
            glossaryEntries = glossaryFile.entries
            logger.info("Glossary loaded: \(glossaryEntries.count) entries from glossary.json")
        } else if !config.transcription.glossary.entries.isEmpty {
            // Migration: entries exist in config.json but no glossary.json yet
            glossaryEntries = config.transcription.glossary.entries
            logger.info("Migrating \(glossaryEntries.count) glossary entries from config.json to glossary.json")
            saveGlossary()
            
            // Clear entries from config.json to complete migration
            config.transcription.glossary.entries = []
            Self.saveConfig(config, to: configPath)
            logger.info("Migration complete — entries removed from config.json")
        } else {
            glossaryEntries = []
            logger.info("No glossary entries found")
        }
    }
    
    private static func loadGlossaryFile(from url: URL) -> AppConfiguration.Transcription.GlossaryFile? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(AppConfiguration.Transcription.GlossaryFile.self, from: data)
        } catch {
            print("Error loading glossary: \(error)")
            return nil
        }
    }
    
    /// Save glossary entries to standalone file with backup
    func saveGlossary() {
        do {
            let dir = glossaryPath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            
            // Back up existing file before overwriting
            let backupPath = glossaryPath.appendingPathExtension("bak")
            if FileManager.default.fileExists(atPath: glossaryPath.path) {
                try? FileManager.default.removeItem(at: backupPath)
                try? FileManager.default.copyItem(at: glossaryPath, to: backupPath)
            }
            
            let glossaryFile = AppConfiguration.Transcription.GlossaryFile(entries: glossaryEntries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(glossaryFile)
            try data.write(to: glossaryPath, options: .atomic)
            logger.info("Glossary saved: \(glossaryEntries.count) entries")
        } catch {
            logger.error("Error saving glossary: \(error)")
        }
    }
    
    /// Update glossary entries and save
    func updateGlossaryEntries(_ entries: [GlossaryEntry]) {
        self.glossaryEntries = entries
        saveGlossary()
        onConfigChanged?()
    }
    
    func updateAutoRecordingEnabled(_ enabled: Bool) {
        config.ui.autoRecordingEnabled = enabled
        save()
    }
    
    func expandPath(_ path: String) -> URL {
        let nsPath = NSString(string: path)
        let expandedPath = nsPath.expandingTildeInPath
        return URL(fileURLWithPath: expandedPath)
    }
    
    // MARK: - Bundled Python Detection
    
    /// Returns the path to bundled Python if it exists in the app bundle
    var bundledPythonPath: String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let pythonPath = "\(resourcePath)/python/bin/python3"
        return FileManager.default.fileExists(atPath: pythonPath) ? pythonPath : nil
    }
    
    /// Returns the path to bundled diarization script if it exists in the app bundle
    var bundledScriptPath: String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let scriptPath = "\(resourcePath)/scripts/diarize_audio_fast.py"
        return FileManager.default.fileExists(atPath: scriptPath) ? scriptPath : nil
    }
    
    // MARK: - Validation Helpers
    
    /// Check if at least one LLM provider has a valid API key
    func hasValidLLMProvider() -> Bool {
        switch config.notes.llm.provider {
        case "openai":
            return !config.notes.llm.openai.apiKey.isEmpty
        case "anthropic":
            return !config.notes.llm.anthropic.apiKey.isEmpty
        case "ollama":
            return !config.notes.llm.ollama.endpoint.isEmpty
        default:
            return false
        }
    }
    
    /// Get the currently active LLM provider configuration
    func getActiveLLMProvider() -> (name: String, hasKey: Bool) {
        let provider = config.notes.llm.provider
        let hasKey: Bool
        
        switch provider {
        case "openai":
            hasKey = !config.notes.llm.openai.apiKey.isEmpty
        case "anthropic":
            hasKey = !config.notes.llm.anthropic.apiKey.isEmpty
        case "ollama":
            hasKey = !config.notes.llm.ollama.endpoint.isEmpty
        default:
            hasKey = false
        }
        
        return (provider, hasKey)
    }
}

// MARK: - GlossaryEntry Extensions for Phonetic Matching

extension AppConfiguration.Transcription.GlossaryEntry {
    
    /// Format entry for prompt injection (matches Swift implementation in TranscriptPostProcessor)
    func formatForPrompt() -> String {
        var parts: [String] = []
        if let pronunciation = pronunciation, !pronunciation.isEmpty {
            parts.append("pronunciation: \(pronunciation)")
        }
        if let context = context, !context.isEmpty {
            parts.append("context: \(context)")
        }
        if let aliases = aliases, !aliases.isEmpty {
            parts.append("aliases: \(aliases.joined(separator: ", "))")
        }
        
        if parts.isEmpty {
            return term
        } else {
            return "\(term) (\(parts.joined(separator: "; ")))"
        }
    }
    
    /// Estimated token count for this entry when formatted for prompt
    /// Uses chars/4 approximation - conservative enough given 4x headroom (2K vs 8K context)
    var estimatedTokenCount: Int {
        return max(1, formatForPrompt().count / 4)
    }
    
    /// All searchable variants: term + aliases (lowercased for matching)
    var searchableVariants: [String] {
        var variants = [term.lowercased()]
        if let aliases = aliases {
            variants.append(contentsOf: aliases.map { $0.lowercased() })
        }
        return variants
    }
    
    /// First word of the term (for multi-word phonetic matching)
    var firstWord: String {
        return term.split(separator: " ").first.map(String.init) ?? term
    }
}
