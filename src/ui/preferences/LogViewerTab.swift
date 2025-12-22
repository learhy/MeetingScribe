import AppKit

class LogViewerTab: BasePreferencesTab {
    override var tabName: String { "Logs" }
    
    private var scrollView: NSScrollView!
    private var textView: NSTextView!
    private var searchField: NSTextField!
    private var autoScrollCheckbox: NSButton!
    private var clearButton: NSButton!
    private var refreshButton: NSButton!
    
    private var logPath: String = ""
    private var updateTimer: Timer?
    private var lastFileSize: UInt64 = 0
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    deinit {
        updateTimer?.invalidate()
    }
    
    private func setupUI() {
        var yPos = 400
        
        // Control bar
        searchField = NSTextField(frame: NSRect(x: 20, y: yPos, width: 200, height: 22))
        searchField.placeholderString = "Search logs..."
        searchField.target = self
        searchField.action = #selector(searchChanged)
        addSubview(searchField)
        
        autoScrollCheckbox = NSButton(checkboxWithTitle: "Auto-scroll", target: self, action: #selector(autoScrollToggled))
        autoScrollCheckbox.frame = NSRect(x: 230, y: yPos, width: 100, height: 22)
        autoScrollCheckbox.state = .on
        addSubview(autoScrollCheckbox)
        
        clearButton = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        clearButton.frame = NSRect(x: 460, y: yPos - 2, width: 55, height: 25)
        clearButton.bezelStyle = .rounded
        addSubview(clearButton)
        
        refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshLog))
        refreshButton.frame = NSRect(x: 520, y: yPos - 2, width: 60, height: 25)
        refreshButton.bezelStyle = .rounded
        addSubview(refreshButton)
        yPos -= 30
        
        // Log viewer
        scrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 560, height: yPos - 20))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .bezelBorder
        
        textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.autoresizingMask = [.width]
        
        scrollView.documentView = textView
        addSubview(scrollView)
    }
    
    override func loadConfig(_ config: AppConfiguration) {
        // Determine log path from config
        // Logs are typically in ~/Library/Logs/MeetingScribe/stderr.log
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MeetingScribe")
        logPath = logsDir.appendingPathComponent("stderr.log").path
        
        loadLogFile()
        startAutoRefresh()
        
        resetDirtyState()
    }
    
    private func loadLogFile() {
        guard !logPath.isEmpty else {
            textView.string = "Log file path not configured"
            return
        }
        
        let expandedPath = (logPath as NSString).expandingTildeInPath
        
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            textView.string = "Log file not found: \(logPath)"
            return
        }
        
        do {
            // Get file size
            let attrs = try FileManager.default.attributesOfItem(atPath: expandedPath)
            let fileSize = attrs[.size] as? UInt64 ?? 0
            
            // Read file (tail last 50KB for performance)
            let file = FileHandle(forReadingAtPath: expandedPath)
            if let file = file {
                defer { file.closeFile() }
                
                if fileSize > 51200 { // 50KB
                    file.seek(toFileOffset: fileSize - 51200)
                    // Skip partial line
                    _ = file.readLine()
                }
                
                if let data = try file.readToEnd(),
                   let content = String(data: data, encoding: .utf8) {
                    updateTextView(with: content)
                    lastFileSize = fileSize
                }
            }
        } catch {
            textView.string = "Error reading log: \(error.localizedDescription)"
        }
    }
    
    private func updateTextView(with content: String) {
        let searchTerm = searchField.stringValue
        
        if searchTerm.isEmpty {
            textView.string = colorizeLog(content)
        } else {
            // Filter lines containing search term
            let lines = content.components(separatedBy: .newlines)
            let filtered = lines.filter { $0.localizedCaseInsensitiveContains(searchTerm) }
            textView.string = colorizeLog(filtered.joined(separator: "\n"))
        }
        
        if autoScrollCheckbox.state == .on {
            scrollToBottom()
        }
    }
    
    private func colorizeLog(_ content: String) -> String {
        // For now, return plain text
        // Future enhancement: Use NSAttributedString for colored log levels
        return content
    }
    
    private func scrollToBottom() {
        textView.scrollToEndOfDocument(nil)
    }
    
    private func startAutoRefresh() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
    }
    
    private func checkForUpdates() {
        guard !logPath.isEmpty else { return }
        
        let expandedPath = (logPath as NSString).expandingTildeInPath
        
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: expandedPath)
            let fileSize = attrs[.size] as? UInt64 ?? 0
            
            if fileSize != lastFileSize {
                loadLogFile()
            }
        } catch {
            // File might not exist yet, ignore
        }
    }
    
    @objc private func searchChanged() {
        loadLogFile()
    }
    
    @objc private func autoScrollToggled() {
        if autoScrollCheckbox.state == .on {
            scrollToBottom()
        }
    }
    
    @objc private func clearLog() {
        let alert = NSAlert()
        alert.messageText = "Clear Log File"
        alert.informativeText = "Are you sure you want to clear the log file? This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        
        if let window = self.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.performClearLog()
                }
            }
        }
    }
    
    private func performClearLog() {
        guard !logPath.isEmpty else { return }
        
        let expandedPath = (logPath as NSString).expandingTildeInPath
        
        do {
            try "".write(toFile: expandedPath, atomically: true, encoding: .utf8)
            textView.string = ""
            lastFileSize = 0
        } catch {
            let alert = NSAlert()
            alert.messageText = "Clear Failed"
            alert.informativeText = "Failed to clear log: \(error.localizedDescription)"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            if let window = self.window {
                alert.beginSheetModal(for: window)
            }
        }
    }
    
    @objc private func refreshLog() {
        loadLogFile()
    }
    
    override func validate() -> [ValidationError] {
        return []
    }
    
    override func collectChanges(into config: inout AppConfiguration) {
        // No config changes for log viewer
    }
}

// MARK: - FileHandle Extension
extension FileHandle {
    func readLine() -> String? {
        var lineData = Data()
        let char = Data(count: 1)
        
        while (try? read(upToCount: 1)) == char {
            if char[0] == 0x0A { // newline
                break
            }
            lineData.append(char[0])
        }
        
        return lineData.isEmpty ? nil : String(data: lineData, encoding: .utf8)
    }
}
