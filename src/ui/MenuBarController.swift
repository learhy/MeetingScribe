import AppKit

enum RecordingState {
    case disabled      // Missing required permissions
    case configError   // Missing required configuration (API keys)
    case idle
    case recording
    case processing
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
        // Unload the LaunchAgent first so it doesn't restart us
        let logger = DualLogger(category: "MenuBarController")
        logger.info("Quit requested - unloading LaunchAgent...")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/com.meetingscribe.daemon.plist"
        let domain = "gui/\(getuid())"
        process.arguments = ["bootout", domain, plistPath]
        
        do {
            try process.run()
            process.waitUntilExit()
            logger.info("LaunchAgent unloaded, quitting...")
        } catch {
            logger.error("Failed to unload LaunchAgent: \(error.localizedDescription)")
            // Quit anyway
        }
        
        NSApplication.shared.terminate(nil)
    }
    
    func updateState(_ state: RecordingState) {
        currentState = state
        updateIcon()
        updateMenuForState()
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
    
    private func updateAutoRecordingMenuItem() {
        let title = autoRecordingEnabled ? "Disable Auto Recording" : "Enable Auto Recording"
        
        for item in menu.items {
            if item.title.contains("Auto Recording") {
                item.title = title
                break
            }
        }
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
        
        let quitItem = NSMenuItem(title: "Quit MeetingScribe", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    private func buildConfigErrorMenu() {
        menu.removeAllItems()
        
        let configItem = NSMenuItem(title: "⚠️  LLM Provider Key Required", action: #selector(openConfigFolder), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let prefsItem = NSMenuItem(title: "Open Configuration Folder", action: #selector(openConfigFolder), keyEquivalent: "")
        prefsItem.target = self
        menu.addItem(prefsItem)
        
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
