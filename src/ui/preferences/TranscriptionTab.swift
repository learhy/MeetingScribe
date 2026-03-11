import AppKit

// Helper class for flipped coordinate system (0,0 at top-left)
private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

class TranscriptionTab: BasePreferencesTab {
    override var tabName: String { "Transcription" }
    
    // Provider selection
    private var localRadio: NSButton!
    private var openaiRadio: NSButton!
    
    // Local provider fields
    private var localContainer: FlippedView!
    private var whisperBinaryField: NSTextField!
    private var whisperBrowseButton: NSButton!
    private var modelPathField: NSTextField!
    private var modelBrowseButton: NSButton!
    
    // OpenAI provider fields
    private var openaiContainer: FlippedView!
    private var openaiApiKeyField: NSTextField!
    private var openaiModelField: NSTextField!
    
    // Diarization (collapsible)
    private var diarizationCheckbox: NSButton!
    private var diarizationContainer: FlippedView!
    private var hfTokenField: NSTextField!
    private var pythonPathField: NSTextField!
    private var scriptPathField: NSTextField!
    private var whisperModelPopup: NSPopUpButton!
    private var minSpeakersField: NSTextField!
    private var maxSpeakersField: NSTextField!
    private var distanceThresholdField: NSTextField!
    private var vocabularyFileField: NSTextField!
    private var initialPromptField: NSTextField!
    
    // Post-processing
    private var postProcessingCheckbox: NSButton!
    private var postProcessingSeparator: NSBox!
    private var postProcessingHelp: NSTextField!
    
