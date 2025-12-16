import Foundation
import ScreenCaptureKit
import AVFoundation

struct PermissionStatus: Equatable {
    let screenGranted: Bool
    let micGranted: Bool
}

class PermissionChecker {
    private let logger = DualLogger(category: "PermissionChecker")

    /// Returns current permission readiness.
    /// Note: screen recording permission is effectively checked by attempting to enumerate shareable content.
    func checkPermissions() async -> PermissionStatus {
        // 1) Screen recording (required for ScreenCaptureKit audio capture)
        logger.info("Checking screen recording permission...")
        logger.info("Process: \(ProcessInfo.processInfo.processName)")
        logger.info("Executable: \(CommandLine.arguments.first ?? "(unknown)")")
        logger.info("Bundle: \(Bundle.main.bundlePath)")

        var screenGranted = false
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false,
                                                                     onScreenWindowsOnly: false)
            screenGranted = true
            logger.info("✅ Screen recording permission granted")
        } catch {
            logger.error("❌ Screen recording permission denied or unavailable")
            logger.error("Error: \(error.localizedDescription)")

            logger.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            logger.info("PERMISSION REQUIRED")
            logger.info("Please grant screen recording permission:")
            logger.info("1. Open System Settings")
            logger.info("2. Go to Privacy & Security > Screen Recording")
            logger.info("3. Enable the checkbox next to meetingscribe")
            logger.info("4. Restart this application")
            logger.info("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        }

        // 2) Microphone (optional for this spike; required only for local track capture)
        logger.info("Checking microphone permission...")
        let micGranted = await requestMicrophoneAccessIfNeeded()
        if micGranted {
            logger.info("✅ Microphone permission granted")
        } else {
            logger.warning("⚠️ Microphone permission not granted (local track will be disabled)")
        }

        return PermissionStatus(screenGranted: screenGranted, micGranted: micGranted)
    }

    /// Convenience used by the main loop: screen recording is required to proceed.
    func ensureScreenPermission() async -> PermissionStatus {
        return await checkPermissions()
    }

    private func requestMicrophoneAccessIfNeeded() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }
}
