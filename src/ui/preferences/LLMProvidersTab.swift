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
            "claude-opus-4-20250514",
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
        let apiKey = anthropicApiKeyField.stringValue
        let model = anthropicModelPopup.titleOfSelectedItem ?? "claude-3-5-sonnet-20241022"
        
        guard !apiKey.isEmpty else {
            showTestResult(success: false, message: "Please enter an API key first")
            return
        }
        
        // Disable button during test
        anthropicTestButton.isEnabled = false
        anthropicTestButton.title = "Testing..."
        
        Task {
            let result = await testAnthropicAPI(apiKey: apiKey, model: model)
            DispatchQueue.main.async { [weak self] in
                self?.anthropicTestButton.isEnabled = true
                self?.anthropicTestButton.title = "Test API"
                self?.showTestResult(success: result.success, message: result.message)
            }
        }
    }
    
    @objc private func testOpenAI() {
        let apiKey = openaiApiKeyField.stringValue
        let model = openaiModelPopup.titleOfSelectedItem ?? "gpt-4o"
        
        guard !apiKey.isEmpty else {
            showTestResult(success: false, message: "Please enter an API key first")
            return
        }
        
        // Disable button during test
        openaiTestButton.isEnabled = false
        openaiTestButton.title = "Testing..."
        
        Task {
            let result = await testOpenAIAPI(apiKey: apiKey, model: model)
            DispatchQueue.main.async { [weak self] in
                self?.openaiTestButton.isEnabled = true
                self?.openaiTestButton.title = "Test API"
                self?.showTestResult(success: result.success, message: result.message)
            }
        }
    }
    
    @objc private func testOllama() {
        let endpoint = ollamaEndpointField.stringValue
        let model = ollamaModelField.stringValue
        
        guard !endpoint.isEmpty else {
            showTestResult(success: false, message: "Please enter an endpoint URL first")
            return
        }
        
        guard !model.isEmpty else {
            showTestResult(success: false, message: "Please enter a model name first")
            return
        }
        
        // Disable button during test
        ollamaTestButton.isEnabled = false
        ollamaTestButton.title = "Testing..."
        
        Task {
            let result = await testOllamaAPI(endpoint: endpoint, model: model)
            DispatchQueue.main.async { [weak self] in
                self?.ollamaTestButton.isEnabled = true
                self?.ollamaTestButton.title = "Test API"
                self?.showTestResult(success: result.success, message: result.message)
            }
        }
    }
    
    private func showTestResult(success: Bool?, message: String) {
        let alert = NSAlert()
        
        if let success = success {
            alert.messageText = success ? "✅ API Test Successful" : "❌ API Test Failed"
            alert.alertStyle = success ? .informational : .warning
        } else {
            alert.messageText = "Testing API..."
            alert.alertStyle = .informational
        }
        
        alert.informativeText = message
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
    
    // MARK: - API Testing
    
    private func testAnthropicAPI(apiKey: String, model: String) async -> (success: Bool, message: String) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 10,
            "messages": [
                ["role": "user", "content": "test"]
            ]
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "Invalid response from server")
            }
            
            if httpResponse.statusCode == 200 {
                return (true, "Successfully connected to Anthropic API\nModel: \(model)")
            } else if httpResponse.statusCode == 401 {
                return (false, "Authentication failed\nPlease check your API key")
            } else if httpResponse.statusCode == 404 {
                return (false, "Model not found: \(model)\nPlease check the model name")
            } else {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    return (false, "Error \(httpResponse.statusCode): \(message)")
                }
                return (false, "HTTP error \(httpResponse.statusCode)")
            }
        } catch {
            return (false, "Network error: \(error.localizedDescription)")
        }
    }
    
    private func testOpenAIAPI(apiKey: String, model: String) async -> (success: Bool, message: String) {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 10,
            "messages": [
                ["role": "user", "content": "test"]
            ]
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "Invalid response from server")
            }
            
            if httpResponse.statusCode == 200 {
                return (true, "Successfully connected to OpenAI API\nModel: \(model)")
            } else if httpResponse.statusCode == 401 {
                return (false, "Authentication failed\nPlease check your API key")
            } else if httpResponse.statusCode == 404 {
                return (false, "Model not found: \(model)\nPlease check the model name")
            } else {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    return (false, "Error \(httpResponse.statusCode): \(message)")
                }
                return (false, "HTTP error \(httpResponse.statusCode)")
            }
        } catch {
            return (false, "Network error: \(error.localizedDescription)")
        }
    }
    
    private func testOllamaAPI(endpoint: String, model: String) async -> (success: Bool, message: String) {
        // First test if Ollama is running by checking /api/tags
        guard let baseURL = URL(string: endpoint) else {
            return (false, "Invalid endpoint URL")
        }
        
        let tagsURL = baseURL.appendingPathComponent("api/tags")
        
        do {
            let (data, response) = try await URLSession.shared.data(from: tagsURL)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return (false, "Invalid response from server")
            }
            
            if httpResponse.statusCode == 200 {
                // Check if model exists
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["models"] as? [[String: Any]] {
                    let modelNames = models.compactMap { $0["name"] as? String }
                    if modelNames.contains(where: { $0.starts(with: model) }) {
                        return (true, "Successfully connected to Ollama\nModel \(model) is available\nEndpoint: \(endpoint)")
                    } else {
                        let available = modelNames.prefix(5).joined(separator: ", ")
                        return (false, "Model '\(model)' not found on this Ollama instance\n\nAvailable models: \(available)\n\nRun: ollama pull \(model)")
                    }
                }
                return (true, "Successfully connected to Ollama\nEndpoint: \(endpoint)")
            } else {
                return (false, "HTTP error \(httpResponse.statusCode)\nIs Ollama running?")
            }
        } catch {
            return (false, "Could not connect to Ollama\n\(error.localizedDescription)\n\nMake sure Ollama is running:\n  ollama serve")
        }
    }
}
