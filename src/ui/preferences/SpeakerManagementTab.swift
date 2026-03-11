import AppKit

/// Preferences tab for managing speaker identities and pending name suggestions
class SpeakerManagementTab: BasePreferencesTab, NSTableViewDelegate, NSTableViewDataSource {
    override var tabName: String { "Speakers" }
    
    // MARK: - Service
    
    private let service = SpeakerDatabaseService.shared
    private let logger = DualLogger(category: "SpeakerManagementTab")
    
    // MARK: - UI Components
    
    private var segmentedControl: NSSegmentedControl!
    private var containerView: NSView!
    
    // Pending Suggestions Tab
    private var pendingScrollView: NSScrollView!
    private var pendingTableView: NSTableView!
    private var confirmButton: NSButton!
    private var rejectButton: NSButton!
    private var pendingCountLabel: NSTextField!
    
    // Speakers Tab
    private var speakersScrollView: NSScrollView!
    private var speakersTableView: NSTableView!
    private var renameButton: NSButton!
    private var mergeButton: NSButton!
    private var splitButton: NSButton!
    private var deleteButton: NSButton!
    private var speakersSearchField: NSSearchField!
    private var speakersCountLabel: NSTextField!
    
    // Stats Tab
    private var statsView: NSView!
    private var totalSpeakersLabel: NSTextField!
    private var totalEmbeddingsLabel: NSTextField!
    private var namedSpeakersLabel: NSTextField!
    private var pendingStatsLabel: NSTextField!
    private var databaseSizeLabel: NSTextField!
    private var cleanupButton: NSButton!
    private var checkButton: NSButton!
    
    // Common
    private var refreshButton: NSButton!
    private var loadingIndicator: NSProgressIndicator!
    private var statusLabel: NSTextField!
    
    // State
    private var speakerSearchText: String = ""
    private var filteredSpeakers: [Speaker] = []
    private var selectedSpeakerDetail: SpeakerDetail?
    private var notificationObserver: Any?
    
    // MARK: - Initialization
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
        setupNotifications()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - UI Setup
    
    private func setupUI() {
        var yPos = 380
        
        // Title and refresh
        let titleLabel = NSTextField(labelWithString: "Speaker Management")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.frame = NSRect(x: 20, y: yPos, width: 300, height: 20)
        addSubview(titleLabel)
        
        // Loading indicator
        loadingIndicator = NSProgressIndicator(frame: NSRect(x: 330, y: yPos + 2, width: 16, height: 16))
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        addSubview(loadingIndicator)
        
        // Refresh button
        refreshButton = NSButton(frame: NSRect(x: 510, y: yPos - 2, width: 70, height: 24))
        refreshButton.title = "Refresh"
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        addSubview(refreshButton)
        yPos -= 30
        
        // Status label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 20, y: yPos, width: 560, height: 16)
        addSubview(statusLabel)
        yPos -= 25
        
        // Segmented control for sub-tabs
        segmentedControl = NSSegmentedControl(labels: ["Pending", "Speakers", "Stats"], trackingMode: .selectOne, target: self, action: #selector(segmentChanged))
        segmentedControl.frame = NSRect(x: 20, y: yPos, width: 300, height: 24)
        segmentedControl.selectedSegment = 0
        addSubview(segmentedControl)
        yPos -= 10
        
        // Container for sub-tab content
        containerView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: yPos))
        addSubview(containerView)
        
        setupPendingView()
        setupSpeakersView()
        setupStatsView()
        
