import AppKit

class GeneralTab: BasePreferencesTab {
    override var tabName: String { "General" }
    
    private var showNotificationsCheckbox: NSButton!
    private var notifyOnStartCheckbox: NSButton!
    private var notifyOnEndCheckbox: NSButton!
    private var autoRecordingCheckbox: NSButton!
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }
    
    private func setupUI() {
        // Title
        let titleLabel = NSTextField(labelWithString: "UI Preferences")
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.frame = NSRect(x: 20, y: 380, width: 560, height: 20)
        addSubview(titleLabel)
        
        // Show Notifications (master toggle)
        showNotificationsCheckbox = NSButton(checkboxWithTitle: "Show Notifications", target: self, action: #selector(showNotificationsChanged))
        showNotificationsCheckbox.frame = NSRect(x: 20, y: 350, width: 560, height: 20)
        addSubview(showNotificationsCheckbox)
        
        // Notify on Start (indented, dependent)
        notifyOnStartCheckbox = NSButton(checkboxWithTitle: "Notify on Recording Start", target: self, action: #selector(checkboxChanged))
        notifyOnStartCheckbox.frame = NSRect(x: 40, y: 320, width: 540, height: 20)
        addSubview(notifyOnStartCheckbox)
        
        // Notify on End (indented, dependent)
        notifyOnEndCheckbox = NSButton(checkboxWithTitle: "Notify on Recording End", target: self, action: #selector(checkboxChanged))
        notifyOnEndCheckbox.frame = NSRect(x: 40, y: 290, width: 540, height: 20)
        addSubview(notifyOnEndCheckbox)
        
        // Spacer
        let separatorLine = NSBox(frame: NSRect(x: 20, y: 260, width: 560, height: 1))
        separatorLine.boxType = .separator
        addSubview(separatorLine)
        
        // Auto-Recording Enabled
        autoRecordingCheckbox = NSButton(checkboxWithTitle: "Auto-Recording Enabled", target: self, action: #selector(checkboxChanged))
        autoRecordingCheckbox.frame = NSRect(x: 20, y: 230, width: 560, height: 20)
        addSubview(autoRecordingCheckbox)
        
        // Help text
        let helpLabel = NSTextField(wrappingLabelWithString: "When disabled, MeetingScribe will only record when you manually start recording from the menu bar.")
        helpLabel.font = NSFont.systemFont(ofSize: 10)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.frame = NSRect(x: 40, y: 200, width: 540, height: 30)
        addSubview(helpLabel)
    }
    
    @objc private func showNotificationsChanged() {
        markDirty()
        updateDependentControls()
    }
    
    @objc private func checkboxChanged() {
        markDirty()
    }
    
    private func updateDependentControls() {
        let enabled = showNotificationsCheckbox.state == .on
        notifyOnStartCheckbox.isEnabled = enabled
        notifyOnEndCheckbox.isEnabled = enabled
    }
    
    override func loadConfig(_ config: AppConfiguration) {
        showNotificationsCheckbox.state = config.ui.showNotifications ? .on : .off
        notifyOnStartCheckbox.state = config.ui.notifyOnStart ? .on : .off
        notifyOnEndCheckbox.state = config.ui.notifyOnEnd ? .on : .off
        autoRecordingCheckbox.state = config.ui.autoRecordingEnabled ? .on : .off
        
        updateDependentControls()
        resetDirtyState()
    }
    
    override func validate() -> [ValidationError] {
        // No validation needed - all boolean values
        return []
    }
    
    override func collectChanges(into config: inout AppConfiguration) {
        config.ui.showNotifications = (showNotificationsCheckbox.state == .on)
        config.ui.notifyOnStart = (notifyOnStartCheckbox.state == .on)
        config.ui.notifyOnEnd = (notifyOnEndCheckbox.state == .on)
        config.ui.autoRecordingEnabled = (autoRecordingCheckbox.state == .on)
    }
}
