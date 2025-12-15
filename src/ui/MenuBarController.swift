import AppKit

class MenuBarController {
    private let statusItem: NSStatusItem
    private let menu: NSMenu
    
    var onManualStart: (() -> Void)?
    var onManualStop: (() -> Void)?
    
    private var isRecording = false
    
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
    
    @objc private func openPreferences() {
        // TODO: Open preferences window
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.meetingscribe"))
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    private func updateMenuState() {
        guard let startItem = menu.item(withTitle: "Start Recording"),
              let stopItem = menu.item(withTitle: "Stop Recording") else {
            return
        }
        
        startItem.isHidden = isRecording
        stopItem.isHidden = !isRecording
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: isRecording ? "mic.circle.fill" : "mic.circle", 
                                 accessibilityDescription: "MeetingScribe")
        }
    }
}
