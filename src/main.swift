import Foundation
import AppKit
import ScreenCaptureKit

// Entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = DualLogger(category: "MeetingScribe")
    private var menuBarController: MenuBarController?
    private var meetingScribeService: MeetingScribeService?
    private var wasFirstRun = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let processId = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundlePath
        logger.info("MeetingScribe starting... (PID: \(processId), Path: \(bundlePath))")
        
        // Set up standard Edit menu for keyboard shortcuts (Cmd+C, Cmd+V, etc.)
        setupEditMenu()
        
        // Run first-run installer if needed
        // This handles installation from any location (DMG, Downloads, etc.)
        let needsInstall = FirstRunInstaller.needsInstallation()
        logger.info("Installation check: needsInstallation=\(needsInstall)")
        
        if needsInstall {
            logger.info("First run detected - running installer (PID: \(processId))")
            wasFirstRun = true
            
            // Run installer synchronously on first run
            // The installer will handle moving the app if needed and setting everything up
            let success = FirstRunInstaller.runInstaller()
            
            if !success {
                logger.error("Installation failed or was cancelled (PID: \(processId))")
                // Installer will have shown appropriate error messages
                NSApp.terminate(nil)
                return
            }
            
            logger.info("Installation completed successfully (PID: \(processId))")
            logger.info("LaunchAgent has been bootstrapped and will start new instance")
            
            // IMPORTANT: The installer starts a LaunchAgent which will launch another instance
            // We need to exit THIS instance immediately to avoid showing duplicate dialogs
            // The LaunchAgent instance will request permissions and show completion dialog
            logger.info("Exiting installer instance immediately (PID: \(processId)) - LaunchAgent will take over")
            
            // Use exit() instead of NSApp.terminate() to ensure immediate termination
            // NSApp.terminate() is asynchronous and may allow code to continue
            logger.info("Calling exit(0) now...")
            exit(0)
        }
        
        // This is the LaunchAgent instance (not the installer)
        logger.info("Proceeding with normal startup (LaunchAgent instance, PID: \(processId))")
        
        // Activate the app so menu bar icon appears
        NSApp.setActivationPolicy(.accessory)
        
        // Initialize menu bar
        menuBarController = MenuBarController()
        
        // Initialize and start service
        meetingScribeService = MeetingScribeService()
        
        // Link menu bar to service
        menuBarController?.onManualStart = { [weak self] in
            self?.meetingScribeService?.startManualRecording()
        }
        
        menuBarController?.onManualStop = { [weak self] in
            self?.meetingScribeService?.stopManualRecording()
        }
        
        menuBarController?.onToggleAutoRecording = { [weak self] in
            self?.meetingScribeService?.toggleAutoRecording()
        }
        
        menuBarController?.onRecheckPermissions = { [weak self] in
            self?.recheckPermissions()
        }
        
        menuBarController?.onResetPermissions = { [weak self] in
            self?.resetPermissions()
        }
        
        menuBarController?.onRequestPermissions = { [weak self] in
            self?.requestPermissions()
        }
        
        // Link service state to menu bar
        meetingScribeService?.onStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                self?.menuBarController?.updateState(state)
            }
        }
        
        meetingScribeService?.onAutoRecordingChanged = { [weak self] enabled in
            DispatchQueue.main.async {
                self?.menuBarController?.updateAutoRecordingState(enabled)
            }
        }
        
        // Check permissions and start service
        Task {
            await startWithPermissionCheck()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        logger.info("MeetingScribe terminating...")
        meetingScribeService?.stop()
    }
    
    private func setupEditMenu() {
        // Create main menu bar if it doesn't exist
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = NSMenu()
        }
        
        // Create Edit menu
        let editMenu = NSMenu(title: "Edit")
        
        // Add standard Edit menu items
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        
        // Add Edit menu to menu bar
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        NSApp.mainMenu?.addItem(editMenuItem)
    }
    
    private func startWithPermissionCheck() async {
        let processId = ProcessInfo.processInfo.processIdentifier
        logger.info("startWithPermissionCheck() called (PID: \(processId))")
        
        let permissionChecker = PermissionChecker()
        let perms = await permissionChecker.checkPermissions()
        logger.info("Permission check result: screenGranted=\(perms.screenGranted), micGranted=\(perms.micGranted)")
        
        if !perms.screenGranted {
            logger.warning("Screen recording permission not granted - entering disabled state")
            DispatchQueue.main.async { [weak self] in
                self?.menuBarController?.updateState(.disabled)
            }
            
            // Start periodic permission recheck
            startPermissionRecheckLoop()
            return
        }
        
        // Permissions OK - start service
        await meetingScribeService?.run()
        
        // If this was a first run (LaunchAgent instance), show completion dialog now
        // Check if this is shortly after installation and dialog hasn't been shown yet
        let installMarkerPath = "\(NSHomeDirectory())/.meetingscribe/.installed"
        let completionDialogShownPath = "\(NSHomeDirectory())/.meetingscribe/.completion_shown"
        logger.info("Checking if completion dialog should be shown...")
        
        // Check if we've already shown the dialog
        if FileManager.default.fileExists(atPath: completionDialogShownPath) {
            logger.info("Completion dialog already shown, skipping")
        } else if FileManager.default.fileExists(atPath: installMarkerPath) {
            if let installDate = try? FileManager.default.attributesOfItem(atPath: installMarkerPath)[.creationDate] as? Date {
                let secondsSinceInstall = Date().timeIntervalSince(installDate)
                logger.info("Install marker found, created \(secondsSinceInstall) seconds ago")
                
                // If installed in last 60 seconds, this is the first LaunchAgent launch
                if secondsSinceInstall < 60 {
                    logger.info("First LaunchAgent launch after installation (PID: \(processId)) - showing completion dialog")
                    
                    // Write flag to prevent showing dialog again
                    try? "shown".write(toFile: completionDialogShownPath, atomically: true, encoding: .utf8)
                    logger.info("Wrote completion dialog flag to \(completionDialogShownPath)")
                    
                    DispatchQueue.main.async {
                        FirstRunInstaller.showCompletionDialogPublic()
                    }
                } else {
                    logger.info("Install marker is too old (\(secondsSinceInstall)s), not showing completion dialog")
                }
            } else {
                logger.warning("Could not read install marker creation date")
            }
        } else {
            logger.info("No install marker found at \(installMarkerPath)")
        }
    }
    
    private func requestPermissions() {
        Task {
            let permissionChecker = PermissionChecker()
            logger.info("Actively requesting screen recording permission...")
            
            let granted = await permissionChecker.requestScreenRecordingPermission()
            
            if granted {
                logger.info("Permission granted! Starting service...")
                await meetingScribeService?.run()
                
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Permission Granted!"
                    alert.informativeText = "Screen Recording permission has been enabled. MeetingScribe is now active."
                    alert.alertStyle = .informational
                    alert.runModal()
                }
            } else {
                logger.warning("Permission denied or prompt dismissed")
                
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Permission Required"
                    alert.informativeText = "Screen Recording permission is required for MeetingScribe to work.\n\nYou can grant it manually in System Settings > Privacy & Security > Screen Recording."
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
    
    private func recheckPermissions() {
        Task {
            let permissionChecker = PermissionChecker()
            let perms = await permissionChecker.checkPermissions()
            
            if perms.screenGranted {
                logger.info("Permissions granted! Starting service...")
                await meetingScribeService?.run()
            } else {
                logger.warning("Permissions still not granted")
                
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Permissions Not Granted"
                    alert.informativeText = "Screen Recording permission is still not enabled. Please check System Settings."
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
    
    private func resetPermissions() {
        Task {
            let bundleID = Bundle.main.bundleIdentifier ?? "com.meetingscribe.daemon"
            logger.info("Resetting TCC permissions for \(bundleID)")
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "All", bundleID]
            
            do {
                try process.run()
                process.waitUntilExit()
                
                if process.terminationStatus == 0 {
                    logger.info("TCC permissions reset successfully")
                    
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Permissions Reset"
                        alert.informativeText = "Privacy permissions have been reset. Please grant them again in System Settings."
                        alert.alertStyle = .informational
                        alert.runModal()
                    }
                } else {
                    logger.error("Failed to reset TCC permissions (exit code: \(process.terminationStatus))")
                    
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = "Reset Failed"
                        alert.informativeText = "Could not reset permissions automatically. You may need to manually remove MeetingScribe from System Settings > Privacy & Security > Screen Recording."
                        alert.alertStyle = .warning
                        alert.runModal()
                    }
                }
            } catch {
                logger.error("Failed to run tccutil: \(error.localizedDescription)")
            }
        }
    }
    
    private func startPermissionRecheckLoop() {
        Task {
            while true {
                try? await Task.sleep(for: .seconds(30))
                
                let permissionChecker = PermissionChecker()
                let perms = await permissionChecker.checkPermissions()
                
                if perms.screenGranted {
                    logger.info("Permissions detected! Starting service...")
                    await meetingScribeService?.run()
                    break
                }
            }
        }
    }
}

// MARK: - Meeting Scribe Service

class MeetingScribeService {
    private let logger = DualLogger(category: "MeetingScribeService")
    private let config = ConfigManager.shared
    private let callDetector: HybridCallDetector
    private let permissionChecker = PermissionChecker()
    private let transcriptionService: TranscriptionService
    private let notesService: NotesGenerationService
    private let templateEngine: TemplateEngine
    private let notesPlugin: NotesPlugin
    
    private var audioCapture: StreamHandler?
    private var isRunning = false
    private var currentRecordingStartTime: Date?
    private var currentAudioFilePath: String?
    private var micPermissionGranted = false
    private var autoRecordingEnabled = true
    private var isCancelled = false
    private var configFileMonitor: DispatchSourceFileSystemObject?
    
    var onStateChanged: ((RecordingState) -> Void)?
    var onAutoRecordingChanged: ((Bool) -> Void)?
    
    init() {
        self.callDetector = HybridCallDetector(
            pollInterval: config.config.detection.pollInterval,
            debounceChecks: config.config.detection.debounceChecks
        )
        self.transcriptionService = TranscriptionService()
        self.notesService = NotesGenerationService()
        self.templateEngine = TemplateEngine()
        self.notesPlugin = BearPlugin()
        
        // Set up call detection callbacks
        callDetector.onCallStarted = { [weak self] callInfo in
            self?.handleCallStarted(callInfo)
        }
        
        callDetector.onCallEnded = { [weak self] platform in
            self?.handleCallEnded(platform)
        }
    }
    
    func run() async {
        logger.info("Service starting...")
        isRunning = true
        
        // Load auto-recording setting from config
        autoRecordingEnabled = config.config.ui.autoRecordingEnabled
        onAutoRecordingChanged?(autoRecordingEnabled)
        
        // Check permissions
        let perms = await permissionChecker.ensureScreenPermission()
        guard perms.screenGranted else {
            logger.error("Screen recording permission not granted - cannot start")
            return
        }
        
        // Check API key configuration
        if !validateAPIKeyConfiguration() {
            logger.warning("LLM provider API key not configured - entering config error state")
            onStateChanged?(.configError)
            // Start watching config file for changes
            startConfigFileWatcher()
            return
        }
        
        // Store mic permission status
        micPermissionGranted = perms.micGranted

        // Warm up notifications (so permission prompts don't happen mid-flow).
        if config.config.ui.showNotifications {
            await NotificationManager.shared.warmup()
        }
        
        // Start call detection
        await callDetector.startMonitoring()
    }
    
    func stop() {
        logger.info("Service stopping...")
        isRunning = false
        audioCapture?.stopCapture()
        stopConfigFileWatcher()
    }
    
    func startManualRecording() {
        logger.info("Manual recording started")
        let fakeCallInfo = CallInfo(
            platform: "manual",
            windowTitle: "Manual Recording",
            processId: 0,
            detectedAt: Date(),
            confidence: 1.0
        )
        handleCallStarted(fakeCallInfo)
    }
    
    func stopManualRecording() {
        logger.info("Manual recording stopped")
        handleCallEnded("manual")
    }
    
    func toggleAutoRecording() {
        autoRecordingEnabled.toggle()
        config.updateAutoRecordingEnabled(autoRecordingEnabled)
        
        logger.info("Auto-recording \(autoRecordingEnabled ? "enabled" : "disabled")")
        onAutoRecordingChanged?(autoRecordingEnabled)
        
        // If disabling and currently recording, cancel the recording
        if !autoRecordingEnabled && currentRecordingStartTime != nil {
            logger.info("Cancelling current recording due to auto-recording disable")
            cancelCurrentRecording()
        }
    }
    
    private func startConfigFileWatcher() {
        let configPath = "\(NSHomeDirectory())/.meetingscribe/config.json"
        
        let fileDescriptor = open(configPath, O_EVTONLY)
        
        if fileDescriptor == -1 {
            logger.warning("Could not open config file for monitoring")
            return
        }
        
        let queue = DispatchQueue(label: "com.meetingscribe.config-monitor")
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: queue
        )
        
        source.setEventHandler { [weak self] in
            self?.logger.info("Config file changed - rechecking API key configuration")
            
            // Reload config
            self?.config.reload()
            
            // Re-validate
            if let self = self, self.validateAPIKeyConfiguration() {
                self.logger.info("API key now configured! Starting service...")
                
                // Stop watching
                self.stopConfigFileWatcher()
                
                // Start the service
                Task {
                    await self.run()
                }
            }
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        configFileMonitor = source
        source.resume()
        
        logger.info("Started monitoring config file for changes")
    }
    
    private func stopConfigFileWatcher() {
        configFileMonitor?.cancel()
        configFileMonitor = nil
    }
    
    private func validateAPIKeyConfiguration() -> Bool {
        let llmConfig = config.config.notes.llm
        
        switch llmConfig.provider {
        case "openai":
            return !llmConfig.openai.apiKey.isEmpty
        case "anthropic":
            return !llmConfig.anthropic.apiKey.isEmpty
        case "ollama":
            // Ollama doesn't require API key
            return true
        default:
            // Unknown provider, default to anthropic validation
            return !llmConfig.anthropic.apiKey.isEmpty
        }
    }
    
    private func cancelCurrentRecording() {
        guard let startTime = currentRecordingStartTime else {
            logger.warning("No active recording to cancel")
            return
        }
        
        logger.info("Cancelling recording...")
        isCancelled = true
        
        let duration = Date().timeIntervalSince(startTime)
        
        // Update state to processing
        onStateChanged?(.processing)
        
        // Send notification
        sendNotification(title: "Recording Cancelled", body: "Processing partial transcript...")
        
        // Stop audio capture and process what we have
        Task {
            await stopAudioCaptureAndProcess(startTime: startTime, duration: duration, platform: "cancelled")
        }
        
        currentRecordingStartTime = nil
    }
    
    private func handleCallStarted(_ callInfo: CallInfo) {
        // Check if auto-recording is enabled
        if !autoRecordingEnabled {
            logger.info("Call detected but auto-recording is disabled: \(callInfo.platform)")
            return
        }
        
        logger.info("Call started: \(callInfo.platform)")
        currentRecordingStartTime = Date()
        isCancelled = false
        
        // Update state to recording
        onStateChanged?(.recording)
        
        // Send notification
        if config.config.ui.notifyOnStart {
            sendNotification(title: "Recording Started", body: "Meeting recording has begun")
        }
        
        // Start audio capture
        Task {
            await startAudioCapture(platform: callInfo.platform)
        }
    }
    
    private func handleCallEnded(_ platform: String) {
        logger.info("Call ended: \(platform)")
        
        guard let startTime = currentRecordingStartTime else {
            logger.warning("No recording start time found")
            return
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        // Update state to processing
        onStateChanged?(.processing)
        
        // Send notification
        if config.config.ui.notifyOnEnd {
            sendNotification(title: "Processing Meeting", body: "Transcribing and generating notes...")
        }
        
        // Stop audio capture and wait for it to finalize, then process
        Task {
            await stopAudioCaptureAndProcess(startTime: startTime, duration: duration, platform: platform)
        }
        
        currentRecordingStartTime = nil
    }
    
    private func processRecording(startTime: Date, duration: TimeInterval, platform: String) async {
        // Get actual audio file path from capture
        guard let audioFilePath = currentAudioFilePath else {
            logger.error("No audio file path available - cannot process recording")
            sendNotification(title: "Processing Failed", body: "No audio file was recorded")
            return
        }
        
        // Verify the audio file exists
        guard FileManager.default.fileExists(atPath: audioFilePath) else {
            logger.error("Audio file does not exist at path: \(audioFilePath)")
            sendNotification(title: "Processing Failed", body: "Audio file not found")
            return
        }
        
        logger.info("Processing audio file: \(audioFilePath)")
        
        do {
            // 1. Transcribe
            logger.info("Starting transcription...")
            let audioURL = URL(fileURLWithPath: audioFilePath)
            let transcript = try await transcriptionService.transcribe(audioFileURL: audioURL)
            logger.info("Transcription complete: \(transcript.prefix(100))...")
            
            // 2. Generate notes
            logger.info("Generating notes...")
            let generatedNotes = try await notesService.generateNotes(transcript: transcript)
            logger.info("Notes generation complete")
            
            // 3. Split notes to get summary
            let splitNotes = GeneratedNotesParser.split(generatedNotes)
            
            // 4. Generate title from transcript and summary
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            
            var meetingTitle = "Meeting Notes - \(dateFormatter.string(from: startTime))"
            if isCancelled {
                meetingTitle = "Cancelled Recording - \(dateFormatter.string(from: startTime))"
            } else {
                do {
                    logger.info("Generating meeting title...")
                    let generatedTitle = try await notesService.generateTitle(transcript: transcript, summary: splitNotes.summary)
                    if !generatedTitle.isEmpty {
                        meetingTitle = generatedTitle
                        logger.info("Generated title: \(generatedTitle)")
                    }
                } catch {
                    logger.warning("Failed to generate title, using date-based title: \(error.localizedDescription)")
                }
            }
            
            // 5. Render template
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            
            let noteData = NoteData(
                date: dateFormatter.string(from: startTime),
                time: timeFormatter.string(from: startTime),
                duration: formatDuration(duration),
                title: meetingTitle,
                summary: splitNotes.summary,
                notes: splitNotes.notes,
                transcript: transcript,
                audioFile: audioFilePath
            )
            
            let renderedNote = try templateEngine.render(noteData: noteData)
            
            // 6. Save to plugin
            logger.info("Saving notes...")
            let result = try await notesPlugin.save(note: renderedNote, title: noteData.title)
            
            logger.info("Processing complete: \(result.message)")
            sendNotification(title: "Notes Ready", body: result.message)
            
            // Reset state to idle
            onStateChanged?(.idle)
            
        } catch {
            logger.error("Failed to process recording: \(error.localizedDescription)")
            sendNotification(title: "Processing Failed", body: error.localizedDescription)
            
            // Reset state to idle on error
            onStateChanged?(.idle)
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func sendNotification(title: String, body: String) {
        guard config.config.ui.showNotifications else { return }

        Task {
            await NotificationManager.shared.send(title: title, body: body)
        }
    }
    
    // MARK: - Audio Capture Management
    
    private func startAudioCapture(platform: String) async {
        do {
            // Find the application based on platform
            guard let app = try await findApplication(for: platform) else {
                logger.error("Could not find \(platform) application")
                sendNotification(title: "Recording Failed", body: "Could not find \(platform) application")
                return
            }
            
            logger.info("Found application: \(app.applicationName) (\(app.bundleIdentifier))")
            
            // Get output directory from config
            // Note: If directory doesn't exist, StreamHandler will fall back to ~/Library/Logs/AudioCapture/recordings/
            let outputDir = config.expandPath(config.config.audio.outputDirectory)
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            
            // Create StreamHandler
            audioCapture = StreamHandler(
                application: app,
                outputDir: outputDir,
                micEnabled: micPermissionGranted
            )
            
            // Start capture
            try await audioCapture?.startCapture()
            
            // Get the actual audio file path from StreamHandler
            currentAudioFilePath = audioCapture?.mixedAudioFilePath
            
            if let path = currentAudioFilePath {
                logger.info("Audio capture started successfully, file: \(path)")
            } else {
                logger.warning("Audio capture started but file path not available")
            }
            
        } catch {
            logger.error("Failed to start audio capture: \(error.localizedDescription)")
            sendNotification(title: "Recording Failed", body: error.localizedDescription)
        }
    }
    
    private func stopAudioCaptureAndProcess(startTime: Date, duration: TimeInterval, platform: String) async {
        guard let capture = audioCapture else {
            logger.warning("No active audio capture to stop")
            return
        }
        
        logger.info("Stopping audio capture...")
        capture.stopCapture()
        
        // Wait for capture to finish and finalize the file
        await capture.waitUntilStopped()
        logger.info("Audio capture stopped and finalized")
        
        // Now process the recording
        await processRecording(startTime: startTime, duration: duration, platform: platform)
    }
    
    private func findApplication(for platform: String) async throws -> SCRunningApplication? {
        // Get shareable content to enumerate running applications
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        
        // Search for the application based on platform
        switch platform.lowercased() {
        case "teams":
            // Look for Microsoft Teams
            return content.applications.first { app in
                let bundleId = app.bundleIdentifier.lowercased()
                let appName = app.applicationName.lowercased()
                return bundleId.contains("teams") || appName.contains("teams")
            }
            
        case "zoom":
            // Look for Zoom
            return content.applications.first { app in
                let bundleId = app.bundleIdentifier.lowercased()
                let appName = app.applicationName.lowercased()
                return bundleId.contains("zoom") || appName.contains("zoom")
            }
            
        case "manual":
            // For manual recording, try to find Teams or Zoom, or use the first available app
            if let teamsApp = content.applications.first(where: { app in
                app.bundleIdentifier.lowercased().contains("teams") ||
                app.applicationName.lowercased().contains("teams")
            }) {
                return teamsApp
            }
            
            if let zoomApp = content.applications.first(where: { app in
                app.bundleIdentifier.lowercased().contains("zoom") ||
                app.applicationName.lowercased().contains("zoom")
            }) {
                return zoomApp
            }
            
            // Fallback: use any app with audio (prefer Chrome, Safari, etc.)
            return content.applications.first { app in
                let appName = app.applicationName.lowercased()
                return appName.contains("chrome") || appName.contains("safari") || appName.contains("firefox")
            }
            
        default:
            logger.warning("Unknown platform: \(platform)")
            return nil
        }
    }
}
