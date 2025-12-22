import AppKit

class AudioTab: BasePreferencesTab {
    override var tabName: String { "Audio" }
    
    private var sampleRatePopup: NSPopUpButton!
    private var bitDepthPopup: NSPopUpButton!
    private var channelsPopup: NSPopUpButton!
    private var outputDirectoryField: NSTextField!
    private var browseButton: NSButton!
    
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
        let titleLabel = NSTextField(labelWithString: "Audio Recording Settings")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.frame = NSRect(x: 20, y: yPos, width: 560, height: 20)
        addSubview(titleLabel)
        yPos -= 40
        
        // Sample Rate
        let sampleRateLabel = NSTextField(labelWithString: "Sample Rate (Hz):")
        sampleRateLabel.frame = NSRect(x: 20, y: yPos, width: 150, height: 20)
        sampleRateLabel.alignment = .right
        addSubview(sampleRateLabel)
        
        sampleRatePopup = NSPopUpButton(frame: NSRect(x: 180, y: yPos - 2, width: 150, height: 25), pullsDown: false)
        sampleRatePopup.addItems(withTitles: ["44100", "48000", "96000", "Custom"])
        sampleRatePopup.target = self
        sampleRatePopup.action = #selector(valueChanged)
        addSubview(sampleRatePopup)
        yPos -= 35
        
        // Bit Depth
        let bitDepthLabel = NSTextField(labelWithString: "Bit Depth:")
        bitDepthLabel.frame = NSRect(x: 20, y: yPos, width: 150, height: 20)
        bitDepthLabel.alignment = .right
        addSubview(bitDepthLabel)
        
        bitDepthPopup = NSPopUpButton(frame: NSRect(x: 180, y: yPos - 2, width: 150, height: 25), pullsDown: false)
        bitDepthPopup.addItems(withTitles: ["8", "16", "24", "32"])
        bitDepthPopup.target = self
        bitDepthPopup.action = #selector(valueChanged)
        addSubview(bitDepthPopup)
        yPos -= 35
        
        // Channels
        let channelsLabel = NSTextField(labelWithString: "Channels:")
        channelsLabel.frame = NSRect(x: 20, y: yPos, width: 150, height: 20)
        channelsLabel.alignment = .right
        addSubview(channelsLabel)
        
        channelsPopup = NSPopUpButton(frame: NSRect(x: 180, y: yPos - 2, width: 150, height: 25), pullsDown: false)
        channelsPopup.addItems(withTitles: ["Mono (1)", "Stereo (2)"])
        channelsPopup.target = self
        channelsPopup.action = #selector(valueChanged)
        addSubview(channelsPopup)
        yPos -= 45
        
        // Output Directory
        let outputDirLabel = NSTextField(labelWithString: "Output Directory:")
        outputDirLabel.frame = NSRect(x: 20, y: yPos, width: 150, height: 20)
        outputDirLabel.alignment = .right
        addSubview(outputDirLabel)
        
        outputDirectoryField = NSTextField(frame: NSRect(x: 180, y: yPos, width: 300, height: 22))
        outputDirectoryField.placeholderString = "~/Documents/MeetingScribe/recordings/"
        outputDirectoryField.target = self
        outputDirectoryField.action = #selector(textFieldChanged)
        addSubview(outputDirectoryField)
        
        browseButton = NSButton(frame: NSRect(x: 490, y: yPos - 2, width: 80, height: 25))
        browseButton.title = "Browse..."
        browseButton.bezelStyle = .rounded
        browseButton.target = self
        browseButton.action = #selector(browseClicked)
        addSubview(browseButton)
        yPos -= 35
        
        // Help text
        let helpLabel = NSTextField(wrappingLabelWithString: "Audio files will be saved to this directory. The directory will be created if it doesn't exist.")
        helpLabel.font = NSFont.systemFont(ofSize: 10)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.frame = NSRect(x: 180, y: yPos - 10, width: 390, height: 30)
        addSubview(helpLabel)
    }
    
    @objc private func valueChanged() {
        markDirty()
    }
    
    @objc private func textFieldChanged() {
        markDirty()
    }
    
    @objc private func browseClicked() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.message = "Choose output directory for audio recordings"
        
        if openPanel.runModal() == .OK, let url = openPanel.url {
            let path = url.path
            // Convert to tilde notation if in home directory
            let homeDir = NSHomeDirectory()
            if path.hasPrefix(homeDir) {
                let relativePath = String(path.dropFirst(homeDir.count))
                outputDirectoryField.stringValue = "~" + relativePath
            } else {
                outputDirectoryField.stringValue = path
            }
            markDirty()
        }
    }
    
    override func loadConfig(_ config: AppConfiguration) {
        // Sample Rate
        let sampleRateStr = String(config.audio.sampleRate)
        if let index = sampleRatePopup.itemTitles.firstIndex(of: sampleRateStr) {
            sampleRatePopup.selectItem(at: index)
        } else {
            sampleRatePopup.selectItem(at: 3) // "Custom"
        }
        
        // Bit Depth
        let bitDepthStr = String(config.audio.bitDepth)
        if let index = bitDepthPopup.itemTitles.firstIndex(of: bitDepthStr) {
            bitDepthPopup.selectItem(at: index)
        }
        
        // Channels
        channelsPopup.selectItem(at: config.audio.channels - 1) // 1->0, 2->1
        
        // Output Directory
        outputDirectoryField.stringValue = config.audio.outputDirectory
        
        resetDirtyState()
    }
    
    override func validate() -> [ValidationError] {
        var errors: [ValidationError] = []
        
        if outputDirectoryField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append(ValidationError(field: "Output Directory", message: "Output Directory cannot be empty"))
        }
        
        return errors
    }
    
    override func collectChanges(into config: inout AppConfiguration) {
        // Sample Rate
        if let selectedTitle = sampleRatePopup.titleOfSelectedItem, selectedTitle != "Custom" {
            config.audio.sampleRate = Int(selectedTitle) ?? 48000
        }
        
        // Bit Depth
        if let selectedTitle = bitDepthPopup.titleOfSelectedItem {
            config.audio.bitDepth = Int(selectedTitle) ?? 16
        }
        
        // Channels
        config.audio.channels = channelsPopup.indexOfSelectedItem + 1 // 0->1, 1->2
        
        // Output Directory
        config.audio.outputDirectory = outputDirectoryField.stringValue
    }
}
