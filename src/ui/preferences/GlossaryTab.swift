import AppKit

/// Validation error type for glossary entries
struct GlossaryValidationError {
    let field: String
    let message: String
}

class GlossaryTab: BasePreferencesTab, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate {
    override var tabName: String { "Glossary" }
    
    // UI Components
    private var enabledCheckbox: NSButton!
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var searchField: NSSearchField!
    private var addButton: NSButton!
    private var editButton: NSButton!
    private var deleteButton: NSButton!
    private var importButton: NSButton!
    private var exportButton: NSButton!
    private var deleteAllButton: NSButton!
    private var countLabel: NSTextField!
    private var filteringInfoLabel: NSTextField!
    
    // Data
    private var entries: [AppConfiguration.Transcription.GlossaryEntry] = []
    private var filteredEntries: [AppConfiguration.Transcription.GlossaryEntry] = []
    private var searchText: String = ""
    private var maxSize: Int = 1000
    
    // Validation constants
    private let maxTermLength = 100
    private let maxContextLength = 200
    private let maxPronunciationLength = 100
    
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
        let titleLabel = NSTextField(labelWithString: "Transcription Glossary")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.frame = NSRect(x: 20, y: yPos, width: 560, height: 20)
        addSubview(titleLabel)
        yPos -= 30
        
        // Enabled checkbox
        enabledCheckbox = NSButton(checkboxWithTitle: "Enable glossary-based transcription correction", target: self, action: #selector(enabledChanged))
        enabledCheckbox.frame = NSRect(x: 20, y: yPos, width: 400, height: 20)
        addSubview(enabledCheckbox)
        yPos -= 30
        
        // Help text
        let helpLabel = NSTextField(wrappingLabelWithString: "Add domain-specific terms that speech-to-text often misrecognizes. The LLM will correct phonetically similar mistakes.")
        helpLabel.font = NSFont.systemFont(ofSize: 10)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.frame = NSRect(x: 20, y: yPos - 10, width: 560, height: 30)
        addSubview(helpLabel)
        yPos -= 45
        
        // Search field
        searchField = NSSearchField(frame: NSRect(x: 20, y: yPos, width: 200, height: 22))
        searchField.placeholderString = "Search terms..."
        searchField.target = self
        searchField.action = #selector(searchChanged)
        addSubview(searchField)
        
        // Count label
        countLabel = NSTextField(labelWithString: "0 / 1000 terms")
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.frame = NSRect(x: 400, y: yPos + 2, width: 180, height: 18)
        countLabel.alignment = .right
        addSubview(countLabel)
        yPos -= 18
        
        // Filtering info label
        filteringInfoLabel = NSTextField(labelWithString: "")
        filteringInfoLabel.font = NSFont.systemFont(ofSize: 10)
        filteringInfoLabel.textColor = .tertiaryLabelColor
        filteringInfoLabel.frame = NSRect(x: 230, y: yPos, width: 350, height: 14)
        filteringInfoLabel.alignment = .right
        addSubview(filteringInfoLabel)
        yPos -= 16
        
        // Table view with scroll view
        let tableHeight = 180
        scrollView = NSScrollView(frame: NSRect(x: 20, y: yPos - tableHeight, width: 560, height: tableHeight))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        
        tableView = NSTableView(frame: scrollView.bounds)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        
        // Add columns
        let termColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("term"))
        termColumn.title = "Term"
        termColumn.width = 120
        tableView.addTableColumn(termColumn)
        
        let pronunciationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pronunciation"))
        pronunciationColumn.title = "Pronunciation"
        pronunciationColumn.width = 120
        tableView.addTableColumn(pronunciationColumn)
        
