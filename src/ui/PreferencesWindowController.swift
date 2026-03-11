import AppKit

// MARK: - Sidebar Data Model

/// Represents a group header or leaf item in the sidebar
private struct SidebarItem {
    let identifier: String
    let title: String
    let children: [SidebarItem]
    let tab: PreferencesTab?
    
    /// Group item (header with children)
    init(group identifier: String, title: String, children: [SidebarItem]) {
        self.identifier = identifier
        self.title = title
        self.children = children
        self.tab = nil
    }
    
    /// Leaf item (linked to a tab view)
    init(leaf identifier: String, title: String, tab: PreferencesTab) {
        self.identifier = identifier
        self.title = title
        self.children = []
        self.tab = tab
    }
    
    var isGroup: Bool { tab == nil && !children.isEmpty }
}

// MARK: - Preferences Window Controller

class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let logger = DualLogger(category: "PreferencesWindow")
    private let config = ConfigManager.shared
    let instanceId = UUID()
    
    private var outlineView: NSOutlineView!
    private var detailContainer: NSView!
    private var saveButton: NSButton!
    private var cancelButton: NSButton!
    private var applyButton: NSButton!
    private var tabs: [PreferencesTab] = []
    private var sidebarItems: [SidebarItem] = []
    /// Flat lookup: identifier -> SidebarItem (leaves only)
    private var itemsByIdentifier: [String: SidebarItem] = [:]
    private var currentDetailView: NSView?
    
    private static let lastTabKey = "PreferencesLastSelectedTab"
    
    // Single instance management
    static private var sharedInstance: PreferencesWindowController?
    private static var priorPolicy: NSApplication.ActivationPolicy = .accessory
    
    static func show() {
        if let existing = sharedInstance {
            existing.logger.info("show() using existing instance \(existing.instanceId)")
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
        }
    }
    
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.title = "MeetingScribe Preferences"
        window.minSize = NSSize(width: 800, height: 600)
        window.center()
        
        setupUI()
        loadConfiguration()
        restoreLastSelectedTab()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    // MARK: - UI Setup
    
    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        
        // Build tab instances
        let generalTab = GeneralTab(frame: .zero)
        let audioTab = AudioTab(frame: .zero)
        let detectionTab = DetectionTab(frame: .zero)
        let transcriptionTab = TranscriptionTab(frame: .zero)
        let glossaryTab = GlossaryTab(frame: .zero)
        let speakerTab = SpeakerManagementTab(frame: .zero)
        let notesTab = NotesTab(frame: .zero)
        let llmTab = LLMProvidersTab(frame: .zero)
        let templateTab = TemplateEditorTab(frame: .zero)
        let logTab = LogViewerTab(frame: .zero)
        
        tabs = [generalTab, audioTab, detectionTab, transcriptionTab, glossaryTab,
                speakerTab, notesTab, llmTab, templateTab, logTab]
        
        // Build sidebar hierarchy (group identifiers use _section suffix to avoid collisions with leaf identifiers)
        sidebarItems = [
            SidebarItem(group: "app_section", title: "App", children: [
                SidebarItem(leaf: "general", title: "General", tab: generalTab),
            ]),
            SidebarItem(group: "recording_section", title: "Recording", children: [
                SidebarItem(leaf: "audio", title: "Audio", tab: audioTab),
                SidebarItem(leaf: "detection", title: "Detection", tab: detectionTab),
            ]),
            SidebarItem(group: "transcription_section", title: "Transcription", children: [
                SidebarItem(leaf: "transcription", title: "Transcription", tab: transcriptionTab),
                SidebarItem(leaf: "glossary", title: "Glossary", tab: glossaryTab),
                SidebarItem(leaf: "speakers", title: "Speakers", tab: speakerTab),
            ]),
            SidebarItem(group: "output_section", title: "Output", children: [
                SidebarItem(leaf: "notes", title: "Notes", tab: notesTab),
                SidebarItem(leaf: "llm", title: "LLM Providers", tab: llmTab),
                SidebarItem(leaf: "template", title: "Template Editor", tab: templateTab),
            ]),
            SidebarItem(group: "advanced_section", title: "Advanced", children: [
                SidebarItem(leaf: "logs", title: "Logs", tab: logTab),
            ]),
        ]
        
        // Build flat lookup (groups + leaves, keyed by identifier)
        for group in sidebarItems {
            itemsByIdentifier[group.identifier] = group
            for child in group.children {
                itemsByIdentifier[child.identifier] = child
            }
        }
        
        let bounds = contentView.bounds
        let sidebarWidth: CGFloat = 200
        let buttonBarHeight: CGFloat = 50
        let detailX = sidebarWidth + 1  // 1px for divider
        let detailWidth = bounds.width - detailX
        
        // --- Sidebar ---
        let sidebarScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height))
        sidebarScrollView.hasVerticalScroller = true
        sidebarScrollView.autoresizingMask = [.height]
        contentView.addSubview(sidebarScrollView)
        
        outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.indentationPerLevel = 14
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.backgroundColor = NSColor(white: 0.95, alpha: 1.0)
        outlineView.delegate = self
        outlineView.dataSource = self
        
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarColumn"))
        column.width = sidebarWidth
        column.isEditable = false
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        
        sidebarScrollView.documentView = outlineView
        
        // --- Vertical divider ---
        let divider = NSBox(frame: NSRect(x: sidebarWidth, y: 0, width: 1, height: bounds.height))
        divider.boxType = .separator
        divider.autoresizingMask = [.height]
        contentView.addSubview(divider)
        
        // --- Detail pane ---
        let detailPane = NSView(frame: NSRect(x: detailX, y: 0, width: detailWidth, height: bounds.height))
        detailPane.autoresizingMask = [.width, .height]
        contentView.addSubview(detailPane)
        
        // Detail content area (fills detail pane above button bar)
        detailContainer = NSView(frame: NSRect(x: 0, y: buttonBarHeight + 1, width: detailWidth, height: bounds.height - buttonBarHeight - 1))
        detailContainer.autoresizingMask = [.width, .height]
        detailPane.addSubview(detailContainer)
        
        // --- Separator line above button bar ---
        let separator = NSBox(frame: NSRect(x: 0, y: buttonBarHeight, width: detailWidth, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .maxYMargin]
        detailPane.addSubview(separator)
        
        // --- Button bar at bottom of detail pane ---
        let buttonBar = NSView(frame: NSRect(x: 0, y: 0, width: detailWidth, height: buttonBarHeight))
        buttonBar.autoresizingMask = [.width, .maxYMargin]
        detailPane.addSubview(buttonBar)
        
        saveButton = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: detailWidth - 100, y: 10, width: 80, height: 30)
        saveButton.autoresizingMask = [.minXMargin]
        buttonBar.addSubview(saveButton)
        
        applyButton = NSButton(title: "Apply", target: self, action: #selector(applyClicked))
        applyButton.bezelStyle = .rounded
        applyButton.frame = NSRect(x: detailWidth - 188, y: 10, width: 80, height: 30)
        applyButton.autoresizingMask = [.minXMargin]
        buttonBar.addSubview(applyButton)
        
        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: detailWidth - 276, y: 10, width: 80, height: 30)
        cancelButton.autoresizingMask = [.minXMargin]
        buttonBar.addSubview(cancelButton)
        
        // Expand all groups and reload
        outlineView.reloadData()
        for group in sidebarItems {
            outlineView.expandItem(group.identifier)
        }
        
        logger.info("Preferences window UI initialized with sidebar navigation")
    }
    
    // MARK: - Configuration
    
    private func loadConfiguration() {
        let currentConfig = config.config
        for tab in tabs {
            tab.loadConfig(currentConfig)
        }
        logger.info("Configuration loaded into tabs")
    }
    
    private func restoreLastSelectedTab() {
        let lastId = UserDefaults.standard.string(forKey: Self.lastTabKey) ?? "general"
        selectSidebarItem(identifier: lastId)
    }
    
    private func selectSidebarItem(identifier: String) {
        // Find the group and child by identifier
        for group in sidebarItems {
            for child in group.children {
                if child.identifier == identifier {
                    // Ensure group is expanded
                    outlineView.expandItem(group.identifier)
                    let row = outlineView.row(forItem: child.identifier)
                    if row >= 0 {
                        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                        showDetail(for: child)
                    } else if let firstChild = sidebarItems.first?.children.first {
                        // Fallback to first item
                        let fallbackRow = outlineView.row(forItem: firstChild.identifier)
                        if fallbackRow >= 0 {
                            outlineView.selectRowIndexes(IndexSet(integer: fallbackRow), byExtendingSelection: false)
                            showDetail(for: firstChild)
                        }
                    }
                    return
                }
            }
        }
        // Fallback: select first item
        if let firstChild = sidebarItems.first?.children.first {
            let row = outlineView.row(forItem: firstChild.identifier)
            if row >= 0 {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                showDetail(for: firstChild)
            }
        }
    }
    
    private func showDetail(for item: SidebarItem) {
        guard let tabView = item.tab else { return }
        
        // Remove previous detail view
        currentDetailView?.removeFromSuperview()
        
        // Add new detail view filling the container
        let view = tabView as NSView
        view.frame = detailContainer.bounds
        view.autoresizingMask = [.width, .height]
        detailContainer.addSubview(view)
        currentDetailView = view
        
        // Persist selection
        UserDefaults.standard.set(item.identifier, forKey: Self.lastTabKey)
    }
    
    // MARK: - Actions
    
    @objc private func cancelClicked() {
        logger.info("cancelClicked start instance=\(instanceId)")
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
                return
            }
        }
        
        logger.info("Preferences cancelled, closing window")
        DispatchQueue.main.async { [weak self] in
            self?.window?.close()
            PreferencesWindowController.sharedInstance = nil
        }
    }
    
    @objc private func applyClicked() {
        logger.info("applyClicked start instance=\(instanceId)")
        if saveConfiguration(closeAfter: false) {
            logger.info("Configuration applied successfully")
        }
    }
    
    @objc private func saveClicked() {
        logger.info("saveClicked start instance=\(instanceId)")
        if saveConfiguration(closeAfter: true) {
            logger.info("Configuration saved successfully, closing window")
        }
    }
    
    /// Validate, save, and optionally close. Returns true on success.
    private func saveConfiguration(closeAfter: Bool) -> Bool {
        // Collect changes
        var newConfig = config.config
        for tab in tabs {
            tab.collectChanges(into: &newConfig)
        }
        
        // Validate
        var allErrors: [ValidationError] = []
        for tab in tabs {
            allErrors.append(contentsOf: tab.validate())
        }
        allErrors.append(contentsOf: ConfigValidator.validateConfiguration(newConfig))
        
        if !allErrors.isEmpty {
            // Group errors by tab name for clarity
            var errorsByTab: [String: [ValidationError]] = [:]
            for error in allErrors {
                // Try to attribute error to a tab by field name
                let tabName = attributeErrorToTab(error)
                errorsByTab[tabName, default: []].append(error)
            }
            
            var message = ""
            for (tabName, errors) in errorsByTab.sorted(by: { $0.key < $1.key }) {
                message += "\(tabName):\n"
                for error in errors {
                    message += "  • \(error.field): \(error.message)\n"
                }
            }
            
            let alert = NSAlert()
            alert.messageText = "Configuration Errors"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
            
            // Navigate to first tab with error
            if let firstTabName = errorsByTab.keys.sorted().first {
                navigateToTabByName(firstTabName)
            }
            
            logger.warning("Validation failed with \(allErrors.count) errors")
            return false
        }
        
        // Save
        config.updateAndSave(newConfig)
        for tab in tabs {
            tab.resetDirtyState()
        }
        
        // Refresh sidebar dirty indicators
        outlineView.reloadData()
        for group in sidebarItems {
            outlineView.expandItem(group.identifier)
        }
        outlineView.sizeLastColumnToFit()
        // Re-select current row
        if let lastId = UserDefaults.standard.string(forKey: Self.lastTabKey) {
            selectSidebarItem(identifier: lastId)
        }
        
        if closeAfter {
            DispatchQueue.main.async { [weak self] in
                self?.window?.close()
                PreferencesWindowController.sharedInstance = nil
                NSApp.setActivationPolicy(PreferencesWindowController.priorPolicy)
            }
        }
        return true
    }
    
    /// Best-effort attribution of a validation error to a tab name
    private func attributeErrorToTab(_ error: ValidationError) -> String {
        let field = error.field.lowercased()
        if field.contains("sample rate") || field.contains("bit depth") || field.contains("channel") || field.contains("output dir") {
            return "Audio"
        } else if field.contains("poll") || field.contains("debounce") || field.contains("confidence threshold") {
            return "Detection"
        } else if field.contains("whisper") || field.contains("model path") || field.contains("openai api key") || field.contains("diarization") || field.contains("distance") || field.contains("python") || field.contains("script") {
            return "Transcription"
        } else if field.contains("anthropic") || field.contains("ollama") || field.contains("llm") {
            return "LLM Providers"
        } else if field.contains("template") || field.contains("bear") || field.contains("tag") || field.contains("fallback") || field.contains("backend") {
            return "Notes"
        }
        return "General"
    }
    
    private func navigateToTabByName(_ name: String) {
        let nameLower = name.lowercased()
        for group in sidebarItems {
            for child in group.children {
                if child.title.lowercased() == nameLower {
                    selectSidebarItem(identifier: child.identifier)
                    return
                }
            }
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        logger.info("windowWillClose instance=\(instanceId)")
        NSApp.setActivationPolicy(PreferencesWindowController.priorPolicy)
        PreferencesWindowController.sharedInstance = nil
    }
    
    // MARK: - Public API
    
    /// Select a tab by name (used by NotesTab "Edit Template" button)
    func selectTab(named name: String) {
        navigateToTabByName(name)
    }
}

