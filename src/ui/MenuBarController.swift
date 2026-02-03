import AppKit

enum RecordingState {
    case disabled      // Missing required permissions
    case configError   // Missing required configuration (API keys)
    case idle
    case recording
    case processing
}

// New composite state model for Phase 1
struct MenuBarState {
    enum SystemStatus {
        case normal
        case disabled
        case configError
    }
    
    let systemStatus: SystemStatus
    let isRecording: Bool
    let processingCount: Int
}

class MenuBarController {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private var permissionGuide: PermissionGuideWindow?
    
    var onManualStart: (() -> Void)?
    var onManualStop: (() -> Void)?
    var onToggleAutoRecording: (() -> Void)?
    var onRecheckPermissions: (() -> Void)?
    var onResetPermissions: (() -> Void)?
    var onRequestPermissions: (() -> Void)?
    
    private var isRecording = false
    private var currentState: RecordingState = .idle
    private var currentMenuBarState: MenuBarState = MenuBarState(systemStatus: .normal, isRecording: false, processingCount: 0)
    private var autoRecordingEnabled = true
    
    init() {
        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "message.circle", accessibilityDescription: "MeetingScribe")
        }
        
        // Create menu
        menu = NSMenu()
        
        let startItem = NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)
        
        let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        stopItem.target = self
        stopItem.isHidden = true
        menu.addItem(stopItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let toggleAutoItem = NSMenuItem(title: "Disable Auto Recording", action: #selector(toggleAutoRecording), keyEquivalent: "")
        toggleAutoItem.target = self
        menu.addItem(toggleAutoItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit MeetingScribe", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
    }
    
    @objc private func startRecording() {
        isRecording = true
        updateMenuState()
        onManualStart?()
    }
    
    @objc private func stopRecording() {
        isRecording = false
        updateMenuState()
        onManualStop?()
    }
    
    @objc private func toggleAutoRecording() {
        onToggleAutoRecording?()
    }
    
    @objc private func openPreferences() {
        PreferencesWindowController.show()
    }
    
    @objc private func quit() {
        LaunchAgentManager.quitApplication()
    }
    
    func updateState(_ state: RecordingState) {
        currentState = state
        updateIcon()
        updateMenuForState()
    }
    
    func updateState(_ state: MenuBarState) {
        currentMenuBarState = state
        updateIconFromMenuBarState()
        updateMenuFromMenuBarState()
    }
    
    func updateAutoRecordingState(_ enabled: Bool) {
        autoRecordingEnabled = enabled
        updateAutoRecordingMenuItem()
    }
    
    private func updateMenuState() {
        guard let startItem = menu.item(withTitle: "Start Recording"),
              let stopItem = menu.item(withTitle: "Stop Recording") else {
            return
        }
        
        startItem.isHidden = isRecording
        stopItem.isHidden = !isRecording
        updateIcon()
    }
    
    private func updateIcon() {
        guard let button = statusItem.button else { return }
        
        let symbolName: String
        let color: NSColor
        
        switch currentState {
        case .disabled:
            symbolName = "exclamationmark.triangle.fill"
            color = .systemRed
        case .configError:
            symbolName = "exclamationmark.triangle.fill"
            color = .systemOrange
        case .idle:
            symbolName = isRecording ? "message.circle.fill" : "message.circle"
            color = .controlTextColor  // System default (transparent)
        case .recording:
            symbolName = "message.circle.fill"
            color = .systemRed
        case .processing:
            symbolName = "message.circle.fill"
            color = .systemOrange
        }
        
        let config = NSImage.SymbolConfiguration(pointSize: 0, weight: .regular)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MeetingScribe")?
            .withSymbolConfiguration(config)
        
        button.image = image
        button.contentTintColor = color
    }
    
    private func updateIconFromMenuBarState() {
        guard let button = statusItem.button else { return }
        
        // Use text-based indicators since contentTintColor is broken on macOS 11+
        // and colored images don't follow macOS design guidelines
        switch currentMenuBarState.systemStatus {
        case .disabled:
            button.image = nil
            button.title = "⚠️"
        case .configError:
            button.image = nil  
            button.title = "⚠️"
        case .normal:
            button.image = nil
            // Recording takes precedence over processing for icon color
            if currentMenuBarState.isRecording {
                button.title = "🔴"  // Red circle for recording
            } else if currentMenuBarState.processingCount > 0 {
                button.title = "🟠"  // Orange circle for processing
            } else {
                // Use SF Symbol for idle state
                let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                if let image = NSImage(systemSymbolName: "message.circle", accessibilityDescription: "MeetingScribe")?
                    .withSymbolConfiguration(config) {
                    image.isTemplate = true
                    button.image = image
                    button.title = ""
                }
            }
        }
    }
    
    private func updateAutoRecordingMenuItem() {
        let title = autoRecordingEnabled ? "Disable Auto Recording" : "Enable Auto Recording"
        
        for item in menu.items {
            if item.title.contains("Auto Recording") {
                item.title = title
                break
            }
        }
    }
    
    private func updateMenuFromMenuBarState() {
        // Show different menu based on system status
        switch currentMenuBarState.systemStatus {
        case .disabled:
            buildDisabledMenu()
        case .configError:
            buildConfigErrorMenu()
        case .normal:
            buildNormalMenuWithState()
        }
    }
    
    private func updateStatusMenuItem() {
        // Find the status menu item (should be second from last, before Quit)
        let statusIndex = menu.items.count - 2
        guard statusIndex >= 0 && statusIndex < menu.items.count else { return }
        
        let statusItem = menu.items[statusIndex]
        
        // Build status text
        let statusText: String
        if currentMenuBarState.isRecording && currentMenuBarState.processingCount > 0 {
            statusText = "Status: Recording + Processing \(currentMenuBarState.processingCount)"
        } else if currentMenuBarState.isRecording {
            statusText = "Status: Recording"
        } else if currentMenuBarState.processingCount > 0 {
            let meetingText = currentMenuBarState.processingCount == 1 ? "meeting" : "meetings"
            statusText = "Status: Processing \(currentMenuBarState.processingCount) \(meetingText)"
        } else {
            statusText = "Status: Waiting"
        }
        
        statusItem.title = statusText
    }
    
    private func updateMenuForState() {
        // Show different menu based on state
        switch currentState {
        case .disabled:
            buildDisabledMenu()
        case .configError:
            buildConfigErrorMenu()
        default:
            buildNormalMenu()
        }
    }
    
    private func buildDisabledMenu() {
        menu.removeAllItems()
        
        let grantItem = NSMenuItem(title: "⚠️  Grant Permissions...", action: #selector(showPermissionGuide), keyEquivalent: "")
        grantItem.target = self
        menu.addItem(grantItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let recheckItem = NSMenuItem(title: "Recheck Permissions", action: #selector(recheckPermissions), keyEquivalent: "")
        recheckItem.target = self
        menu.addItem(recheckItem)
        
        let resetItem = NSMenuItem(title: "Reset Permissions...", action: #selector(resetPermissions), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit MeetingScribe", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    private func buildConfigErrorMenu() {
        menu.removeAllItems()
        
        let configItem = NSMenuItem(title: "⚠️  LLM Provider Key Required", action: nil, keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        
        let openConfigItem = NSMenuItem(title: "Open Configuration Folder", action: #selector(openConfigFolder), keyEquivalent: "")
        openConfigItem.target = self
        menu.addItem(openConfigItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit MeetingScribe", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    private func buildNormalMenu() {
        menu.removeAllItems()
        
        let startItem = NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "")
        startItem.target = self
        startItem.isHidden = isRecording
        menu.addItem(startItem)
        
        let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        stopItem.target = self
        stopItem.isHidden = !isRecording
        menu.addItem(stopItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let toggleAutoTitle = autoRecordingEnabled ? "Disable Auto Recording" : "Enable Auto Recording"
        let toggleAutoItem = NSMenuItem(title: toggleAutoTitle, action: #selector(toggleAutoRecording), keyEquivalent: "")
        toggleAutoItem.target = self
        menu.addItem(toggleAutoItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit MeetingScribe", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    private func buildNormalMenuWithState() {
        menu.removeAllItems()
        
        let startItem = NSMenuItem(title: "Start Recording", action: #selector(startRecording), keyEquivalent: "")
        startItem.target = self
        startItem.isHidden = currentMenuBarState.isRecording
        menu.addItem(startItem)
        
        let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(stopRecording), keyEquivalent: "")
        stopItem.target = self
        stopItem.isHidden = !currentMenuBarState.isRecording
        menu.addItem(stopItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let toggleAutoTitle = autoRecordingEnabled ? "Disable Auto Recording" : "Enable Auto Recording"
        let toggleAutoItem = NSMenuItem(title: toggleAutoTitle, action: #selector(toggleAutoRecording), keyEquivalent: "")
        toggleAutoItem.target = self
        menu.addItem(toggleAutoItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Add status menu item (non-clickable, grayed out)
        let statusItem = NSMenuItem(title: "Status: Waiting", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        
        let quitItem = NSMenuItem(title: "Quit MeetingScribe", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        // Update status text based on current state
        updateStatusMenuItem()
    }
    
    @objc private func showPermissionGuide() {
        if permissionGuide == nil {
            permissionGuide = PermissionGuideWindow()
            permissionGuide?.onRecheck = { [weak self] in
                self?.onRecheckPermissions?()
            }
            permissionGuide?.onReset = { [weak self] in
                self?.onResetPermissions?()
            }
            permissionGuide?.onRequest = { [weak self] in
                self?.onRequestPermissions?()
            }
        }
        permissionGuide?.show()
    }
    
    @objc private func recheckPermissions() {
        onRecheckPermissions?()
    }
    
    @objc private func resetPermissions() {
        onResetPermissions?()
    }
    
    @objc private func openConfigFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.meetingscribe"))
    }
}