        let contextColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("context"))
        contextColumn.title = "Context"
        contextColumn.width = 200
        tableView.addTableColumn(contextColumn)
        
        let aliasesColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("aliases"))
        aliasesColumn.title = "Aliases"
        aliasesColumn.width = 100
        tableView.addTableColumn(aliasesColumn)
        
        scrollView.documentView = tableView
        addSubview(scrollView)
        yPos -= tableHeight + 10
        
        // Buttons row
        addButton = NSButton(frame: NSRect(x: 20, y: yPos, width: 60, height: 25))
        addButton.title = "Add"
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addClicked)
        addSubview(addButton)
        
        editButton = NSButton(frame: NSRect(x: 85, y: yPos, width: 60, height: 25))
        editButton.title = "Edit"
        editButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(editClicked)
        editButton.isEnabled = false
        addSubview(editButton)
        
        deleteButton = NSButton(frame: NSRect(x: 150, y: yPos, width: 70, height: 25))
        deleteButton.title = "Delete"
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.isEnabled = false
        addSubview(deleteButton)
        
        deleteAllButton = NSButton(frame: NSRect(x: 225, y: yPos, width: 85, height: 25))
        deleteAllButton.title = "Delete All"
        deleteAllButton.bezelStyle = .rounded
        deleteAllButton.target = self
        deleteAllButton.action = #selector(deleteAllClicked)
        addSubview(deleteAllButton)
        
        // Import/Export on right side
        importButton = NSButton(frame: NSRect(x: 430, y: yPos, width: 70, height: 25))
        importButton.title = "Import"
        importButton.bezelStyle = .rounded
        importButton.target = self
        importButton.action = #selector(importClicked)
        addSubview(importButton)
        
        exportButton = NSButton(frame: NSRect(x: 505, y: yPos, width: 70, height: 25))
        exportButton.title = "Export"
        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(exportClicked)
        addSubview(exportButton)
    }
    
    // MARK: - Actions
    
    @objc private func enabledChanged() {
        markDirty()
    }
    
    @objc private func searchChanged() {
        searchText = searchField.stringValue.lowercased()
        applyFilter()
        tableView.reloadData()
    }
    
    @objc private func addClicked() {
        if entries.count >= maxSize {
            showAlert(title: "Glossary Full", message: "Maximum glossary size (\(maxSize) terms) reached. Delete some entries before adding more.")
            return
        }
        showEntryEditor(entry: nil, index: nil)
    }
    
    @objc private func editClicked() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < filteredEntries.count else { return }
        
        let entry = filteredEntries[selectedRow]
        if let originalIndex = entries.firstIndex(where: { $0.term == entry.term }) {
            showEntryEditor(entry: entry, index: originalIndex)
        }
    }
    
    @objc private func deleteClicked() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < filteredEntries.count else { return }
        
        let entry = filteredEntries[selectedRow]
        
        let alert = NSAlert()
        alert.messageText = "Delete Entry?"
        alert.informativeText = "Are you sure you want to delete '\(entry.term)'?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            if let originalIndex = entries.firstIndex(where: { $0.term == entry.term }) {
                entries.remove(at: originalIndex)
                applyFilter()
                tableView.reloadData()
                updateCountLabel()
                markDirty()
            }
        }
    }
    
    @objc private func deleteAllClicked() {
        guard !entries.isEmpty else {
            showAlert(title: "Empty Glossary", message: "There are no entries to delete.")
            return
        }
        
        let alert = NSAlert()
        alert.messageText = "Delete All Entries?"
        alert.informativeText = "Are you sure you want to delete all \(entries.count) glossary entries? This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            entries.removeAll()
            applyFilter()
            tableView.reloadData()
            updateCountLabel()
            markDirty()
        }
    }
    
    @objc private func importClicked() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [.json]
        openPanel.message = "Choose a glossary JSON file to import"
        
        if openPanel.runModal() == .OK, let url = openPanel.url {
            importFromJSON(url: url)
        }
    }
    
    @objc private func exportClicked() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "glossary.json"
        savePanel.message = "Export glossary to JSON"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            exportToJSON(url: url)
        }
    }
    
    // MARK: - Entry Editor
    
    private func showEntryEditor(entry: AppConfiguration.Transcription.GlossaryEntry?, index: Int?) {
        let isEditing = entry != nil
        
        let alert = NSAlert()
        alert.messageText = isEditing ? "Edit Glossary Entry" : "Add Glossary Entry"
        alert.alertStyle = .informational
        alert.addButton(withTitle: isEditing ? "Save" : "Add")
        alert.addButton(withTitle: "Cancel")
        
        // Create accessory view with form fields
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 140))
        
        var yPos = 115
        
        // Term field
        let termLabel = NSTextField(labelWithString: "Term (required):")
        termLabel.frame = NSRect(x: 0, y: yPos, width: 100, height: 17)
        accessoryView.addSubview(termLabel)
        
        let termField = NSTextField(frame: NSRect(x: 105, y: yPos - 2, width: 240, height: 22))
        termField.stringValue = entry?.term ?? ""
        termField.placeholderString = "e.g., Kubernetes"
        accessoryView.addSubview(termField)
        yPos -= 30
        
        // Pronunciation field
        let pronLabel = NSTextField(labelWithString: "Pronunciation:")
        pronLabel.frame = NSRect(x: 0, y: yPos, width: 100, height: 17)
        accessoryView.addSubview(pronLabel)
        
        let pronField = NSTextField(frame: NSRect(x: 105, y: yPos - 2, width: 240, height: 22))
        pronField.stringValue = entry?.pronunciation ?? ""
        pronField.placeholderString = "e.g., koo-ber-NET-eez"
        accessoryView.addSubview(pronField)
        yPos -= 30
        
        // Context field
        let contextLabel = NSTextField(labelWithString: "Context:")
        contextLabel.frame = NSRect(x: 0, y: yPos, width: 100, height: 17)
        accessoryView.addSubview(contextLabel)
        
        let contextField = NSTextField(frame: NSRect(x: 105, y: yPos - 2, width: 240, height: 22))
        contextField.stringValue = entry?.context ?? ""
        contextField.placeholderString = "e.g., container orchestration"
        accessoryView.addSubview(contextField)
        yPos -= 30
        
        // Aliases field
        let aliasLabel = NSTextField(labelWithString: "Aliases:")
        aliasLabel.frame = NSRect(x: 0, y: yPos, width: 100, height: 17)
        accessoryView.addSubview(aliasLabel)
        
        let aliasField = NSTextField(frame: NSRect(x: 105, y: yPos - 2, width: 240, height: 22))
        aliasField.stringValue = entry?.aliases?.joined(separator: ", ") ?? ""
        aliasField.placeholderString = "e.g., k8s, K8s (comma-separated)"
        accessoryView.addSubview(aliasField)
        
        alert.accessoryView = accessoryView
        
        if alert.runModal() == .alertFirstButtonReturn {
            let term = termField.stringValue.trimmingCharacters(in: .whitespaces)
            
            // Validate
            if let error = validateEntry(term: term, 
                                         pronunciation: pronField.stringValue,
                                         context: contextField.stringValue,
                                         isNew: !isEditing,
                                         editingTerm: entry?.term) {
                showAlert(title: "Validation Error", message: error.message)
                return
            }
            
            // Parse aliases
            let aliasesText = aliasField.stringValue.trimmingCharacters(in: .whitespaces)
            let aliases: [String]? = aliasesText.isEmpty ? nil : aliasesText.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            
            let newEntry = AppConfiguration.Transcription.GlossaryEntry(
                term: term,
                pronunciation: pronField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? nil : pronField.stringValue.trimmingCharacters(in: .whitespaces),
                context: contextField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? nil : contextField.stringValue.trimmingCharacters(in: .whitespaces),
                aliases: aliases
            )
            
            if let editIndex = index {
                entries[editIndex] = newEntry
            } else {
                entries.append(newEntry)
            }
            
            applyFilter()
            tableView.reloadData()
            updateCountLabel()
            markDirty()
        }
    }
    
    // MARK: - Validation
    
    private func validateEntry(term: String, pronunciation: String, context: String, isNew: Bool, editingTerm: String?) -> GlossaryValidationError? {
        // Term is required
        if term.isEmpty {
            return GlossaryValidationError(field: "Term", message: "Term cannot be empty")
        }
        
        // Check length limits
        if term.count > maxTermLength {
            return GlossaryValidationError(field: "Term", message: "Term must be \(maxTermLength) characters or less")
        }
        
        if pronunciation.count > maxPronunciationLength {
            return GlossaryValidationError(field: "Pronunciation", message: "Pronunciation must be \(maxPronunciationLength) characters or less")
        }
        
        if context.count > maxContextLength {
            return GlossaryValidationError(field: "Context", message: "Context must be \(maxContextLength) characters or less")
        }
        
        // Check for control characters (prompt injection prevention)
        let controlChars = CharacterSet.controlCharacters
        if term.unicodeScalars.contains(where: { controlChars.contains($0) }) {
            return GlossaryValidationError(field: "Term", message: "Term contains invalid control characters")
        }
        
        // Check for duplicate terms (case-insensitive)
        let termLower = term.lowercased()
        let isDuplicate = entries.contains { entry in
            let existingLower = entry.term.lowercased()
            if let editing = editingTerm, editing.lowercased() == existingLower {
                return false // Skip the entry being edited
            }
            return existingLower == termLower
        }
        
        if isDuplicate {
            return GlossaryValidationError(field: "Term", message: "A term with this name already exists")
        }
        
        return nil
    }
    
    // MARK: - Import/Export
    
    private func importFromJSON(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let glossary = try decoder.decode(AppConfiguration.Transcription.Glossary.self, from: data)
            
            // Validate imported entries
            var validEntries: [AppConfiguration.Transcription.GlossaryEntry] = []
            var skipped = 0
            
            for entry in glossary.entries {
                if validateEntry(term: entry.term, 
                                pronunciation: entry.pronunciation ?? "",
                                context: entry.context ?? "",
                                isNew: true,
                                editingTerm: nil) == nil {
                    // Check if already exists
                    if !entries.contains(where: { $0.term.lowercased() == entry.term.lowercased() }) &&
                       !validEntries.contains(where: { $0.term.lowercased() == entry.term.lowercased() }) {
                        validEntries.append(entry)
                    } else {
                        skipped += 1
                    }
                } else {
                    skipped += 1
                }
            }
            
            // Check total size
            let totalAfterImport = entries.count + validEntries.count
            if totalAfterImport > maxSize {
                let allowedCount = maxSize - entries.count
                validEntries = Array(validEntries.prefix(allowedCount))
                showAlert(title: "Partial Import", message: "Imported \(validEntries.count) entries. \(glossary.entries.count - validEntries.count) entries skipped due to size limit or validation errors.")
            } else if skipped > 0 {
                showAlert(title: "Import Complete", message: "Imported \(validEntries.count) entries. \(skipped) duplicates or invalid entries skipped.")
            }
            
            entries.append(contentsOf: validEntries)
            applyFilter()
            tableView.reloadData()
            updateCountLabel()
            markDirty()
            
        } catch {
            showAlert(title: "Import Failed", message: "Could not read glossary file: \(error.localizedDescription)")
        }
    }
    
    private func exportToJSON(url: URL) {
        let glossary = AppConfiguration.Transcription.Glossary(
            enabled: enabledCheckbox.state == .on,
            entries: entries,
            maxSize: maxSize
        )
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(glossary)
            try data.write(to: url)
            
            showAlert(title: "Export Complete", message: "Exported \(entries.count) glossary entries.")
        } catch {
            showAlert(title: "Export Failed", message: "Could not save glossary file: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Helpers
    
    private func applyFilter() {
        if searchText.isEmpty {
            filteredEntries = entries
        } else {
            filteredEntries = entries.filter { entry in
                entry.term.lowercased().contains(searchText) ||
                (entry.pronunciation?.lowercased().contains(searchText) ?? false) ||
                (entry.context?.lowercased().contains(searchText) ?? false) ||
                (entry.aliases?.joined(separator: " ").lowercased().contains(searchText) ?? false)
            }
        }
    }
    
    private func updateCountLabel() {
        let count = entries.count
        countLabel.stringValue = "\(count) / \(maxSize) terms"
        countLabel.textColor = count >= maxSize ? .systemRed : .secondaryLabelColor
        updateFilteringInfoLabel()
    }
    
    private func updateFilteringInfoLabel() {
        guard !entries.isEmpty else {
            filteringInfoLabel.stringValue = ""
            return
        }
        
        let config = ConfigManager.shared.config.transcription.glossary
        let tokenBudget = config.maxGlossaryTokens
        let totalTokens = entries.reduce(0) { $0 + $1.estimatedTokenCount }
        
        if config.filteringEnabled {
            if totalTokens > tokenBudget {
                filteringInfoLabel.stringValue = "~\(totalTokens) tokens total → filtered to ≤\(tokenBudget) per transcript"
                filteringInfoLabel.textColor = .systemBlue
            } else {
                filteringInfoLabel.stringValue = "~\(totalTokens) tokens (within \(tokenBudget) budget)"
                filteringInfoLabel.textColor = .tertiaryLabelColor
            }
        } else {
            filteringInfoLabel.stringValue = "Filtering disabled – all \(totalTokens) tokens injected"
            filteringInfoLabel.textColor = .systemOrange
        }
    }
    
    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    // MARK: - NSTableViewDataSource
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredEntries.count
    }
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < filteredEntries.count else { return nil }
        let entry = filteredEntries[row]
        
        switch tableColumn?.identifier.rawValue {
        case "term":
            return entry.term
        case "pronunciation":
            return entry.pronunciation ?? ""
        case "context":
            return entry.context ?? ""
        case "aliases":
            return entry.aliases?.joined(separator: ", ") ?? ""
        default:
            return nil
        }
    }
    
    // MARK: - NSTableViewDelegate
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        let hasSelection = tableView.selectedRow >= 0
        editButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
        deleteAllButton.isEnabled = !entries.isEmpty
    }
    
    // MARK: - PreferencesTab Protocol
    
    override func loadConfig(_ config: AppConfiguration) {
        enabledCheckbox.state = config.transcription.glossary.enabled ? .on : .off
        entries = config.transcription.glossary.entries
        maxSize = config.transcription.glossary.maxSize
        applyFilter()
        tableView.reloadData()
        updateCountLabel()
        resetDirtyState()
    }
    
    override func validate() -> [ValidationError] {
        // All validation happens on add/edit, so just return empty
        return []
    }
    
    override func collectChanges(into config: inout AppConfiguration) {
        config.transcription.glossary.enabled = enabledCheckbox.state == .on
        config.transcription.glossary.entries = entries
        config.transcription.glossary.maxSize = maxSize
    }
}
