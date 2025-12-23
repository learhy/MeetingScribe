import AppKit

private class LoggingButton: NSButton {
    private let logger = DualLogger(category: "PreferencesWindow.Button")
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        logger.info("mouseDown title=\(self.title) state=enabled:\(isEnabled)")
        super.mouseDown(with: event)
        if event.type == .leftMouseDown {
            logger.info("invoking onClick for \(self.title)")
            onClick?()
        }
    }
}

class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let logger = DualLogger(category: "PreferencesWindow")
    private let config = ConfigManager.shared
    let instanceId = UUID()
    
    private var tabView: NSTabView!
    private var saveButton: LoggingButton!
    private var cancelButton: LoggingButton!
    private var tabs: [PreferencesTab] = []
    
    // Single instance management
    static private weak var sharedInstance: PreferencesWindowController?
    private static var priorPolicy: NSApplication.ActivationPolicy = .accessory
    
    static func show() {
        if let existing = sharedInstance {
            existing.logger.info("show() using existing instance \(existing.instanceId)")
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            existing.logger.info("attachedSheet existing=\(String(describing: existing.window?.attachedSheet))")
        } else {
            let controller = PreferencesWindowController()
            controller.logger.info("show() creating new instance \(controller.instanceId)")
            sharedInstance = controller
            priorPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            controller.window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeFirstResponder(controller.cancelButton)
            controller.logger.info("attachedSheet new=\(String(describing: controller.window?.attachedSheet))")
        }
    }
    
    init() {
        // Create window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        logger.info("init PreferencesWindowController instance=\(instanceId)")
        logger.info("attachedSheet at init=\(String(describing: window.attachedSheet))")
        window.title = "MeetingScribe Preferences"
        window.minSize = NSSize(width: 600, height: 500)
        window.center()
        
        // super.init moved above to allow delegate assignment
        
        setupUI()
        loadConfiguration()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        
        // Create tab view (will hold all preference tabs)
        tabView = NSTabView(frame: NSRect(x: 0, y: 50, width: 600, height: 450))
        tabView.autoresizingMask = [.width, .height]
        contentView.addSubview(tabView)
        
        // Create and add all tabs
        addTab(GeneralTab(frame: NSRect(x: 0, y: 0, width: 600, height: 450)))
        addTab(AudioTab(frame: NSRect(x: 0, y: 0, width: 600, height: 450)))
        addTab(DetectionTab(frame: NSRect(x: 0, y: 0, width: 600, height: 450)))
        addTab(TranscriptionTab(frame: NSRect(x: 0, y: 0, width: 600, height: 450)))
        addTab(NotesTab(frame: NSRect(x: 0, y: 0, width: 600, height: 450)))
        addTab(LLMProvidersTab(frame: NSRect(x: 0, y: 0, width: 600, height: 450)))
        addTab(TemplateEditorTab(frame: NSRect(x: 0, y: 0, width: 600, height: 450)))
        addTab(LogViewerTab(frame: NSRect(x: 0, y: 0, width: 600, height: 450)))
        
        // Bottom bar with buttons
        let buttonBar = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 50))
        buttonBar.autoresizingMask = [.width, .maxYMargin]
        contentView.addSubview(buttonBar)
        
        // Cancel button
        cancelButton = LoggingButton(frame: NSRect(x: 420, y: 10, width: 80, height: 32))
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.isEnabled = true
        let controller = self
        cancelButton.onClick = { controller.cancelClicked() }
        buttonBar.addSubview(cancelButton)
        
        // Save button
        saveButton = LoggingButton(frame: NSRect(x: 510, y: 10, width: 80, height: 32))
        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\\r" // Return key
        saveButton.isEnabled = true
        saveButton.onClick = { controller.saveClicked() }
        buttonBar.addSubview(saveButton)
        
        // Ensure responder chain includes controller for nil targets
        contentView.nextResponder = self
        window?.makeFirstResponder(cancelButton)
        
        logger.info("Preferences window UI initialized")
    }
    
    private func loadConfiguration() {
        let currentConfig = config.config
        for tab in tabs {
            tab.loadConfig(currentConfig)
        }
        logger.info("Configuration loaded into tabs")
        logger.info("window isKey=\(window?.isKeyWindow ?? false) isMain=\(window?.isMainWindow ?? false) attachedSheet=\(String(describing: window?.attachedSheet))")
    }
    
    @objc private func cancelClicked() {
        logger.info("cancelClicked start instance=\(instanceId) visible=\(window?.isVisible ?? false)")
        // Check if dirty
        let isDirty = tabs.contains { $0.isDirty }
        
        if isDirty {
            let alert = NSAlert()
            alert.messageText = "Discard Changes?"
            alert.informativeText = "You have unsaved changes. Do you want to discard them?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            
            let response = alert.runModal()
            if response != .alertFirstButtonReturn {
                return // User chose "Cancel", don't close
            }
        }
        
        logger.info("Preferences cancelled, closing window")
        DispatchQueue.main.async { [weak self] in
            self?.window?.close()
            if let self = self {
                self.logger.info("Window closed after cancel instance=\(self.instanceId) visible=\(self.window?.isVisible ?? false)")
            }
            PreferencesWindowController.sharedInstance = nil
        }
    }
    
    @objc private func saveClicked() {
        logger.info("saveClicked start instance=\(instanceId) visible=\(window?.isVisible ?? false)")
        
        // Collect all changes into a temporary config
        var newConfig = config.config
        for tab in tabs {
            tab.collectChanges(into: &newConfig)
        }
        
        // Validate the complete configuration
        var allErrors: [ValidationError] = []
        for tab in tabs {
            let errors = tab.validate()
            allErrors.append(contentsOf: errors)
        }
        
        // Also run full config validation
        let configErrors = ConfigValidator.validateConfiguration(newConfig)
        allErrors.append(contentsOf: configErrors)
        
        if !allErrors.isEmpty {
            // Show validation errors
            let errorMessages = allErrors.map { error in "• \(error.field): \(error.message)" }.joined(separator: "\n")
            
            let alert = NSAlert()
            alert.messageText = "Configuration Errors"
            alert.informativeText = "Please fix the following errors:\n\n\(errorMessages)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
            
            logger.warning("Validation failed with \(allErrors.count) errors")
            
            return
        }
        
        // Validation passed - save configuration
        logger.info("Validation passed, saving configuration")
        config.updateAndSave(newConfig)
        
        // Reset dirty states
        for tab in tabs {
            tab.resetDirtyState()
        }
        
        logger.info("Configuration saved successfully, closing window")
        DispatchQueue.main.async { [weak self] in
            self?.window?.close()
            if let self = self {
                self.logger.info("Window closed after save instance=\(self.instanceId) visible=\(self.window?.isVisible ?? false)")
            }
            PreferencesWindowController.sharedInstance = nil
            // restore activation policy
            NSApp.setActivationPolicy(PreferencesWindowController.priorPolicy)
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        logger.info("windowWillClose instance=\(instanceId)")
        NSApp.setActivationPolicy(PreferencesWindowController.priorPolicy)
        PreferencesWindowController.sharedInstance = nil
    }
    
    // MARK: - Tab Management
    
    /// Add a preference tab to the window
    func addTab(_ tab: PreferencesTab) {
        tabs.append(tab)
        
        let tabViewItem = NSTabViewItem(identifier: tab.tabName)
        tabViewItem.label = tab.tabName
        tabViewItem.view = tab
        tabView.addTabViewItem(tabViewItem)
        
        logger.info("Added tab: \(tab.tabName)")
    }
    
    /// Select a tab by name
    func selectTab(named name: String) {
        for (index, item) in tabView.tabViewItems.enumerated() {
            if item.label == name {
                tabView.selectTabViewItem(at: index)
                logger.info("Selected tab: \(name)")
                return
            }
        }
        logger.warning("Tab not found: \\(name)")
    }
}
