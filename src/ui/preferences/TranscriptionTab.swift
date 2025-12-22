import AppKit

class TranscriptionTab: BasePreferencesTab {
    override var tabName: String { "Transcription" }
    
    // Provider selection
    private var localRadio: NSButton!
    private var openaiRadio: NSButton!
    
    // Local provider fields
    private var localContainer: NSView!
    private var whisperBinaryField: NSTextField!
    private var modelPathField: NSTextField!
    
    // OpenAI provider fields
    private var openaiContainer: NSView!
    private var openaiApiKeyField: NSTextField!
    private var openaiModelField: NSTextField!
    
    // Diarization (collapsible)
    private var diarizationCheckbox: NSButton!
    private var diarizationContainer: NSView!
    private var hfTokenField: NSTextField!
    private var pythonPathField: NSTextField!
    private var scriptPathField: NSTextField!
    private var whisperModelPopup: NSPopUpButton!
    private var minSpeakersField: NSTextField!
    private var maxSpeakersField: NSTextField!
    private var distanceThresholdField: NSTextField!
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    private func setupUI() {
        var yPos = 380
        
        // Title
        let titleLabel = NSTextField(labelWithString: "Transcription Provider")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.frame = NSRect(x: 20, y: yPos, width: 560, height: 20)
        addSubview(titleLabel)
        yPos -= 30
        
        // Radio buttons
        localRadio = NSButton(radioButtonWithTitle: "Local (whisper.cpp)", target: self, action: #selector(providerChanged))
        localRadio.frame = NSRect(x: 20, y: yPos, width: 200, height: 20)
        addSubview(localRadio)
        
        openaiRadio = NSButton(radioButtonWithTitle: "OpenAI", target: self, action: #selector(providerChanged))
        openaiRadio.frame = NSRect(x: 230, y: yPos, width: 150, height: 20)
        addSubview(openaiRadio)
        yPos -= 35
        
        // Local provider container
        localContainer = NSView(frame: NSRect(x: 20, y: yPos - 70, width: 560, height: 70))
        addSubview(localContainer)
        setupLocalFields()
        
        // OpenAI provider container
        openaiContainer = NSView(frame: NSRect(x: 20, y: yPos - 70, width: 560, height: 70))
        openaiContainer.isHidden = true
        addSubview(openaiContainer)
        setupOpenAIFields()
        
        yPos -= 85
        
        // Diarization section
        let separator = NSBox(frame: NSRect(x: 20, y: yPos, width: 560, height: 1))
        separator.boxType = .separator
        addSubview(separator)
        yPos -= 25
        
        diarizationCheckbox = NSButton(checkboxWithTitle: "Enable Diarization (Speaker Detection)", target: self, action: #selector(diarizationToggled))
        diarizationCheckbox.frame = NSRect(x: 20, y: yPos, width: 300, height: 20)
        addSubview(diarizationCheckbox)
        yPos -= 30
        
        // Diarization container (collapsible)
        diarizationContainer = NSView(frame: NSRect(x: 20, y: 20, width: 560, height: yPos - 20))
        diarizationContainer.isHidden = true
        addSubview(diarizationContainer)
        setupDiarizationFields()
    }
    
    private func setupLocalFields() {
        var yPos = 45
        
        let binaryLabel = NSTextField(labelWithString: "Whisper Binary:")
        binaryLabel.frame = NSRect(x: 0, y: yPos, width: 120, height: 20)
        binaryLabel.alignment = .right
        localContainer.addSubview(binaryLabel)
        
        whisperBinaryField = NSTextField(frame: NSRect(x: 130, y: yPos, width: 350, height: 22))
        whisperBinaryField.placeholderString = "/path/to/whisper"
        whisperBinaryField.target = self
        whisperBinaryField.action = #selector(fieldChanged)
        localContainer.addSubview(whisperBinaryField)
        yPos -= 30
        
        let modelLabel = NSTextField(labelWithString: "Model Path:")
        modelLabel.frame = NSRect(x: 0, y: yPos, width: 120, height: 20)
        modelLabel.alignment = .right
        localContainer.addSubview(modelLabel)
        
        modelPathField = NSTextField(frame: NSRect(x: 130, y: yPos, width: 350, height: 22))
        modelPathField.placeholderString = "/path/to/model.bin"
        modelPathField.target = self
        modelPathField.action = #selector(fieldChanged)
        localContainer.addSubview(modelPathField)
    }
    
    private func setupOpenAIFields() {
        var yPos = 45
        
        let apiKeyLabel = NSTextField(labelWithString: "API Key:")
        apiKeyLabel.frame = NSRect(x: 0, y: yPos, width: 120, height: 20)
        apiKeyLabel.alignment = .right
        openaiContainer.addSubview(apiKeyLabel)
        
        openaiApiKeyField = NSTextField(frame: NSRect(x: 130, y: yPos, width: 350, height: 22))
        openaiApiKeyField.placeholderString = "sk-..."
        openaiApiKeyField.target = self
        openaiApiKeyField.action = #selector(fieldChanged)
        openaiContainer.addSubview(openaiApiKeyField)
        yPos -= 30
        
        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.frame = NSRect(x: 0, y: yPos, width: 120, height: 20)
        modelLabel.alignment = .right
        openaiContainer.addSubview(modelLabel)
        
        openaiModelField = NSTextField(frame: NSRect(x: 130, y: yPos, width: 200, height: 22))
        openaiModelField.placeholderString = "whisper-1"
        openaiModelField.target = self
        openaiModelField.action = #selector(fieldChanged)
        openaiContainer.addSubview(openaiModelField)
    }
    
    private func setupDiarizationFields() {
        var yPos = 145
        
        // HF Token
        let hfLabel = NSTextField(labelWithString: "HuggingFace Token:")
        hfLabel.frame = NSRect(x: 0, y: yPos, width: 140, height: 20)
        hfLabel.alignment = .right
        diarizationContainer.addSubview(hfLabel)
        
        hfTokenField = NSTextField(frame: NSRect(x: 150, y: yPos, width: 350, height: 22))
        hfTokenField.placeholderString = "Optional (for some models)"
        hfTokenField.target = self
        hfTokenField.action = #selector(fieldChanged)
        diarizationContainer.addSubview(hfTokenField)
        yPos -= 30
        
        // Python Path
        let pythonLabel = NSTextField(labelWithString: "Python Path:")
        pythonLabel.frame = NSRect(x: 0, y: yPos, width: 140, height: 20)
        pythonLabel.alignment = .right
        diarizationContainer.addSubview(pythonLabel)
        
        pythonPathField = NSTextField(frame: NSRect(x: 150, y: yPos, width: 200, height: 22))
        pythonPathField.placeholderString = "python3"
        pythonPathField.target = self
        pythonPathField.action = #selector(fieldChanged)
        diarizationContainer.addSubview(pythonPathField)
        yPos -= 30
        
        // Script Path
        let scriptLabel = NSTextField(labelWithString: "Script Path:")
        scriptLabel.frame = NSRect(x: 0, y: yPos, width: 140, height: 20)
        scriptLabel.alignment = .right
        diarizationContainer.addSubview(scriptLabel)
        
        scriptPathField = NSTextField(frame: NSRect(x: 150, y: yPos, width: 350, height: 22))
        scriptPathField.target = self
        scriptPathField.action = #selector(fieldChanged)
        diarizationContainer.addSubview(scriptPathField)
        yPos -= 30
        
        // Whisper Model
        let whisperModelLabel = NSTextField(labelWithString: "Whisper Model:")
        whisperModelLabel.frame = NSRect(x: 0, y: yPos, width: 140, height: 20)
        whisperModelLabel.alignment = .right
        diarizationContainer.addSubview(whisperModelLabel)
        
        whisperModelPopup = NSPopUpButton(frame: NSRect(x: 150, y: yPos - 2, width: 120, height: 25), pullsDown: false)
        whisperModelPopup.addItems(withTitles: ["tiny", "base", "small", "medium", "large"])
        whisperModelPopup.target = self
        whisperModelPopup.action = #selector(fieldChanged)
        diarizationContainer.addSubview(whisperModelPopup)
        yPos -= 30
        
        // Min/Max Speakers
        let speakersLabel = NSTextField(labelWithString: "Speakers (min-max):")
        speakersLabel.frame = NSRect(x: 0, y: yPos, width: 140, height: 20)
        speakersLabel.alignment = .right
        diarizationContainer.addSubview(speakersLabel)
        
        minSpeakersField = NSTextField(frame: NSRect(x: 150, y: yPos, width: 50, height: 22))
        minSpeakersField.placeholderString = "1"
        minSpeakersField.target = self
        minSpeakersField.action = #selector(fieldChanged)
        diarizationContainer.addSubview(minSpeakersField)
        
        let dashLabel = NSTextField(labelWithString: "to")
        dashLabel.frame = NSRect(x: 210, y: yPos, width: 20, height: 20)
        diarizationContainer.addSubview(dashLabel)
        
        maxSpeakersField = NSTextField(frame: NSRect(x: 240, y: yPos, width: 50, height: 22))
        maxSpeakersField.placeholderString = "10"
        maxSpeakersField.target = self
        maxSpeakersField.action = #selector(fieldChanged)
        diarizationContainer.addSubview(maxSpeakersField)
        yPos -= 30
        
        // Distance Threshold
        let thresholdLabel = NSTextField(labelWithString: "Distance Threshold:")
        thresholdLabel.frame = NSRect(x: 0, y: yPos, width: 140, height: 20)
        thresholdLabel.alignment = .right
        diarizationContainer.addSubview(thresholdLabel)
        
        distanceThresholdField = NSTextField(frame: NSRect(x: 150, y: yPos, width: 80, height: 22))
        distanceThresholdField.placeholderString = "0.90"
        distanceThresholdField.target = self
        distanceThresholdField.action = #selector(fieldChanged)
        diarizationContainer.addSubview(distanceThresholdField)
        
        let thresholdHelp = NSTextField(labelWithString: "(0.85-0.95)")
        thresholdHelp.font = NSFont.systemFont(ofSize: 10)
        thresholdHelp.textColor = .secondaryLabelColor
        thresholdHelp.frame = NSRect(x: 240, y: yPos + 2, width: 100, height: 20)
        diarizationContainer.addSubview(thresholdHelp)
    }
    
    @objc private func providerChanged() {
        localContainer.isHidden = (openaiRadio.state == .on)
        openaiContainer.isHidden = (localRadio.state == .on)
        markDirty()
    }
    
    @objc private func diarizationToggled() {
        diarizationContainer.isHidden = (diarizationCheckbox.state == .off)
        markDirty()
    }
    
    @objc private func fieldChanged() {
        markDirty()
    }
    
    override func loadConfig(_ config: AppConfiguration) {
        // Provider
        if config.transcription.provider == "local" {
            localRadio.state = .on
            openaiRadio.state = .off
        } else {
            localRadio.state = .off
            openaiRadio.state = .on
        }
        providerChanged()
        
        // Local fields
        whisperBinaryField.stringValue = config.transcription.local.whisperBinaryPath
        modelPathField.stringValue = config.transcription.local.modelPath
        
        // OpenAI fields
        openaiApiKeyField.stringValue = config.transcription.openai.apiKey
        openaiModelField.stringValue = config.transcription.openai.model
        
        // Diarization
        diarizationCheckbox.state = config.transcription.diarization.enabled ? .on : .off
        hfTokenField.stringValue = config.transcription.diarization.hfToken
        pythonPathField.stringValue = config.transcription.diarization.pythonPath
        scriptPathField.stringValue = config.transcription.diarization.scriptPath
        whisperModelPopup.selectItem(withTitle: config.transcription.diarization.whisperModel)
        minSpeakersField.stringValue = config.transcription.diarization.minSpeakers.map(String.init) ?? ""
        maxSpeakersField.stringValue = config.transcription.diarization.maxSpeakers.map(String.init) ?? ""
        distanceThresholdField.stringValue = String(format: "%.2f", config.transcription.diarization.distanceThreshold)
        diarizationToggled()
        
        resetDirtyState()
    }
    
    override func validate() -> [ValidationError] {
        // Validation handled by ConfigValidator
        return []
    }
    
    override func collectChanges(into config: inout AppConfiguration) {
        // Provider
        config.transcription.provider = (localRadio.state == .on) ? "local" : "openai"
        
        // Local
        config.transcription.local.whisperBinaryPath = whisperBinaryField.stringValue
        config.transcription.local.modelPath = modelPathField.stringValue
        
        // OpenAI
        config.transcription.openai.apiKey = openaiApiKeyField.stringValue
        config.transcription.openai.model = openaiModelField.stringValue
        
        // Diarization
        config.transcription.diarization.enabled = (diarizationCheckbox.state == .on)
        config.transcription.diarization.hfToken = hfTokenField.stringValue
        config.transcription.diarization.pythonPath = pythonPathField.stringValue
        config.transcription.diarization.scriptPath = scriptPathField.stringValue
        config.transcription.diarization.whisperModel = whisperModelPopup.titleOfSelectedItem ?? "base"
        config.transcription.diarization.minSpeakers = Int(minSpeakersField.stringValue)
        config.transcription.diarization.maxSpeakers = Int(maxSpeakersField.stringValue)
        config.transcription.diarization.distanceThreshold = Double(distanceThresholdField.stringValue) ?? 0.90
    }
}
