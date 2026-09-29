import Foundation

// Type aliases for convenience and test compatibility
typealias GlossaryEntry = AppConfiguration.Transcription.GlossaryEntry
typealias Glossary = AppConfiguration.Transcription.Glossary

struct AppConfiguration: Codable {
    struct Detection: Codable {
        var pollInterval: Double = 2.0
        var debounceChecks: Int = 2
        var confidenceThreshold: Int = 85

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pollInterval = try container.decodeIfPresent(Double.self, forKey: .pollInterval) ?? 2.0
            debounceChecks = try container.decodeIfPresent(Int.self, forKey: .debounceChecks) ?? 2
            confidenceThreshold = try container.decodeIfPresent(Int.self, forKey: .confidenceThreshold) ?? 85
        }

        init() {}

        private enum CodingKeys: String, CodingKey {
            case pollInterval, debounceChecks, confidenceThreshold
        }
    }
    
    struct Audio: Codable {
        var outputDirectory: String = "~/Documents/MeetingScribe/recordings/"
        var sampleRate: Int = 48000
        var bitDepth: Int = 16
        var channels: Int = 2
        var mixMode: String = "mono_mixed"  // "stereo_separated" | "mono_mixed" — default mono to prevent stereo desync echo
        var microphoneEnabled: Bool = true  // Explicit mic toggle (ANDed with OS permission)
        var systemGain: Double = 1.0  // Per-channel volume for system audio
        var micGain: Double = 1.0  // Per-channel volume for microphone audio
        // P1-4: audio-quality guards + retention (Dan's Q1 decision: 30 days)
        var audioGuardsEnabled: Bool = true        // refuse <5 s / near-silent audio
        var audioRetentionDays: Int = 30           // 0 disables auto-deletion
        var telemetryEnabled: Bool = true          // log clipping/silence/SNR alongside transcripts

        // Custom decoder for backwards compatibility with existing config files
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            outputDirectory = try container.decodeIfPresent(String.self, forKey: .outputDirectory) ?? "~/Documents/MeetingScribe/recordings/"
            sampleRate = try container.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 48000
            bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth) ?? 16
            channels = try container.decodeIfPresent(Int.self, forKey: .channels) ?? 2
            mixMode = try container.decodeIfPresent(String.self, forKey: .mixMode) ?? "mono_mixed"
            microphoneEnabled = try container.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? true
            systemGain = try container.decodeIfPresent(Double.self, forKey: .systemGain) ?? 1.0
            micGain = try container.decodeIfPresent(Double.self, forKey: .micGain) ?? 1.0
            audioGuardsEnabled = try container.decodeIfPresent(Bool.self, forKey: .audioGuardsEnabled) ?? true
            audioRetentionDays = try container.decodeIfPresent(Int.self, forKey: .audioRetentionDays) ?? 30
            telemetryEnabled = try container.decodeIfPresent(Bool.self, forKey: .telemetryEnabled) ?? true
        }

        init() {}

        private enum CodingKeys: String, CodingKey {
            case outputDirectory, sampleRate, bitDepth, channels
            case mixMode, microphoneEnabled, systemGain, micGain
            case audioGuardsEnabled, audioRetentionDays, telemetryEnabled
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

        /// P2-1: AssemblyAI Universal-3 Pro config block (EVAL-ONLY — the
        /// default provider stays whisper-1+roster until the harness says
        /// otherwise; see docs/engine-swap.md).
        struct AssemblyAI: Codable {
            var apiKey: String = ""          // prefer Keychain (see SecretsManager note)
            var model: String = "universal-3-pro"
            var keytermsFromRoster: Bool = true  // map the RosterBuilder prompt to `keyterms`
            var extraKeyterms: [String] = []     // manual additions beyond the roster
            var pollIntervalSeconds: Double = 3.0
            var maxPollAttempts: Int = 600

            // Custom decoder for backwards compatibility with existing config files
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
                model = try container.decodeIfPresent(String.self, forKey: .model) ?? "universal-3-pro"
                keytermsFromRoster = try container.decodeIfPresent(Bool.self, forKey: .keytermsFromRoster) ?? true
                extraKeyterms = try container.decodeIfPresent([String].self, forKey: .extraKeyterms) ?? []
                pollIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .pollIntervalSeconds) ?? 3.0
                maxPollAttempts = try container.decodeIfPresent(Int.self, forKey: .maxPollAttempts) ?? 600
            }

            init() {}

            private enum CodingKeys: String, CodingKey {
                case apiKey, model, keytermsFromRoster, extraKeyterms
                case pollIntervalSeconds, maxPollAttempts
            }
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
            var initialPrompt: String = "Boundary, HashiCorp, Rachana, Aman, Sapta, Lauren, Mukesh, Yang Li, Krishnan, Abhijit, Anando, Katie Simmons, Pradeep, Jeff Mitchell, Jim Lambert, Mike Gaffney, Adam Bouhmad, Eric Haberkorn, PEDM, RDP, OIDC, OAuth, JWT, session recording, credential injection, agentic access control"  // Default glossary prompt for Whisper
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
        var assemblyai: AssemblyAI = AssemblyAI()
        var diarization: Diarization = Diarization()
        var postProcessing: PostProcessing = PostProcessing()
        var glossary: Glossary = Glossary()
        var smartPrompt: SmartPrompt = SmartPrompt()

        // Custom decoder for backwards compatibility with existing config files
        // (configs written before the assemblyai section existed must not fail
        // to decode — a failed decode makes ConfigManager save DEFAULTS over
        // the user's real config)
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "local"
            openai = try container.decodeIfPresent(OpenAI.self, forKey: .openai) ?? OpenAI()
            local = try container.decodeIfPresent(Local.self, forKey: .local) ?? Local()
            assemblyai = try container.decodeIfPresent(AssemblyAI.self, forKey: .assemblyai) ?? AssemblyAI()
            diarization = try container.decodeIfPresent(Diarization.self, forKey: .diarization) ?? Diarization()
            postProcessing = try container.decodeIfPresent(PostProcessing.self, forKey: .postProcessing) ?? PostProcessing()
            glossary = try container.decodeIfPresent(Glossary.self, forKey: .glossary) ?? Glossary()
            smartPrompt = try container.decodeIfPresent(SmartPrompt.self, forKey: .smartPrompt) ?? SmartPrompt()
        }

        init() {}

        private enum CodingKeys: String, CodingKey {
            case provider, openai, local, assemblyai, diarization, postProcessing, glossary, smartPrompt
        }
    }
    
    struct Notes: Codable {
        struct LLM: Codable {
            var provider: String = "anthropic"  // "openai" | "anthropic" | "ollama" | "nous"

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

            /// Nous Research inference portal (OpenAI-compatible).
            /// Auth: static `apiKey`, or an OAuth token file refreshed in place
            /// (keys: access_token, refresh_token, client_id, expires_at,
            ///  portal_base_url, inference_base_url).
            struct Nous: Codable {
                var apiKey: String = ""
                var model: String = "z-ai/glm-5.3-flash"
                var authTokenFile: String = ""

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
                    model = try container.decodeIfPresent(String.self, forKey: .model) ?? "z-ai/glm-5.3-flash"
                    authTokenFile = try container.decodeIfPresent(String.self, forKey: .authTokenFile) ?? ""
                }

                init() {}

                private enum CodingKeys: String, CodingKey {
                    case apiKey, model, authTokenFile
                }
            }

            var openai: OpenAI = OpenAI()
            var anthropic: Anthropic = Anthropic()
            var ollama: Ollama = Ollama()
            var nous: Nous = Nous()
            var systemPromptFile: String = "~/.meetingscribe/prompts/default.txt"

            // Custom decoder for backwards compatibility with existing config files
            // (configs written before a section existed must not fail to decode)
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "anthropic"
                openai = try container.decodeIfPresent(OpenAI.self, forKey: .openai) ?? OpenAI()
                anthropic = try container.decodeIfPresent(Anthropic.self, forKey: .anthropic) ?? Anthropic()
                ollama = try container.decodeIfPresent(Ollama.self, forKey: .ollama) ?? Ollama()
                nous = try container.decodeIfPresent(Nous.self, forKey: .nous) ?? Nous()
                systemPromptFile = try container.decodeIfPresent(String.self, forKey: .systemPromptFile) ?? "~/.meetingscribe/prompts/default.txt"
            }

            init() {}

            private enum CodingKeys: String, CodingKey {
                case provider, openai, anthropic, ollama, nous, systemPromptFile
            }
        }
        
        var llm: LLM = LLM()
        var templateFile: String = "~/.meetingscribe/templates/default.md"
        var backend: String = "bear"  // "bear" | "notion" | "obsidian"

        struct Bear: Codable {
            var tags: [String] = ["#meetings", "#teams"]
            var fallbackDirectory: String = "~/Documents/MeetingScribe/notes/"
        }

        var bear: Bear = Bear()

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            llm = try container.decodeIfPresent(LLM.self, forKey: .llm) ?? LLM()
            templateFile = try container.decodeIfPresent(String.self, forKey: .templateFile) ?? "~/.meetingscribe/templates/default.md"
            backend = try container.decodeIfPresent(String.self, forKey: .backend) ?? "bear"
            bear = try container.decodeIfPresent(Bear.self, forKey: .bear) ?? Bear()
        }

        init() {}

        private enum CodingKeys: String, CodingKey {
            case llm, templateFile, backend, bear
        }
    }
    
    struct UI: Codable {
        var showNotifications: Bool = true
        var notifyOnStart: Bool = true
        var notifyOnEnd: Bool = true
        var autoRecordingEnabled: Bool = true

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            showNotifications = try container.decodeIfPresent(Bool.self, forKey: .showNotifications) ?? true
            notifyOnStart = try container.decodeIfPresent(Bool.self, forKey: .notifyOnStart) ?? true
            notifyOnEnd = try container.decodeIfPresent(Bool.self, forKey: .notifyOnEnd) ?? true
            autoRecordingEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoRecordingEnabled) ?? true
        }

        init() {}

        private enum CodingKeys: String, CodingKey {
            case showNotifications, notifyOnStart, notifyOnEnd, autoRecordingEnabled
        }
    }

    struct Participants: Codable {
        var enabled: Bool = true
        var calendarSource: String = "eventkit"  // "eventkit" | "outlook" | "both"
        var eventKitCalendarName: String = "Calendar"
        var outlookDatabasePath: String = "~/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile/Data/"
        var debugLogging: Bool = false

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            calendarSource = try container.decodeIfPresent(String.self, forKey: .calendarSource) ?? "eventkit"
            eventKitCalendarName = try container.decodeIfPresent(String.self, forKey: .eventKitCalendarName) ?? "Calendar"
            outlookDatabasePath = try container.decodeIfPresent(String.self, forKey: .outlookDatabasePath) ?? "~/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile/Data/"
            debugLogging = try container.decodeIfPresent(Bool.self, forKey: .debugLogging) ?? false
        }

        init() {}

        private enum CodingKeys: String, CodingKey {
            case enabled, calendarSource, eventKitCalendarName, outlookDatabasePath, debugLogging
        }
    }

    var version: String = "1.0"
    var detection: Detection = Detection()
    var audio: Audio = Audio()
    var transcription: Transcription = Transcription()
    var notes: Notes = Notes()
    var ui: UI = UI()
    var participants: Participants = Participants()

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "1.0"
        detection = try container.decodeIfPresent(Detection.self, forKey: .detection) ?? Detection()
        audio = try container.decodeIfPresent(Audio.self, forKey: .audio) ?? Audio()
        transcription = try container.decodeIfPresent(Transcription.self, forKey: .transcription) ?? Transcription()
        notes = try container.decodeIfPresent(Notes.self, forKey: .notes) ?? Notes()
        ui = try container.decodeIfPresent(UI.self, forKey: .ui) ?? UI()
        participants = try container.decodeIfPresent(Participants.self, forKey: .participants) ?? Participants()
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, detection, audio, transcription, notes, ui, participants
    }
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
        case "nous":
            return !config.notes.llm.nous.apiKey.isEmpty || !config.notes.llm.nous.authTokenFile.isEmpty
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
        case "nous":
            hasKey = !config.notes.llm.nous.apiKey.isEmpty || !config.notes.llm.nous.authTokenFile.isEmpty
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
