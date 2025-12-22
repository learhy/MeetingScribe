import AppKit

class NotesTab: BasePreferencesTab {
    override var tabName: String { "Notes" }
    
    private var backendPopup: NSPopUpButton!
    private var tagsField: NSTextField!
    private var templatePathField: NSTextField!
    private var editTemplateButton: NSButton!
    private var fallbackDirectoryField: NSTextField!
    private var browseFallbackButton: NSButton!
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    private func setupUI() {
        var yPos = 380
        
        // Backend selection
        let backendLabel = NSTextField(labelWithString: "Notes Backend:")
        backendLabel.frame = NSRect(x: 20, y: yPos, width: 120, height: 20)
        backendLabel.alignment = .right
        addSubview(backendLabel)
        
        backendPopup = NSPopUpButton(frame: NSRect(x: 150, y: yPos - 2, width: 150, height: 25), pullsDown: false)
        backendPopup.addItems(withTitles: ["Bear"])
        backendPopup.target = self
        backendPopup.action = #selector(fieldChanged)
        addSubview(backendPopup)
        yPos -= 40
        
        // Tags (comma-separated)
        let tagsLabel = NSTextField(labelWithString: "Tags:")
        tagsLabel.frame = NSRect(x: 20, y: yPos, width: 120, height: 20)
        tagsLabel.alignment = .right
        addSubview(tagsLabel)
        
        tagsField = NSTextField(frame: NSRect(x: 150, y: yPos, width: 400, height: 22))
        tagsField.placeholderString = "meeting, transcription, ai"
        tagsField.target = self
        tagsField.action = #selector(fieldChanged)
        addSubview(tagsField)
        
        let tagsHelp = NSTextField(labelWithString: "Comma-separated tags to add to notes")
        tagsHelp.font = NSFont.systemFont(ofSize: 10)
        tagsHelp.textColor = .secondaryLabelColor
        tagsHelp.frame = NSRect(x: 150, y: yPos - 18, width: 400, height: 15)
        addSubview(tagsHelp)
        yPos -= 50
        
        // Template path
        let templateLabel = NSTextField(labelWithString: "Template File:")
        templateLabel.frame = NSRect(x: 20, y: yPos, width: 120, height: 20)
        templateLabel.alignment = .right
        addSubview(templateLabel)
        
        templatePathField = NSTextField(frame: NSRect(x: 150, y: yPos, width: 300, height: 22))
        templatePathField.isEditable = false
        templatePathField.isBordered = true
        templatePathField.backgroundColor = NSColor.controlBackgroundColor
        addSubview(templatePathField)
        
        editTemplateButton = NSButton(title: "Edit Template", target: self, action: #selector(editTemplate))
        editTemplateButton.frame = NSRect(x: 460, y: yPos - 2, width: 110, height: 25)
        editTemplateButton.bezelStyle = .rounded
        addSubview(editTemplateButton)
        yPos -= 50
        
        // Fallback directory
        let fallbackLabel = NSTextField(labelWithString: "Fallback Directory:")
        fallbackLabel.frame = NSRect(x: 20, y: yPos, width: 120, height: 20)
        fallbackLabel.alignment = .right
        addSubview(fallbackLabel)
        
        fallbackDirectoryField = NSTextField(frame: NSRect(x: 150, y: yPos, width: 300, height: 22))
        fallbackDirectoryField.placeholderString = "~/Documents/MeetingScribe"
        fallbackDirectoryField.target = self
        fallbackDirectoryField.action = #selector(fieldChanged)
        addSubview(fallbackDirectoryField)
        
        browseFallbackButton = NSButton(title: "Browse...", target: self, action: #selector(browseFallback))
        browseFallbackButton.frame = NSRect(x: 460, y: yPos - 2, width: 90, height: 25)
        browseFallbackButton.bezelStyle = .rounded
        addSubview(browseFallbackButton)
        
        let fallbackHelp = NSTextField(labelWithString: "Used when Bear is not available")
        fallbackHelp.font = NSFont.systemFont(ofSize: 10)
        fallbackHelp.textColor = .secondaryLabelColor
        fallbackHelp.frame = NSRect(x: 150, y: yPos - 18, width: 400, height: 15)
        addSubview(fallbackHelp)
    }
    
    @objc private func fieldChanged() {
        markDirty()
    }
    
    @objc private func editTemplate() {
        // Open template editor tab
        if let window = self.window {
            if let prefWindow = window.windowController as? PreferencesWindowController {
                prefWindow.selectTab(named: "Template Editor")
            }
        }
    }
    
    @objc private func browseFallback() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select fallback directory for notes"
        
        if let window = self.window {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url {
                    self?.fallbackDirectoryField.stringValue = url.path
                    self?.markDirty()
                }
            }
        }
    }
    
    override func loadConfig(_ config: AppConfiguration) {
        backendPopup.selectItem(withTitle: config.notes.backend)
        tagsField.stringValue = config.notes.bear.tags.joined(separator: ", ")
        templatePathField.stringValue = config.notes.templateFile
        fallbackDirectoryField.stringValue = config.notes.bear.fallbackDirectory
        
        resetDirtyState()
    }
    
    override func validate() -> [ValidationError] {
        // Validation handled by ConfigValidator
        return []
    }
    
    override func collectChanges(into config: inout AppConfiguration) {
        config.notes.backend = backendPopup.titleOfSelectedItem ?? "bear"
        
        // Parse comma-separated tags
        let tagString = tagsField.stringValue
        config.notes.bear.tags = tagString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        config.notes.templateFile = templatePathField.stringValue
        config.notes.bear.fallbackDirectory = fallbackDirectoryField.stringValue
    }
}