    // Content view inside scroll view
    private var contentView: FlippedView!
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    private func setupUI() {
        // Create a scroll view to contain all content
        let scrollView = NSScrollView(frame: bounds)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        
        // Content view with enough height for all elements
        // Use FlippedView so coordinates start from top (0,0 at top-left)
        // Calculate total needed height: title(20) + spacing(30) + radio(20) + spacing(35) + 
        // provider fields(70) + spacing(15) + separator(1) + spacing(25) + diarization checkbox(20) +
        // diarization fields(240) + spacing(25) + separator(1) + spacing(25) + post-processing(60)
        let contentHeight: CGFloat = 587
        contentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 600, height: contentHeight))
        scrollView.documentView = contentView
        
        var yPos: CGFloat = 20  // Start from top with 20px padding
        
        // Title
        let titleLabel = NSTextField(labelWithString: "Transcription Provider")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.frame = NSRect(x: 20, y: yPos, width: 560, height: 20)
        contentView.addSubview(titleLabel)
        yPos += 30
        
        // Radio buttons
        localRadio = NSButton(radioButtonWithTitle: "Local (whisper.cpp)", target: self, action: #selector(providerChanged))
        localRadio.frame = NSRect(x: 20, y: yPos, width: 200, height: 20)
        contentView.addSubview(localRadio)
        
        openaiRadio = NSButton(radioButtonWithTitle: "OpenAI", target: self, action: #selector(providerChanged))
        openaiRadio.frame = NSRect(x: 230, y: yPos, width: 150, height: 20)
        contentView.addSubview(openaiRadio)
        yPos += 35
        
        // Local provider container
        localContainer = FlippedView(frame: NSRect(x: 20, y: yPos, width: 560, height: 70))
        contentView.addSubview(localContainer)
        setupLocalFields()
        
        // OpenAI provider container
        openaiContainer = FlippedView(frame: NSRect(x: 20, y: yPos, width: 560, height: 70))
        openaiContainer.isHidden = true
        contentView.addSubview(openaiContainer)
        setupOpenAIFields()
        
        yPos += 85
        
        // Diarization section
        let separator = NSBox(frame: NSRect(x: 20, y: yPos, width: 560, height: 1))
        separator.boxType = .separator
        contentView.addSubview(separator)
        yPos += 25
        
        diarizationCheckbox = NSButton(checkboxWithTitle: "Enable Diarization (Speaker Detection)", target: self, action: #selector(diarizationToggled))
        diarizationCheckbox.frame = NSRect(x: 20, y: yPos, width: 360, height: 20)
        contentView.addSubview(diarizationCheckbox)
        yPos += 10
        
        // Diarization container (collapsible) - positioned below checkbox
        // Height is 240 to fit all diarization fields (8 rows × 30px)
        let diarizationHeight: CGFloat = 240
        diarizationContainer = FlippedView(frame: NSRect(x: 20, y: yPos, width: 560, height: diarizationHeight))
        diarizationContainer.isHidden = true
        contentView.addSubview(diarizationContainer)
        setupDiarizationFields()
        
        yPos += diarizationHeight + 25
        
        // Post-processing section - positioned dynamically below diarization
        postProcessingSeparator = NSBox(frame: NSRect(x: 20, y: yPos, width: 560, height: 1))
        postProcessingSeparator.boxType = .separator
        contentView.addSubview(postProcessingSeparator)
        yPos += 25
        
        postProcessingCheckbox = NSButton(checkboxWithTitle: "Enable LLM Post-Processing (correct transcription errors)", target: self, action: #selector(fieldChanged))
        postProcessingCheckbox.frame = NSRect(x: 20, y: yPos, width: 500, height: 20)
        contentView.addSubview(postProcessingCheckbox)
        yPos += 20
        
        postProcessingHelp = NSTextField(labelWithString: "Uses configured LLM to fix misheard names, terms, and words")
        postProcessingHelp.font = NSFont.systemFont(ofSize: 10)
        postProcessingHelp.textColor = .secondaryLabelColor
        postProcessingHelp.frame = NSRect(x: 40, y: yPos, width: 520, height: 16)
        contentView.addSubview(postProcessingHelp)
    }
    
    private func setupLocalFields() {
        var yPos: CGFloat = 10
        
        let binaryLabel = NSTextField(labelWithString: "Whisper Binary:")
        binaryLabel.frame = NSRect(x: 0, y: yPos, width: 120, height: 20)
        binaryLabel.alignment = .right
        localContainer.addSubview(binaryLabel)
        
        whisperBinaryField = NSTextField(frame: NSRect(x: 130, y: yPos, width: 300, height: 22))
        whisperBinaryField.placeholderString = "/path/to/whisper"
        whisperBinaryField.target = self
        whisperBinaryField.action = #selector(fieldChanged)
        localContainer.addSubview(whisperBinaryField)
        
        whisperBrowseButton = NSButton(title: "Browse...", target: self, action: #selector(browseWhisper))
        whisperBrowseButton.frame = NSRect(x: 440, y: yPos - 2, width: 90, height: 25)
        whisperBrowseButton.bezelStyle = .rounded
        localContainer.addSubview(whisperBrowseButton)
        yPos += 30
        
        let modelLabel = NSTextField(labelWithString: "Model Path:")
        modelLabel.frame = NSRect(x: 0, y: yPos, width: 120, height: 20)
        modelLabel.alignment = .right
        localContainer.addSubview(modelLabel)
        
        modelPathField = NSTextField(frame: NSRect(x: 130, y: yPos, width: 300, height: 22))
        modelPathField.placeholderString = "/path/to/model.bin"
        modelPathField.target = self
        modelPathField.action = #selector(fieldChanged)
        localContainer.addSubview(modelPathField)
        
        modelBrowseButton = NSButton(title: "Browse...", target: self, action: #selector(browseModel))
        modelBrowseButton.frame = NSRect(x: 440, y: yPos - 2, width: 90, height: 25)
        modelBrowseButton.bezelStyle = .rounded
        localContainer.addSubview(modelBrowseButton)
    }
    
    private func setupOpenAIFields() {
        var yPos: CGFloat = 10
        
        let apiKeyLabel = NSTextField(labelWithString: "API Key:")
        apiKeyLabel.frame = NSRect(x: 0, y: yPos, width: 120, height: 20)
        apiKeyLabel.alignment = .right
        openaiContainer.addSubview(apiKeyLabel)
        
        openaiApiKeyField = NSTextField(frame: NSRect(x: 130, y: yPos, width: 350, height: 22))
        openaiApiKeyField.placeholderString = "sk-..."
        openaiApiKeyField.target = self
        openaiApiKeyField.action = #selector(fieldChanged)
        openaiContainer.addSubview(openaiApiKeyField)
        yPos += 30
        
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
        // Position fields from top of container (height=240)
        var yPos: CGFloat = 10
        
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
        yPos += 30
        
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
        yPos += 30
        
        // Script Path
        let scriptLabel = NSTextField(labelWithString: "Script Path:")
        scriptLabel.frame = NSRect(x: 0, y: yPos, width: 140, height: 20)
        scriptLabel.alignment = .right
        diarizationContainer.addSubview(scriptLabel)
        
        scriptPathField = NSTextField(frame: NSRect(x: 150, y: yPos, width: 350, height: 22))
        scriptPathField.target = self
        scriptPathField.action = #selector(fieldChanged)
        diarizationContainer.addSubview(scriptPathField)
        yPos += 30
        
        // Whisper Model
        let whisperModelLabel = NSTextField(labelWithString: "Whisper Model:")
        whisperModelLabel.frame = NSRect(x: 0, y: yPos, width: 140, height: 20)
        whisperModelLabel.alignment = .right
        diarizationContainer.addSubview(whisperModelLabel)
        
        whisperModelPopup = NSPopUpButton(frame: NSRect(x: 150, y: yPos - 2, width: 120, height: 25), pullsDown: false)
        whisperModelPopup.addItems(withTitles: ["tiny", "base", "small", "medium", "large", "turbo"])
        whisperModelPopup.target = self
        whisperModelPopup.action = #selector(fieldChanged)
        diarizationContainer.addSubview(whisperModelPopup)
        yPos += 30
        
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
        yPos += 30
        
        // Distance Threshold
        let thresholdLabel = NSTextField(labelWithString: "Distance Threshold:")
        thresholdLabel.frame = NSRect(x: 0, y: yPos, width: 140, height: 20)
        thresholdLabel.alignment = .right
        diarizationContainer.addSubview(thresholdLabel)
        
        distanceThresholdField = NSTextField(frame: NSRect(x: 150, y: yPos, width: 80, height: 22))
        distanceThresholdField.placeholderString = "0.25"
        distanceThresholdField.target = self
        distanceThresholdField.action = #selector(fieldChanged)
        diarizationContainer.addSubview(distanceThresholdField)
        
        let thresholdHelp = NSTextField(labelWithString: "(0.15-0.40)")
        thresholdHelp.font = NSFont.systemFont(ofSize: 10)
        thresholdHelp.textColor = .secondaryLabelColor
        thresholdHelp.frame = NSRect(x: 240, y: yPos + 2, width: 100, height: 20)
        diarizationContainer.addSubview(thresholdHelp)
        yPos += 30
        
        // Vocabulary File
        let vocabLabel = NSTextField(labelWithString: "Vocabulary File:")
        vocabLabel.frame = NSRect(x: 0, y: yPos, width: 140, height: 20)
        vocabLabel.alignment = .right
        diarizationContainer.addSubview(vocabLabel)
        
        vocabularyFileField = NSTextField(frame: NSRect(x: 150, y: yPos, width: 350, height: 22))
        vocabularyFileField.placeholderString = "Optional: ~/.meetingscribe/vocabulary.txt"
        vocabularyFileField.target = self
        vocabularyFileField.action = #selector(fieldChanged)
        diarizationContainer.addSubview(vocabularyFileField)
        yPos += 30
        
        // Initial Prompt
        let promptLabel = NSTextField(labelWithString: "Initial Prompt:")
        promptLabel.frame = NSRect(x: 0, y: yPos, width: 140, height: 20)
        promptLabel.alignment = .right
        diarizationContainer.addSubview(promptLabel)
        
        initialPromptField = NSTextField(frame: NSRect(x: 150, y: yPos, width: 350, height: 22))
        initialPromptField.placeholderString = "e.g., Glossary: QBR, MBR, GTM, Dan, Sanjay"
        initialPromptField.target = self
        initialPromptField.action = #selector(fieldChanged)
        diarizationContainer.addSubview(initialPromptField)
    }
    
    @objc private func providerChanged() {
        localContainer.isHidden = (openaiRadio.state == .on)
        openaiContainer.isHidden = (localRadio.state == .on)
        markDirty()
    }
    
    @objc private func diarizationToggled() {
        let isEnabled = (diarizationCheckbox.state == .on)
        diarizationContainer.isHidden = !isEnabled
        markDirty()
    }
    
    @objc private func fieldChanged() {
        markDirty()
    }
    
    @objc private func browseWhisper() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select whisper.cpp binary"
        let defaultDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".meetingscribe")
        if FileManager.default.fileExists(atPath: defaultDir.path) {
            panel.directoryURL = defaultDir
        }
        if let window = self.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url {
                    self?.whisperBinaryField.stringValue = url.path
                    self?.markDirty()
                }
            }
        }
    }
    
    @objc private func browseModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select model file"
        let defaultDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".meetingscribe")
        if FileManager.default.fileExists(atPath: defaultDir.path) {
            panel.directoryURL = defaultDir
        }
        if let window = self.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url {
                    self?.modelPathField.stringValue = url.path
                    self?.markDirty()
                }
            }
        }
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
        vocabularyFileField.stringValue = config.transcription.diarization.vocabularyFile
        initialPromptField.stringValue = config.transcription.diarization.initialPrompt
        diarizationToggled()
        
        // Post-processing
        postProcessingCheckbox.state = config.transcription.postProcessing.enabled ? .on : .off
        
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
        config.transcription.diarization.distanceThreshold = Double(distanceThresholdField.stringValue) ?? 0.25
        config.transcription.diarization.vocabularyFile = vocabularyFileField.stringValue
        config.transcription.diarization.initialPrompt = initialPromptField.stringValue
        
        // Post-processing
        config.transcription.postProcessing.enabled = (postProcessingCheckbox.state == .on)
    }
}
