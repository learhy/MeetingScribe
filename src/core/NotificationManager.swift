import Foundation
import UserNotifications

actor NotificationManager {
    static let shared = NotificationManager()

    private let logger = DualLogger(category: "NotificationManager")
    private let center: UNUserNotificationCenter?
    private var didRequestAuthorization = false
    private var didLogDenied = false
    private var didLogNotGranted = false
    private var didLogUnavailable = false

    private init() {
        // UNUserNotificationCenter requires a valid app bundle.
        // When running as a daemon from /usr/local/bin, there's no bundle, so it crashes.
        // Check if we have a valid bundle before trying to access the notification center.
        if Self.hasValidBundle() {
            self.center = UNUserNotificationCenter.current()
        } else {
            self.center = nil
        }
    }

    private static func hasValidBundle() -> Bool {
        // For LaunchAgents/daemons installed to /usr/local/bin, Bundle.main points at that directory,
        // and UNUserNotificationCenter.current() can throw an Objective-C exception.
        let bundlePath = Bundle.main.bundlePath

        // “Real” app bundle (what UserNotifications expects).
        if bundlePath.contains(".app/Contents/") || bundlePath.hasSuffix(".app") {
            return true
        }

        // Common non-bundle locations (treat as not valid for UserNotifications).
        if bundlePath.hasPrefix("/usr/local/bin") || bundlePath.hasPrefix("/opt/homebrew") {
            return false
        }

        // Default to false: only enable UserNotifications when we can prove we are an app bundle.
        return false
    }

    /// Request authorization (if needed) early so the prompt doesn't appear at an awkward time.
    func warmup() async {
        guard center != nil else {
            if !didLogUnavailable {
                didLogUnavailable = true
                logger.info("Notifications unavailable (running as daemon without app bundle)")
            }
            return
        }
        _ = await ensureAuthorized()
    }

    func send(title: String, body: String) async {
        guard let center = center else {
            if !didLogUnavailable {
                didLogUnavailable = true
                logger.info("Notifications unavailable (running as daemon without app bundle)")
            }
            return
        }

        guard await ensureAuthorized() else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            logger.warning("Failed to post notification: \(error.localizedDescription)")
        }
    }

    // MARK: - Authorization

    private func ensureAuthorized() async -> Bool {
        guard let center = center else { return false }
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true

        case .denied:
            if !didLogDenied {
                didLogDenied = true
                logger.info("Notifications are denied in System Settings; skipping notification delivery")
            }
            return false

        case .notDetermined:
            // Request once per process lifetime.
            if didRequestAuthorization {
                return false
            }
            didRequestAuthorization = true

            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                if !granted, !didLogNotGranted {
                    didLogNotGranted = true
                    logger.info("Notification permission was not granted; skipping notification delivery")
                }
                return granted
            } catch {
                logger.warning("Failed to request notification authorization: \(error.localizedDescription)")
                return false
            }

        @unknown default:
            return false
        }
    }
}
