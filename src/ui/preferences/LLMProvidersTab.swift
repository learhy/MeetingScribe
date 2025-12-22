import AppKit

class LLMProvidersTab: BasePreferencesTab {
    override var tabName: String { "LLM Providers" }
    
    // System prompt
    private var systemPromptField: NSTextField!
    private var browsePromptButton: NSButton!
    
    // Provider selection
    private var anthropicRadio: NSButton!
    private var openaiRadio: NSButton!
    private var ollamaRadio: NSButton!
    
    // Provider containers
    private var anthropicContainer: NSView!
    private var openaiContainer: NSView!
    private var ollamaContainer: NSView!
    
    // Anthropic fields
    private var anthropicApiKeyField: NSTextField!
    private var anthropicModelPopup: NSPopUpButton!
    private var anthropicTestButton: NSButton!
    
    // OpenAI fields
    private var openaiApiKeyField: NSTextField!
    private var openaiModelPopup: NSPopUpButton!
    private var openaiTestButton: NSButton!
    
    // Ollama fields
    private var ollamaEndpointField: NSTextField!
    private var ollamaModelField: NSTextField!
    private var ollamaTestButton: NSButton!
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    private func setupUI() {
        var yPos = 380
        
        // System prompt file
        let promptLabel = NSTextField(labelWithString: "System Prompt File:")
        promptLabel.frame = NSRect(x: 20, y: yPos, width: 120, height: 20)
        promptLabel.alignment = .right
        addSubview(promptLabel)
        
        systemPromptField = NSTextField(frame: NSRect(x: 150, y: yPos, width: 320, height: 22))
        systemPromptField.target = self
        systemPromptField.action = #selector(fieldChanged)
        addSubview(systemPromptField)
        
        browsePromptButton = NSButton(title: "Browse...", target: self, action: #selector(browsePrompt))
        browsePromptButton.frame = NSRect(x: 480, y: yPos - 2, width: 90, height: 25)
        browsePromptButton.bezelStyle = .rounded
        addSubview(browsePromptButton)
        yPos -= 40
        
        // Separator
        let separator = NSBox(frame: NSRect(x: 20, y: yPos, width: 560, height: 1))
        separator.boxType = .separator
        addSubview(separator)
        yPos -= 25
        
        // Provider title
        let providerTitle = NSTextField(labelWithString: "LLM Provider")
        providerTitle.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        providerTitle.frame = NSRect(x: 20, y: yPos, width: 560, height: 20)
        addSubview(providerTitle)
        yPos -= 30
        
        // Radio buttons
        anthropicRadio = NSButton(radioButtonWithTitle: "Anthropic (Claude)", target: self, action: #selector(providerChanged))
        anthropicRadio.frame = NSRect(x: 20, y: yPos, width: 180, height: 20)
        addSubview(anthropicRadio)
        
        openaiRadio = NSButton(radioButtonWithTitle: "OpenAI", target: self, action: #selector(providerChanged))
        openaiRadio.frame = NSRect(x: 210, y: yPos, width: 100, height: 20)
        addSubview(openaiRadio)
        
        ollamaRadio = NSButton(radioButtonWithTitle: "Ollama (Local)", target: self, action: #selector(providerChanged))
        ollamaRadio.frame = NSRect(x: 320, y: yPos, width: 150, height: 20)
        addSubview(ollamaRadio)
        yPos -= 35
        
        // Provider containers
        anthropicContainer = NSView(frame: NSRect(x: 20, y: yPos - 100, width: 560, height: 100))
        addSubview(anthropicContainer)
        setupAnthropicFields()
        
        openaiContainer = NSView(frame: NSRect(x: 20, y: yPos - 100, width: 560, height: 100))
        openaiContainer.isHidden = true
        addSubview(openaiContainer)
        setupOpenAIFields()
        
        ollamaContainer = NSView(frame: NSRect(x: 20, y: yPos - 100, width: 560, height: 100))
        ollamaContainer.isHidden = true
        addSubview(ollamaContainer)
        setupOllamaFields()
    }
    
    private func setupAnthropicFields() {
        var yPos = 75
        
        let apiKeyLabel = NSTextField(labelWithString: "API Key:")
        apiKeyLabel.frame = NSRect(x: 0, y: yPos, width: 80, height: 20)
        apiKeyLabel.alignment = .right
        anthropicContainer.addSubview(apiKeyLabel)
        
        anthropicApiKeyField = NSTextField(frame: NSRect(x: 90, y: yPos, width: 380, height: 22))
        anthropicApiKeyField.placeholderString = "sk-ant-..."
        anthropicApiKeyField.target = self
        anthropicApiKeyField.action = #selector(fieldChanged)
        anthropicContainer.addSubview(anthropicApiKeyField)
        yPos -= 35
        
        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.frame = NSRect(x: 0, y: yPos, width: 80, height: 20)
        modelLabel.alignment = .right
        anthropicContainer.addSubview(modelLabel)
        
        anthropicModelPopup = NSPopUpButton(frame: NSRect(x: 90, y: yPos - 2, width: 250, height: 25), pullsDown: false)
        anthropicModelPopup.addItems(withTitles: [
            "claude-3-5-sonnet-20241022",
            "claude-3-5-haiku-20241022",
            "claude-3-opus-20240229",
            "claude-3-sonnet-20240229",
            "claude-3-haiku-20240307"
        ])
        anthropicModelPopup.target = self
        anthropicModelPopup.action = #selector(fieldChanged)
        anthropicContainer.addSubview(anthropicModelPopup)
        
        anthropicTestButton = NSButton(title: "Test API", target: self, action: #selector(testAnthropic))
        anthropicTestButton.frame = NSRect(x: 350, y: yPos - 2, width: 90, height: 25)
        anthropicTestButton.bezelStyle = .rounded
        anthropicContainer.addSubview(anthropicTestButton)
    }
    
    private func setupOpenAIFields() {
        var yPos = 75
        
        let apiKeyLabel = NSTextField(labelWithString: "API Key:")
        apiKeyLabel.frame = NSRect(x: 0, y: yPos, width: 80, height: 20)
        apiKeyLabel.alignment = .right
        openaiContainer.addSubview(apiKeyLabel)
        
        openaiApiKeyField = NSTextField(frame: NSRect(x: 90, y: yPos, width: 380, height: 22))
        openaiApiKeyField.placeholderString = "sk-..."
        openaiApiKeyField.target = self
        openaiApiKeyField.action = #selector(fieldChanged)
        openaiContainer.addSubview(openaiApiKeyField)
        yPos -= 35
        
        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.frame = NSRect(x: 0, y: yPos, width: 80, height: 20)
        modelLabel.alignment = .right
        openaiContainer.addSubview(modelLabel)
        
        openaiModelPopup = NSPopUpButton(frame: NSRect(x: 90, y: yPos - 2, width: 250, height: 25), pullsDown: false)
        openaiModelPopup.addItems(withTitles: [
            "gpt-4o",
            "gpt-4o-mini",
            "gpt-4-turbo",
            "gpt-4",
            "gpt-3.5-turbo"
        ])
        openaiModelPopup.target = self
        openaiModelPopup.action = #selector(fieldChanged)
        openaiContainer.addSubview(openaiModelPopup)
        
        openaiTestButton = NSButton(title: "Test API", target: self, action: #selector(testOpenAI))
        openaiTestButton.frame = NSRect(x: 350, y: yPos - 2, width: 90, height: 25)
        openaiTestButton.bezelStyle = .rounded
        openaiContainer.addSubview(openaiTestButton)
    }
    
    private func setupOllamaFields() {
        var yPos = 75
        
        let endpointLabel = NSTextField(labelWithString: "Endpoint:")
        endpointLabel.frame = NSRect(x: 0, y: yPos, width: 80, height: 20)
        endpointLabel.alignment = .right
        ollamaContainer.addSubview(endpointLabel)
        
        ollamaEndpointField = NSTextField(frame: NSRect(x: 90, y: yPos, width: 380, height: 22))
        ollamaEndpointField.placeholderString = "http://localhost:11434"
        ollamaEndpointField.target = self
        ollamaEndpointField.action = #selector(fieldChanged)
        ollamaContainer.addSubview(ollamaEndpointField)
        yPos -= 35
        
        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.frame = NSRect(x: 0, y: yPos, width: 80, height: 20)
        modelLabel.alignment = .right
        ollamaContainer.addSubview(modelLabel)
        
        ollamaModelField = NSTextField(frame: NSRect(x: 90, y: yPos, width: 250, height: 22))
        ollamaModelField.placeholderString = "llama3.2, mistral, etc."
        ollamaModelField.target = self
        ollamaModelField.action = #selector(fieldChanged)
        ollamaContainer.addSubview(ollamaModelField)
        
        ollamaTestButton = NSButton(title: "Test API", target: self, action: #selector(testOllama))
        ollamaTestButton.frame = NSRect(x: 350, y: yPos - 2, width: 90, height: 25)
        ollamaTestButton.bezelStyle = .rounded
        ollamaContainer.addSubview(ollamaTestButton)
    }
    
    @objc private func providerChanged() {
        anthropicContainer.isHidden = (anthropicRadio.state != .on)
        openaiContainer.isHidden = (openaiRadio.state != .on)
        ollamaContainer.isHidden = (ollamaRadio.state != .on)
        markDirty()
    }
    
    @objc private func fieldChanged() {
        markDirty()
    }
    
    @objc private func browsePrompt() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.text, .plainText]
        panel.message = "Select system prompt file"
        
        if let window = self.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url {
                    self?.systemPromptField.stringValue = url.path
                    self?.markDirty()
                }
            }
        }
    }
    
    @objc private func testAnthropic() {
        showTestResult(message: "Testing Anthropic API connection...")
        // TODO: Implement actual API test
    }
    
    @objc private func testOpenAI() {
        showTestResult(message: "Testing OpenAI API connection...")
        // TODO: Implement actual API test
    }
    
    @objc private func testOllama() {
        showTestResult(message: "Testing Ollama connection...")
        // TODO: Implement actual API test
    }
    
    private func showTestResult(message: String) {
        let alert = NSAlert()
        alert.messageText = "API Test"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = self.window {
            alert.beginSheetModal(for: window)
        }
    }
    
    override func loadConfig(_ config: AppConfiguration) {
        systemPromptField.stringValue = config.notes.llm.systemPromptFile
        
        // Provider selection
        switch config.notes.llm.provider {
        case "anthropic":
            anthropicRadio.state = .on
            openaiRadio.state = .off
            ollamaRadio.state = .off
        case "openai":
            anthropicRadio.state = .off
            openaiRadio.state = .on
            ollamaRadio.state = .off
        case "ollama":
            anthropicRadio.state = .off
            openaiRadio.state = .off
            ollamaRadio.state = .on
        default:
            anthropicRadio.state = .on
            openaiRadio.state = .off
            ollamaRadio.state = .off
        }
        providerChanged()
        
        // Anthropic
        anthropicApiKeyField.stringValue = config.notes.llm.anthropic.apiKey
        anthropicModelPopup.selectItem(withTitle: config.notes.llm.anthropic.model)
        
        // OpenAI
        openaiApiKeyField.stringValue = config.notes.llm.openai.apiKey
        openaiModelPopup.selectItem(withTitle: config.notes.llm.openai.model)
        
        // Ollama
        ollamaEndpointField.stringValue = config.notes.llm.ollama.endpoint
        ollamaModelField.stringValue = config.notes.llm.ollama.model
        
        resetDirtyState()
    }
    
    override func validate() -> [ValidationError] {
        // Validation handled by ConfigValidator
        return []
    }
    
    override func collectChanges(into config: inout AppConfiguration) {
        config.notes.llm.systemPromptFile = systemPromptField.stringValue
        
        // Provider
        if anthropicRadio.state == .on {
            config.notes.llm.provider = "anthropic"
        } else if openaiRadio.state == .on {
            config.notes.llm.provider = "openai"
        } else {
            config.notes.llm.provider = "ollama"
        }
        
        // Anthropic
        config.notes.llm.anthropic.apiKey = anthropicApiKeyField.stringValue
        config.notes.llm.anthropic.model = anthropicModelPopup.titleOfSelectedItem ?? "claude-3-5-sonnet-20241022"
        
        // OpenAI
        config.notes.llm.openai.apiKey = openaiApiKeyField.stringValue
        config.notes.llm.openai.model = openaiModelPopup.titleOfSelectedItem ?? "gpt-4o"
        
        // Ollama
        config.notes.llm.ollama.endpoint = ollamaEndpointField.stringValue
        config.notes.llm.ollama.model = ollamaModelField.stringValue
    }
}
