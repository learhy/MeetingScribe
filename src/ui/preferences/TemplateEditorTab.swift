import AppKit

class TemplateEditorTab: BasePreferencesTab {
    override var tabName: String { "Template Editor" }
    
    private var pathLabel: NSTextField!
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var templatePath: String = ""
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    private func setupUI() {
        var yPos = 350
        
        // Path display (read-only)
        let pathTitleLabel = NSTextField(labelWithString: "Template File:")
        pathTitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        pathTitleLabel.frame = NSRect(x: 20, y: yPos, width: 100, height: 20)
        addSubview(pathTitleLabel)
        
        pathLabel = NSTextField(labelWithString: "")
        pathLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.frame = NSRect(x: 125, y: yPos + 2, width: 455, height: 16)
        pathLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(pathLabel)
        yPos -= 30
        
        // Text editor with scroll view sized to bounds
        let scrollHeight = max(100, self.bounds.height - 80)
        scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 560, height: scrollHeight))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .bezelBorder
        
        textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainer?.containerSize = NSSize(width: scrollView.bounds.width - 20, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.delegate = self
        
        scrollView.documentView = textView
        addSubview(scrollView)
    }
    
    override func loadConfig(_ config: AppConfiguration) {
        templatePath = config.notes.templateFile
        pathLabel.stringValue = templatePath
        
        // Load template file
        loadTemplateFile()
        
        resetDirtyState()
    }
    
    private func loadTemplateFile() {
        guard !templatePath.isEmpty else {
            textView.string = "# Template file not configured\n\nPlease set a template file in the Notes tab."
            return
        }
        
        let expandedPath = (templatePath as NSString).expandingTildeInPath
        
        do {
            let content = try String(contentsOfFile: expandedPath, encoding: .utf8)
            textView.string = content
        } catch {
            textView.string = "# Error loading template\n\nFailed to load: \(templatePath)\n\nError: \(error.localizedDescription)"
        }
    }
    
    override func validate() -> [ValidationError] {
        // No validation needed for template editor
        return []
    }
    
    override func collectChanges(into config: inout AppConfiguration) {
        // Save template file if dirty
        if isDirty {
            saveTemplateFile()
        }
    }
    
    private func saveTemplateFile() {
        guard !templatePath.isEmpty else { return }
        
        let expandedPath = (templatePath as NSString).expandingTildeInPath
        
        do {
            try textView.string.write(toFile: expandedPath, atomically: true, encoding: .utf8)
        } catch {
            DispatchQueue.main.async { [weak self] in
                let alert = NSAlert()
                alert.messageText = "Save Failed"
                alert.informativeText = "Failed to save template: \(error.localizedDescription)"
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                if let window = self?.window {
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }
}

// MARK: - NSTextViewDelegate
extension TemplateEditorTab: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        markDirty()
    }
}
