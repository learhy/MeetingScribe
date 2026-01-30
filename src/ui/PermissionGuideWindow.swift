import AppKit

class PermissionGuideWindow: NSWindow {
    private let logger = DualLogger(category: "PermissionGuide")
    
    var onRecheck: (() -> Void)?
    var onReset: (() -> Void)?
    var onRequest: (() -> Void)?
    
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
        
        Option 1 - Request Permission (Recommended):
        1. Click "Request Permission" below
        2. Click "OK" in the system prompt that appears
        3. If it says restart required, click "Recheck" after restarting
        
        Option 2 - Manual Setup:
        1. Click "Open System Settings"
        2. Find "MeetingScribe" and enable the checkbox
        3. Click "Recheck Permissions"
        """
        
        let instructionsLabel = NSTextField(wrappingLabelWithString: instructions)
        instructionsLabel.frame = NSRect(x: 20, y: 80, width: 380, height: 130)
        instructionsLabel.font = NSFont.systemFont(ofSize: 12)
        instructionsLabel.alignment = .left
        contentView.addSubview(instructionsLabel)
        
        // Request Permission button (primary action)
        let requestButton = NSButton(frame: NSRect(x: 20, y: 40, width: 160, height: 32))
        requestButton.title = "Request Permission"
        requestButton.bezelStyle = .rounded
        requestButton.keyEquivalent = "\r"
        requestButton.target = self
        requestButton.action = #selector(requestPermission)
        contentView.addSubview(requestButton)
        
        // Open System Settings button
        let openSettingsButton = NSButton(frame: NSRect(x: 190, y: 40, width: 100, height: 32))
        openSettingsButton.title = "Settings..."
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openSettings)
        contentView.addSubview(openSettingsButton)
        
        // Recheck button
        let recheckButton = NSButton(frame: NSRect(x: 300, y: 40, width: 90, height: 32))
        recheckButton.title = "Recheck"
        recheckButton.bezelStyle = .rounded
        recheckButton.target = self
        recheckButton.action = #selector(recheck)
        contentView.addSubview(recheckButton)
        
        // Quit button
        let quitButton = NSButton(frame: NSRect(x: 20, y: 8, width: 60, height: 24))
        quitButton.title = "Quit"
        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quit)
        contentView.addSubview(quitButton)
        
        self.contentView = contentView
    }
    
    @objc private func requestPermission() {
        logger.info("Requesting permission (will trigger system prompt)...")
        onRequest?()
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
    
    
    @objc private func quit() {
        logger.info("User clicked Quit - unloading LaunchAgent to prevent restart")
        LaunchAgentManager.quitApplication()
    }
    
    func show() {
        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
