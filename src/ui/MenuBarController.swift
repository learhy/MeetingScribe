import AppKit

enum RecordingState {
    case idle
    case recording
    case processing
}

class MenuBarController {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    
    var onManualStart: (() -> Void)?
    var onManualStop: (() -> Void)?
    var onToggleAutoRecording: (() -> Void)?
    
    private var isRecording = false
    private var currentState: RecordingState = .idle
    private var autoRecordingEnabled = true
    
    init() {
        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "MeetingScribe")
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
        // TODO: Open preferences window
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.meetingscribe"))
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    func updateState(_ state: RecordingState) {
        currentState = state
        updateIcon()
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
        case .idle:
            symbolName = isRecording ? "mic.circle.fill" : "mic.circle"
            color = .controlTextColor  // System default (transparent)
        case .recording:
            symbolName = "mic.circle.fill"
            color = .systemRed
        case .processing:
            symbolName = "mic.circle.fill"
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
}
