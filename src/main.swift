import Foundation
import AppKit

@main
struct MeetingScribe {
    static func main() async {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = DualLogger(category: "MeetingScribe")
    private var menuBarController: MenuBarController?
    private var meetingScribeService: MeetingScribeService?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("MeetingScribe starting...")
        
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
        
        // Start the service
        Task {
            await meetingScribeService?.run()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        logger.info("MeetingScribe terminating...")
        meetingScribeService?.stop()
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
        
        // Check permissions
        let perms = await permissionChecker.ensureScreenPermission()
        guard perms.screenGranted else {
            logger.error("Screen recording permission not granted - cannot start")
            return
        }
        
        // Start call detection
        await callDetector.startMonitoring()
    }
    
    func stop() {
        logger.info("Service stopping...")
        isRunning = false
        audioCapture?.stopCapture()
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
    
    private func handleCallStarted(_ callInfo: CallInfo) {
        logger.info("Call started: \(callInfo.platform)")
        currentRecordingStartTime = Date()
        
        // Send notification
        if config.config.ui.notifyOnStart {
            sendNotification(title: "Recording Started", body: "Meeting recording has begun")
        }
        
        // TODO: Start audio capture
        // This would require finding the Teams/Zoom application
        // For now, log placeholder
        logger.info("Audio capture would start here")
    }
    
    private func handleCallEnded(_ platform: String) {
        logger.info("Call ended: \(platform)")
        
        guard let startTime = currentRecordingStartTime else {
            logger.warning("No recording start time found")
            return
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        // Send notification
        if config.config.ui.notifyOnEnd {
            sendNotification(title: "Processing Meeting", body: "Transcribing and generating notes...")
        }
        
        // Process recording asynchronously
        Task {
            await processRecording(startTime: startTime, duration: duration, platform: platform)
        }
        
        currentRecordingStartTime = nil
    }
    
    private func processRecording(startTime: Date, duration: TimeInterval, platform: String) async {
        // TODO: Get actual audio file path from audio capture
        // For now, use placeholder
        let audioFilePath = "~/Documents/MeetingScribe/recordings/meeting_placeholder.wav"
        
        do {
            // 1. Transcribe
            logger.info("Starting transcription...")
            let audioURL = URL(fileURLWithPath: (audioFilePath as NSString).expandingTildeInPath)
            // let transcript = try await transcriptionService.transcribe(audioFileURL: audioURL)
            let transcript = "Placeholder transcript"  // Placeholder for demo
            
            // 2. Generate notes
            logger.info("Generating notes...")
            // let generatedNotes = try await notesService.generateNotes(transcript: transcript)
            let generatedNotes = "Placeholder meeting notes"  // Placeholder for demo
            
            // 3. Render template
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .short
            
            let noteData = NoteData(
                date: dateFormatter.string(from: startTime),
                time: timeFormatter.string(from: startTime),
                duration: formatDuration(duration),
                title: "Meeting Notes - \(dateFormatter.string(from: startTime))",
                summary: generatedNotes,
                notes: generatedNotes,
                transcript: transcript,
                audioFile: audioFilePath
            )
            
            let renderedNote = try templateEngine.render(noteData: noteData)
            
            // 4. Save to plugin
            logger.info("Saving notes...")
            let result = try await notesPlugin.save(note: renderedNote, title: noteData.title)
            
            logger.info("Processing complete: \(result.message)")
            sendNotification(title: "Notes Ready", body: result.message)
            
        } catch {
            logger.error("Failed to process recording: \(error.localizedDescription)")
            sendNotification(title: "Processing Failed", body: error.localizedDescription)
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func sendNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        NSUserNotificationCenter.default.deliver(notification)
    }
}