// MARK: - NSOutlineViewDataSource

extension PreferencesWindowController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return sidebarItems.count
        }
        if let identifier = item as? String {
            return sidebarItems.first(where: { $0.identifier == identifier })?.children.count ?? 0
        }
        return 0
    }
    
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return sidebarItems[index].identifier
        }
        if let identifier = item as? String,
           let group = sidebarItems.first(where: { $0.identifier == identifier }) {
            return group.children[index].identifier
        }
        return ""
    }
    
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let identifier = item as? String {
            return sidebarItems.contains(where: { $0.identifier == identifier })
        }
        return false
    }
}

// MARK: - NSOutlineViewDelegate

extension PreferencesWindowController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if let identifier = item as? String {
            return sidebarItems.contains(where: { $0.identifier == identifier })
        }
        return false
    }
    
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        // Only allow selecting leaf items, not group headers
        if let identifier = item as? String {
            return !sidebarItems.contains(where: { $0.identifier == identifier })
        }
        return false
    }
    
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let identifier = item as? String else { return nil }
        guard let sidebarItem = itemsByIdentifier[identifier] else { return nil }
        
        let isGroup = sidebarItem.isGroup
        let cellId = NSUserInterfaceItemIdentifier(isGroup ? "GroupCell" : "ItemCell")
        
        let cell: NSTableCellView
        if let existing = outlineView.makeView(withIdentifier: cellId, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        
        cell.textField?.stringValue = sidebarItem.title
        
        if isGroup {
            cell.textField?.stringValue = sidebarItem.title.uppercased()
            cell.textField?.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            cell.textField?.textColor = .tertiaryLabelColor
        } else {
            // Check dirty state for leaf items
            let isDirty = sidebarItem.tab?.isDirty ?? false
            cell.textField?.font = isDirty
                ? NSFont.systemFont(ofSize: 13, weight: .semibold)
                : NSFont.systemFont(ofSize: 13, weight: .regular)
            cell.textField?.textColor = .labelColor
        }
        
        return cell
    }
    
    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let identifier = outlineView.item(atRow: row) as? String else { return }
        
        if let item = itemsByIdentifier[identifier], !item.isGroup {
            showDetail(for: item)
        }
    }
}

