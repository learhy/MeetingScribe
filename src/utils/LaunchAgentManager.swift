import Foundation
import AppKit

/// Manages the MeetingScribe LaunchAgent lifecycle
class LaunchAgentManager {
    private static let logger = DualLogger(category: "LaunchAgentManager")
    private static let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/com.meetingscribe.daemon.plist"
    private static let domain = "gui/\(getuid())"
    private static let label = "com.meetingscribe.daemon"
    
    /// Unloads the LaunchAgent so the app won't restart after termination.
    /// This should be called before NSApp.terminate() when the user explicitly quits.
    static func unloadLaunchAgent() {
        logger.info("Unloading LaunchAgent...")
        
        // Method 1: Try bootout with plist path
        let bootoutProcess = Process()
        bootoutProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootoutProcess.arguments = ["bootout", domain, plistPath]
        
        do {
            try bootoutProcess.run()
            bootoutProcess.waitUntilExit()
            
            if bootoutProcess.terminationStatus == 0 {
                logger.info("LaunchAgent unloaded via bootout plist")
                return
            } else {
                logger.warning("bootout plist failed with status \(bootoutProcess.terminationStatus), trying alternative methods...")
            }
        } catch {
            logger.warning("bootout plist failed: \(error.localizedDescription)")
        }
        
        // Method 2: Try bootout with service target (domain/label)
        let bootoutLabelProcess = Process()
        bootoutLabelProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootoutLabelProcess.arguments = ["bootout", "\(domain)/\(label)"]
        
        do {
            try bootoutLabelProcess.run()
            bootoutLabelProcess.waitUntilExit()
            
            if bootoutLabelProcess.terminationStatus == 0 {
                logger.info("LaunchAgent unloaded via bootout label")
                return
            } else {
                logger.warning("bootout label failed with status \(bootoutLabelProcess.terminationStatus)")
            }
        } catch {
            logger.warning("bootout label failed: \(error.localizedDescription)")
        }
        
        // Method 3: Remove the plist file to prevent reload on next login
        // This is a last resort - the service may still be running but won't restart
        logger.info("Removing plist file to prevent future restarts...")
        try? FileManager.default.removeItem(atPath: plistPath)
        logger.info("Plist file removed (if existed)")
    }
    
    /// Quits the application after unloading the LaunchAgent.
    /// Use this instead of NSApp.terminate() when the user explicitly wants to quit.
    static func quitApplication() {
        unloadLaunchAgent()
        NSApplication.shared.terminate(nil)
    }
    
    /// Checks if the LaunchAgent is currently loaded
    static func isLaunchAgentLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.contains(label)
            }
        } catch {
            logger.error("Failed to check LaunchAgent status: \(error.localizedDescription)")
        }
        
        return false
    }
}
