import AppKit

class PermissionGuideWindow: NSWindow {
    private let logger = DualLogger(category: "PermissionGuide")
    
    var onRecheck: (() -> Void)?
    var onReset: (() -> Void)?
    
    init() {
        // Create a floating window
        let contentRect = NSRect(x: 0, y: 0, width: 420, height: 280)
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        self.title = "MeetingScribe Permissions Required"
        self.level = .floating
        self.center()
        self.isReleasedWhenClosed = false
        
        setupUI()
    }
    
    private func setupUI() {
        let contentView = NSView(frame: self.contentView!.bounds)
        contentView.wantsLayer = true
        
        // Icon
        let iconView = NSImageView(frame: NSRect(x: 20, y: 220, width: 40, height: 40))
        iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        iconView.contentTintColor = .systemOrange
        contentView.addSubview(iconView)
        
        // Title
        let titleLabel = NSTextField(labelWithString: "Screen Recording Permission Required")
        titleLabel.frame = NSRect(x: 70, y: 225, width: 330, height: 24)
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .bold)
        contentView.addSubview(titleLabel)
        
        // Instructions
        let instructions = """
        MeetingScribe needs Screen Recording permission to capture meeting audio.
        
        To grant permission:
        
        1. Click "Open System Settings" below
        2. Find "MeetingScribe" in the list
        3. Enable the checkbox next to it
        4. Click "Recheck Permissions"
        
        If you don't see MeetingScribe in the list, try "Reset Permissions" to clear old entries.
        """
        
        let instructionsLabel = NSTextField(wrappingLabelWithString: instructions)
        instructionsLabel.frame = NSRect(x: 20, y: 80, width: 380, height: 130)
        instructionsLabel.font = NSFont.systemFont(ofSize: 12)
        instructionsLabel.alignment = .left
        contentView.addSubview(instructionsLabel)
        
        // Open System Settings button
        let openSettingsButton = NSButton(frame: NSRect(x: 20, y: 40, width: 180, height: 32))
        openSettingsButton.title = "Open System Settings"
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.keyEquivalent = "\r"
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettings)
        contentView.addSubview(openSettingsButton)
        
        // Recheck button
        let recheckButton = NSButton(frame: NSRect(x: 210, y: 40, width: 90, height: 32))
        recheckButton.title = "Recheck"
        recheckButton.bezelStyle = .rounded
        recheckButton.target = self
        recheckButton.action = #selector(recheck)
        contentView.addSubview(recheckButton)
        
        // Reset button
        let resetButton = NSButton(frame: NSRect(x: 310, y: 40, width: 90, height: 32))
        resetButton.title = "Reset..."
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(reset)
        contentView.addSubview(resetButton)
        
        // Quit button
        let quitButton = NSButton(frame: NSRect(x: 20, y: 8, width: 60, height: 24))
        quitButton.title = "Quit"
        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quit)
        contentView.addSubview(quitButton)
        
        self.contentView = contentView
    }
    
    @objc private func openSettings() {
        logger.info("Opening System Settings...")
        let permissionChecker = PermissionChecker()
        permissionChecker.openSystemSettings()
    }
    
    @objc private func recheck() {
        logger.info("Rechecking permissions...")
        onRecheck?()
    }
    
    @objc private func reset() {
        logger.info("Reset permissions requested")
        
        let alert = NSAlert()
        alert.messageText = "Reset TCC Permissions?"
        alert.informativeText = "This will clear all privacy permissions for MeetingScribe. You'll need to grant them again.\n\nNote: This only works if the app is still at the same location."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            onReset?()
        }
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    func show() {
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