        showSegment(0)
    }
    
    private func setupPendingView() {
        let contentHeight = 280
        var yPos = contentHeight - 10
        
        // Info label
        let infoLabel = NSTextField(wrappingLabelWithString: "Review name suggestions from AI identification. Confirm to apply the name, or reject to keep the auto-generated ID.")
        infoLabel.font = NSFont.systemFont(ofSize: 10)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.frame = NSRect(x: 20, y: yPos - 25, width: 560, height: 30)
        containerView.addSubview(infoLabel)
        infoLabel.tag = 100 // Tag for pending view
        yPos -= 40
        
        // Count label
        pendingCountLabel = NSTextField(labelWithString: "0 pending suggestions")
        pendingCountLabel.font = NSFont.systemFont(ofSize: 11)
        pendingCountLabel.textColor = .secondaryLabelColor
        pendingCountLabel.frame = NSRect(x: 20, y: yPos, width: 200, height: 16)
        containerView.addSubview(pendingCountLabel)
        pendingCountLabel.tag = 100
        yPos -= 20
        
        // Table view
        let tableHeight = 160
        pendingScrollView = NSScrollView(frame: NSRect(x: 20, y: yPos - tableHeight, width: 560, height: tableHeight))
        pendingScrollView.hasVerticalScroller = true
        pendingScrollView.borderType = .bezelBorder
        pendingScrollView.identifier = NSUserInterfaceItemIdentifier("pending")
        
        pendingTableView = NSTableView(frame: pendingScrollView.bounds)
        pendingTableView.delegate = self
        pendingTableView.dataSource = self
        pendingTableView.allowsMultipleSelection = false
        pendingTableView.rowHeight = 22
        pendingTableView.usesAlternatingRowBackgroundColors = true
        pendingTableView.tag = 100
        
        let speakerCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pendingSpeaker"))
        speakerCol.title = "Current ID"
        speakerCol.width = 120
        pendingTableView.addTableColumn(speakerCol)
        
        let suggestedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestedName"))
        suggestedCol.title = "Suggested Name"
        suggestedCol.width = 150
        pendingTableView.addTableColumn(suggestedCol)
        
        let confidenceCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("confidence"))
        confidenceCol.title = "Confidence"
        confidenceCol.width = 80
        pendingTableView.addTableColumn(confidenceCol)
        
        let sourceCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sourceCol.title = "Source"
        sourceCol.width = 80
        pendingTableView.addTableColumn(sourceCol)
        
        let createdCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pendingCreated"))
        createdCol.title = "Created"
        createdCol.width = 100
        pendingTableView.addTableColumn(createdCol)
        
        pendingScrollView.documentView = pendingTableView
        containerView.addSubview(pendingScrollView)
        yPos -= tableHeight + 10
        
        // Buttons
        confirmButton = NSButton(frame: NSRect(x: 20, y: yPos, width: 80, height: 25))
        confirmButton.title = "Confirm"
        confirmButton.bezelStyle = .rounded
        confirmButton.target = self
        confirmButton.action = #selector(confirmClicked)
        confirmButton.isEnabled = false
        confirmButton.tag = 100
        containerView.addSubview(confirmButton)
        
        rejectButton = NSButton(frame: NSRect(x: 110, y: yPos, width: 80, height: 25))
        rejectButton.title = "Reject"
        rejectButton.bezelStyle = .rounded
        rejectButton.target = self
        rejectButton.action = #selector(rejectClicked)
        rejectButton.isEnabled = false
        rejectButton.tag = 100
        containerView.addSubview(rejectButton)
    }
    
    private func setupSpeakersView() {
        let contentHeight = 280
        var yPos = contentHeight - 10
        
        // Search field
        speakersSearchField = NSSearchField(frame: NSRect(x: 20, y: yPos - 22, width: 200, height: 22))
        speakersSearchField.placeholderString = "Search speakers..."
        speakersSearchField.target = self
        speakersSearchField.action = #selector(speakerSearchChanged)
        speakersSearchField.tag = 200
        containerView.addSubview(speakersSearchField)
        
        // Count label
        speakersCountLabel = NSTextField(labelWithString: "0 speakers")
        speakersCountLabel.font = NSFont.systemFont(ofSize: 11)
        speakersCountLabel.textColor = .secondaryLabelColor
        speakersCountLabel.frame = NSRect(x: 400, y: yPos - 20, width: 180, height: 16)
        speakersCountLabel.alignment = .right
        speakersCountLabel.tag = 200
        containerView.addSubview(speakersCountLabel)
        yPos -= 35
        
        // Table view
        let tableHeight = 170
        speakersScrollView = NSScrollView(frame: NSRect(x: 20, y: yPos - tableHeight, width: 560, height: tableHeight))
        speakersScrollView.hasVerticalScroller = true
        speakersScrollView.borderType = .bezelBorder
        speakersScrollView.identifier = NSUserInterfaceItemIdentifier("speakers")
        
        speakersTableView = NSTableView(frame: speakersScrollView.bounds)
        speakersTableView.delegate = self
        speakersTableView.dataSource = self
        speakersTableView.allowsMultipleSelection = true
        speakersTableView.rowHeight = 22
        speakersTableView.usesAlternatingRowBackgroundColors = true
        speakersTableView.tag = 200
        
        let idCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("speakerId"))
        idCol.title = "ID"
        idCol.width = 100
        speakersTableView.addTableColumn(idCol)
        
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("speakerName"))
        nameCol.title = "Name"
        nameCol.width = 150
        speakersTableView.addTableColumn(nameCol)
        
        let embeddingsCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("embeddingCount"))
        embeddingsCol.title = "Embeddings"
        embeddingsCol.width = 80
        speakersTableView.addTableColumn(embeddingsCol)
        
        let lastSeenCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("lastSeen"))
        lastSeenCol.title = "Last Seen"
        lastSeenCol.width = 120
        speakersTableView.addTableColumn(lastSeenCol)
        
        let confCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("nameConfidence"))
        confCol.title = "Confidence"
        confCol.width = 80
        speakersTableView.addTableColumn(confCol)
        
        speakersScrollView.documentView = speakersTableView
        containerView.addSubview(speakersScrollView)
        yPos -= tableHeight + 10
        
        // Buttons
        renameButton = NSButton(frame: NSRect(x: 20, y: yPos, width: 70, height: 25))
        renameButton.title = "Rename"
        renameButton.bezelStyle = .rounded
        renameButton.target = self
        renameButton.action = #selector(renameClicked)
        renameButton.isEnabled = false
        renameButton.tag = 200
        containerView.addSubview(renameButton)
        
        mergeButton = NSButton(frame: NSRect(x: 95, y: yPos, width: 70, height: 25))
        mergeButton.title = "Merge"
        mergeButton.bezelStyle = .rounded
        mergeButton.target = self
        mergeButton.action = #selector(mergeClicked)
        mergeButton.isEnabled = false
        mergeButton.tag = 200
        containerView.addSubview(mergeButton)
        
        splitButton = NSButton(frame: NSRect(x: 170, y: yPos, width: 60, height: 25))
        splitButton.title = "Split"
        splitButton.bezelStyle = .rounded
        splitButton.target = self
        splitButton.action = #selector(splitClicked)
        splitButton.isEnabled = false
        splitButton.tag = 200
        containerView.addSubview(splitButton)
        
        deleteButton = NSButton(frame: NSRect(x: 500, y: yPos, width: 80, height: 25))
        deleteButton.title = "Delete"
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.isEnabled = false
        deleteButton.tag = 200
        containerView.addSubview(deleteButton)
    }
    
    private func setupStatsView() {
        let contentHeight = 280
        var yPos = contentHeight - 20
        
        // Stats labels
        let statsTitle = NSTextField(labelWithString: "Database Statistics")
        statsTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        statsTitle.frame = NSRect(x: 20, y: yPos, width: 200, height: 18)
        statsTitle.tag = 300
        containerView.addSubview(statsTitle)
        yPos -= 30
        
        totalSpeakersLabel = createStatLabel(y: yPos, tag: 300)
        totalSpeakersLabel.stringValue = "Total Speakers: -"
        yPos -= 22
        
        namedSpeakersLabel = createStatLabel(y: yPos, tag: 300)
        namedSpeakersLabel.stringValue = "Named Speakers: -"
        yPos -= 22
        
        totalEmbeddingsLabel = createStatLabel(y: yPos, tag: 300)
        totalEmbeddingsLabel.stringValue = "Total Embeddings: -"
        yPos -= 22
        
        pendingStatsLabel = createStatLabel(y: yPos, tag: 300)
        pendingStatsLabel.stringValue = "Pending Suggestions: -"
        yPos -= 22
        
        databaseSizeLabel = createStatLabel(y: yPos, tag: 300)
        databaseSizeLabel.stringValue = "Database Size: -"
        yPos -= 40
        
        // Maintenance section
        let maintTitle = NSTextField(labelWithString: "Database Maintenance")
        maintTitle.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        maintTitle.frame = NSRect(x: 20, y: yPos, width: 200, height: 18)
        maintTitle.tag = 300
        containerView.addSubview(maintTitle)
        yPos -= 30
        
        cleanupButton = NSButton(frame: NSRect(x: 20, y: yPos, width: 100, height: 25))
        cleanupButton.title = "Run Cleanup"
        cleanupButton.bezelStyle = .rounded
        cleanupButton.target = self
        cleanupButton.action = #selector(cleanupClicked)
        cleanupButton.tag = 300
        containerView.addSubview(cleanupButton)
        
        checkButton = NSButton(frame: NSRect(x: 130, y: yPos, width: 120, height: 25))
        checkButton.title = "Check Integrity"
        checkButton.bezelStyle = .rounded
        checkButton.target = self
        checkButton.action = #selector(checkClicked)
        checkButton.tag = 300
        containerView.addSubview(checkButton)
        
        let helpLabel = NSTextField(wrappingLabelWithString: "Cleanup removes orphaned data. Check verifies database integrity.")
        helpLabel.font = NSFont.systemFont(ofSize: 10)
        helpLabel.textColor = .tertiaryLabelColor
        helpLabel.frame = NSRect(x: 20, y: yPos - 35, width: 400, height: 30)
        helpLabel.tag = 300
        containerView.addSubview(helpLabel)
    }
    
    private func createStatLabel(y: Int, tag: Int) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.frame = NSRect(x: 40, y: y, width: 300, height: 18)
        label.tag = tag
        containerView.addSubview(label)
        return label
    }
    
    // MARK: - Notifications
    
    private func setupNotifications() {
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .speakerDataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateUI()
        }
    }
    
    // MARK: - Actions
    
    @objc private func segmentChanged() {
        showSegment(segmentedControl.selectedSegment)
    }
    
    private func showSegment(_ index: Int) {
        // Hide all tagged subviews
        for view in containerView.subviews {
            view.isHidden = true
        }
        
        // Show views for selected segment
        let tag = (index + 1) * 100 // 100=pending, 200=speakers, 300=stats
        for view in containerView.subviews {
            if view.tag == tag {
                view.isHidden = false
            }
        }
    }
    
    @objc private func refreshClicked() {
        loadData()
    }
    
    @objc private func confirmClicked() {
        let row = pendingTableView.selectedRow
        guard row >= 0 && row < service.pendingSuggestions.count else { return }
        
        let suggestion = service.pendingSuggestions[row]
        
        let alert = NSAlert()
        alert.messageText = "Confirm Name Suggestion?"
        alert.informativeText = "Apply name '\(suggestion.suggestedName)' to speaker '\(suggestion.speakerId)'?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Confirm")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            setLoading(true)
            service.confirmSuggestion(suggestion) { [weak self] result in
                DispatchQueue.main.async {
                    self?.setLoading(false)
                    if case .failure(let error) = result {
                        self?.showError("Failed to confirm: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    @objc private func rejectClicked() {
        let row = pendingTableView.selectedRow
        guard row >= 0 && row < service.pendingSuggestions.count else { return }
        
        let suggestion = service.pendingSuggestions[row]
        
        let alert = NSAlert()
        alert.messageText = "Reject Name Suggestion?"
        alert.informativeText = "Reject suggestion '\(suggestion.suggestedName)' for speaker '\(suggestion.speakerId)'?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reject")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            setLoading(true)
            service.rejectSuggestion(suggestion) { [weak self] result in
                DispatchQueue.main.async {
                    self?.setLoading(false)
                    if case .failure(let error) = result {
                        self?.showError("Failed to reject: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    @objc private func renameClicked() {
        let row = speakersTableView.selectedRow
        guard row >= 0 && row < filteredSpeakers.count else { return }
        
        let speaker = filteredSpeakers[row]
        
        let alert = NSAlert()
        alert.messageText = "Rename Speaker"
        alert.informativeText = "Enter a new name for speaker '\(speaker.displayName)':"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = speaker.name ?? ""
        textField.placeholderString = "Enter name"
        alert.accessoryView = textField
        
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = textField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !newName.isEmpty else {
                showError("Name cannot be empty")
                return
            }
            
            setLoading(true)
            service.renameSpeaker(speaker, to: newName) { [weak self] result in
                DispatchQueue.main.async {
                    self?.setLoading(false)
                    if case .failure(let error) = result {
                        self?.showError("Failed to rename: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    @objc private func mergeClicked() {
        let selectedRows = speakersTableView.selectedRowIndexes
        guard selectedRows.count == 2 else {
            showError("Select exactly 2 speakers to merge")
            return
        }
        
        let indices = Array(selectedRows)
        guard indices[0] < filteredSpeakers.count && indices[1] < filteredSpeakers.count else { return }
        
        let speaker1 = filteredSpeakers[indices[0]]
        let speaker2 = filteredSpeakers[indices[1]]
        
        let alert = NSAlert()
        alert.messageText = "Merge Speakers"
        alert.informativeText = "Which speaker should be kept? The other speaker's embeddings will be transferred."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep \(speaker1.displayName)")
        alert.addButton(withTitle: "Keep \(speaker2.displayName)")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        var keepSpeaker: Speaker
        var mergeSpeaker: Speaker
        
        switch response {
        case .alertFirstButtonReturn:
            keepSpeaker = speaker1
            mergeSpeaker = speaker2
        case .alertSecondButtonReturn:
            keepSpeaker = speaker2
            mergeSpeaker = speaker1
        default:
            return
        }
        
        setLoading(true)
        service.mergeSpeakers(keep: keepSpeaker, merge: mergeSpeaker) { [weak self] result in
            DispatchQueue.main.async {
                self?.setLoading(false)
                switch result {
                case .success(let response):
                    self?.showInfo("Merged \(response.embeddingsTransferred ?? 0) embeddings")
                case .failure(let error):
                    self?.showError("Failed to merge: \(error.localizedDescription)")
                }
            }
        }
    }
    
    @objc private func splitClicked() {
        let row = speakersTableView.selectedRow
        guard row >= 0 && row < filteredSpeakers.count else { return }
        
        let speaker = filteredSpeakers[row]
        
        // Fetch detail to get embeddings
        setLoading(true)
        service.getSpeakerDetail(speaker.id) { [weak self] result in
            DispatchQueue.main.async {
                self?.setLoading(false)
                switch result {
                case .success(let detail):
                    self?.showSplitDialog(speaker: speaker, detail: detail)
                case .failure(let error):
                    self?.showError("Failed to load speaker details: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func showSplitDialog(speaker: Speaker, detail: SpeakerDetail) {
        guard detail.embeddings.count > 1 else {
            showError("Speaker has only 1 embedding and cannot be split")
            return
        }
        
        let alert = NSAlert()
        alert.messageText = "Split Speaker"
        alert.informativeText = "Select embeddings to move to a new speaker.\n\nSpeaker '\(speaker.displayName)' has \(detail.embeddings.count) embeddings."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Split")
        alert.addButton(withTitle: "Cancel")
        
        // Create a table to select embeddings
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 150))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        
        let tableView = NSTableView(frame: scrollView.bounds)
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = 20
        
        let sourceCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sourceCol.title = "Audio Source"
        sourceCol.width = 200
        tableView.addTableColumn(sourceCol)
        
        let qualityCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("quality"))
        qualityCol.title = "Quality"
        qualityCol.width = 60
        tableView.addTableColumn(qualityCol)
        
        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateCol.title = "Created"
        dateCol.width = 120
        tableView.addTableColumn(dateCol)
        
        // Simple data source using a helper
        let dataSource = EmbeddingTableDataSource(embeddings: detail.embeddings)
        tableView.delegate = dataSource
        tableView.dataSource = dataSource
        
        scrollView.documentView = tableView
        alert.accessoryView = scrollView
        
        if alert.runModal() == .alertFirstButtonReturn {
            let selectedIndices = tableView.selectedRowIndexes
            guard !selectedIndices.isEmpty else {
                showError("No embeddings selected")
                return
            }
            guard selectedIndices.count < detail.embeddings.count else {
                showError("Cannot move all embeddings. Leave at least one.")
                return
            }
            
            let embeddingIds = selectedIndices.map { detail.embeddings[$0].embeddingId }
            
            setLoading(true)
            service.splitSpeaker(speaker, embeddingIds: embeddingIds) { [weak self] result in
                DispatchQueue.main.async {
                    self?.setLoading(false)
                    switch result {
                    case .success(let response):
                        self?.showInfo("Created new speaker '\(response.newSpeakerId)' with \(response.embeddingsMoved) embeddings")
                    case .failure(let error):
                        self?.showError("Failed to split: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    @objc private func deleteClicked() {
        let row = speakersTableView.selectedRow
        guard row >= 0 && row < filteredSpeakers.count else { return }
        
        let speaker = filteredSpeakers[row]
        
        let alert = NSAlert()
        alert.messageText = "Delete Speaker?"
        alert.informativeText = "This will permanently delete speaker '\(speaker.displayName)' and all their embeddings. This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            setLoading(true)
            service.deleteSpeaker(speaker) { [weak self] result in
                DispatchQueue.main.async {
                    self?.setLoading(false)
                    if case .failure(let error) = result {
                        self?.showError("Failed to delete: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    @objc private func speakerSearchChanged() {
        speakerSearchText = speakersSearchField.stringValue.lowercased()
        applyFilter()
        speakersTableView.reloadData()
    }
    
    @objc private func cleanupClicked() {
        let alert = NSAlert()
        alert.messageText = "Run Database Cleanup?"
        alert.informativeText = "This will remove orphaned embeddings and optimize the database. A backup will be created first."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Run Cleanup")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            setLoading(true)
            service.runCleanup { [weak self] result in
                DispatchQueue.main.async {
                    self?.setLoading(false)
                    switch result {
                case .success(let response):
                    self?.showInfo("Cleanup complete. Removed \(response.orphanedEmbeddingsRemoved) orphaned embeddings, \(response.expiredSuggestionsRemoved ?? 0) expired suggestions.")
                    case .failure(let error):
                        self?.showError("Cleanup failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    @objc private func checkClicked() {
        setLoading(true)
        service.checkIntegrity { [weak self] result in
            DispatchQueue.main.async {
                self?.setLoading(false)
                switch result {
                case .success(let response):
                    if response.isHealthy {
                        self?.showInfo("Database integrity check passed. \(response.totalChecks ?? 0) checks performed.")
                    } else {
                        let issues = response.issues.joined(separator: "\n• ")
                        self?.showError("Database issues found:\n• \(issues)")
                    }
                case .failure(let error):
                    self?.showError("Check failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Data Loading
    
    private func loadData() {
        guard service.checkCLIAvailable() else {
            statusLabel.stringValue = "Speaker CLI not available"
            statusLabel.textColor = .systemRed
            return
        }
        
        setLoading(true)
        service.refresh { [weak self] success in
            DispatchQueue.main.async {
                self?.setLoading(false)
                if success {
                    self?.updateUI()
                } else {
                    self?.statusLabel.stringValue = "Failed to load data"
                    self?.statusLabel.textColor = .systemRed
                }
            }
        }
    }
    
    private func updateUI() {
        // Update pending tab
        pendingTableView.reloadData()
        pendingCountLabel.stringValue = "\(service.pendingSuggestions.count) pending suggestions"
        updatePendingButtons()
        
        // Update segment badge
        if service.pendingCount > 0 {
            segmentedControl.setLabel("Pending (\(service.pendingCount))", forSegment: 0)
        } else {
            segmentedControl.setLabel("Pending", forSegment: 0)
        }
        
        // Update speakers tab
        applyFilter()
        speakersTableView.reloadData()
        if service.speakers.isEmpty {
            speakersCountLabel.stringValue = "Record a meeting to start building your speaker database"
            speakersCountLabel.textColor = .tertiaryLabelColor
        } else {
            speakersCountLabel.stringValue = "\(filteredSpeakers.count) of \(service.speakers.count) speakers"
            speakersCountLabel.textColor = .secondaryLabelColor
        }
        updateSpeakerButtons()
        
        // Update stats tab
        if let stats = service.stats {
            totalSpeakersLabel.stringValue = "Total Speakers: \(stats.totalSpeakers)"
            namedSpeakersLabel.stringValue = "Named Speakers: \(stats.namedSpeakers)"
            totalEmbeddingsLabel.stringValue = "Total Embeddings: \(stats.totalEmbeddings)"
            pendingStatsLabel.stringValue = "Pending Suggestions: \(stats.pendingSuggestions)"
            databaseSizeLabel.stringValue = "Database Size: \(formatBytes(stats.databaseSizeBytes))"
        }
        
        // Update status
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .none
        dateFormatter.timeStyle = .medium
        statusLabel.stringValue = "Last updated: \(dateFormatter.string(from: Date()))"
        statusLabel.textColor = .secondaryLabelColor
    }
    
    private func applyFilter() {
        if speakerSearchText.isEmpty {
            filteredSpeakers = service.speakers
        } else {
            filteredSpeakers = service.speakers.filter { speaker in
                speaker.id.lowercased().contains(speakerSearchText) ||
                (speaker.name?.lowercased().contains(speakerSearchText) ?? false)
            }
        }
    }
    
    private func updatePendingButtons() {
        let hasSelection = pendingTableView.selectedRow >= 0
        confirmButton.isEnabled = hasSelection
        rejectButton.isEnabled = hasSelection
    }
    
    private func updateSpeakerButtons() {
        let selectedCount = speakersTableView.selectedRowIndexes.count
        renameButton.isEnabled = selectedCount == 1
        mergeButton.isEnabled = selectedCount == 2
        splitButton.isEnabled = selectedCount == 1
        deleteButton.isEnabled = selectedCount == 1
    }
    
    // MARK: - Helpers
    
    private func setLoading(_ loading: Bool) {
        if loading {
            loadingIndicator.startAnimation(nil)
            loadingIndicator.isHidden = false
        } else {
            loadingIndicator.stopAnimation(nil)
            loadingIndicator.isHidden = true
        }
        refreshButton.isEnabled = !loading
    }
    
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    private func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Success"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    // MARK: - NSTableViewDataSource
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView.tag == 100 { // Pending
            return service.pendingSuggestions.count
        } else if tableView.tag == 200 { // Speakers
            return filteredSpeakers.count
        }
        return 0
    }
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let columnId = tableColumn?.identifier.rawValue else { return nil }
        
        if tableView.tag == 100 { // Pending
            guard row < service.pendingSuggestions.count else { return nil }
            let suggestion = service.pendingSuggestions[row]
            
            switch columnId {
            case "pendingSpeaker":
                return suggestion.speakerId
            case "suggestedName":
                return suggestion.suggestedName
            case "confidence":
                return String(format: "%.0f%%", suggestion.confidence * 100)
            case "source":
                return suggestion.source
            case "pendingCreated":
                return formatDate(suggestion.createdAt)
            default:
                return nil
            }
        } else if tableView.tag == 200 { // Speakers
            guard row < filteredSpeakers.count else { return nil }
            let speaker = filteredSpeakers[row]
            
            switch columnId {
            case "speakerId":
                return speaker.id
            case "speakerName":
                return speaker.name ?? "(unnamed)"
            case "embeddingCount":
                return "\(speaker.embeddingCount)"
            case "lastSeen":
                return formatDate(speaker.lastSeen)
            case "nameConfidence":
                if let conf = speaker.nameConfidence {
                    return String(format: "%.0f%%", conf * 100)
                }
                return "-"
            default:
                return nil
            }
        }
        return nil
    }
    
    // MARK: - NSTableViewDelegate
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        
        if tableView.tag == 100 {
            updatePendingButtons()
        } else if tableView.tag == 200 {
            updateSpeakerButtons()
        }
    }
    
    // MARK: - PreferencesTab Protocol
    
    override func loadConfig(_ config: AppConfiguration) {
        // Load data from service, not config
        loadData()
        resetDirtyState()
    }
    
    override func validate() -> [ValidationError] {
        // No validation needed - data is managed by external CLI
        return []
    }
    
    override func collectChanges(into config: inout AppConfiguration) {
        // No changes to collect - data is managed by external CLI
    }
}

// MARK: - Helper for embedding table in split dialog

private class EmbeddingTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let embeddings: [SpeakerEmbedding]
    
    init(embeddings: [SpeakerEmbedding]) {
        self.embeddings = embeddings
        super.init()
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
        return embeddings.count
    }
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < embeddings.count else { return nil }
        let embedding = embeddings[row]
        
        switch tableColumn?.identifier.rawValue {
        case "source":
            return embedding.audioSource ?? "(unknown)"
        case "quality":
            if let quality = embedding.qualityScore {
                return String(format: "%.2f", quality)
            }
            return "-"
        case "date":
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            return formatter.string(from: embedding.createdAt)
        default:
            return nil
        }
    }
}
