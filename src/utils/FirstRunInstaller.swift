import Foundation
import AppKit

/// Handles first-run installation when app is launched from any location
/// This ensures proper setup even if user drags from DMG and runs directly
class FirstRunInstaller {
    private static let installMarkerPath = "\(NSHomeDirectory())/.meetingscribe/.installed"
    private static let logger = DualLogger(category: "FirstRunInstaller")
    
    /// Check if the first-run installer needs to run
    static func needsInstallation() -> Bool {
        let processId = ProcessInfo.processInfo.processIdentifier
        logger.info("[PID \(processId)] needsInstallation() called")
        logger.info("[PID \(processId)] Checking for marker at: \(installMarkerPath)")
        
        // Check if installation marker exists
        if FileManager.default.fileExists(atPath: installMarkerPath) {
            logger.info("[PID \(processId)] Installation marker found")
            // Check if app location has changed
            if let installedPath = try? String(contentsOfFile: installMarkerPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
                let currentPath = Bundle.main.bundlePath
                logger.info("[PID \(processId)] Installed path: \(installedPath)")
                logger.info("[PID \(processId)] Current path: \(currentPath)")
                if installedPath != currentPath {
                    logger.info("[PID \(processId)] App location changed - installation needed")
                    return true
                }
                logger.info("[PID \(processId)] App location unchanged - no installation needed")
            }
            return false
        }
        
        logger.info("[PID \(processId)] Installation marker not found - first run detected")
        return true
    }
    
    /// Run the first-run installer script
    /// Returns true if installation completed successfully or was already done
    static func runInstaller() -> Bool {
        let processId = ProcessInfo.processInfo.processIdentifier
        logger.info("[PID \(processId)] runInstaller() called")
        
        // Check if we actually need to install
        if !needsInstallation() {
            logger.info("[PID \(processId)] Installation not needed - already installed")
            return true
        }
        
        logger.info("[PID \(processId)] Running first-run installer...")
        
        let bundlePath = Bundle.main.bundlePath
        
        // Show welcome dialog from Swift (not bash)
        let welcomeResult = showWelcomeDialog()
        if !welcomeResult {
            logger.info("User cancelled installation at welcome screen")
            return false
        }
        
        guard let resourcePath = Bundle.main.resourcePath else {
            logger.error("Could not find app resources")
            showError("Installation failed: Could not find app resources")
            return false
        }
        
        let installerScript = "\(resourcePath)/scripts/first-run-installer.sh"
        
        guard FileManager.default.fileExists(atPath: installerScript) else {
            logger.error("Installer script not found at \(installerScript)")
            showError("Installation failed: Installer script not found in app bundle")
            return false
        }
        
        logger.info("Launching installer: \(installerScript)")
        logger.info("App bundle path: \(bundlePath)")
        
        // Run the installer script
        // The script will handle:
        // 1. Detecting if app is in correct location
        // 2. Offering to move app to /Applications if needed
        // 3. Setting up LaunchAgent
        // 4. Installing CLI tools
        // 5. Creating configuration
        // 6. Prompting for permissions
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [installerScript, bundlePath, "--no-dialogs"]
        
        // Capture output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            // Log output (always log, even if empty)
            if let outputData = try? outputPipe.fileHandleForReading.readToEnd(),
               let output = String(data: outputData, encoding: .utf8) {
                if !output.isEmpty {
                    logger.info("Installer output: \(output)")
                } else {
                    logger.warning("Installer produced no stdout output")
                }
            }
            
            if let errorData = try? errorPipe.fileHandleForReading.readToEnd(),
               let errorOutput = String(data: errorData, encoding: .utf8) {
                if !errorOutput.isEmpty {
                    logger.warning("Installer stderr: \(errorOutput)")
                } else {
                    logger.info("Installer produced no stderr output")
                }
            }
            
            if process.terminationStatus == 0 {
                logger.info("Installer completed successfully")
                
                // Verify installation artifacts exist
                let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/com.meetingscribe.daemon.plist"
                let configPath = "\(NSHomeDirectory())/.meetingscribe/config.json"
                
                if !FileManager.default.fileExists(atPath: plistPath) {
                    logger.error("Installation verification failed: plist not found at \(plistPath)")
                    showError("Installation incomplete: LaunchAgent plist file was not created. Please check logs and try again.")
                    return false
                }
                
                if !FileManager.default.fileExists(atPath: configPath) {
                    logger.error("Installation verification failed: config not found at \(configPath)")
                    showError("Installation incomplete: Configuration file was not created. Please check logs and try again.")
                    return false
                }
                
                logger.info("Installation verification passed")
                // Don't show completion dialog here - wait for permissions first
                // The service will show it after permissions are granted
                return true
            } else {
                logger.error("Installer exited with status \(process.terminationStatus)")
                
                // Check if user cancelled
                if process.terminationStatus == 1 {
                    // This is likely user cancellation - just quit gracefully
                    logger.info("User likely cancelled installation")
                    NSApp.terminate(nil)
                    return false
                }
                
                showError("Installation failed with exit code \(process.terminationStatus)")
                return false
            }
        } catch {
            logger.error("Failed to run installer: \(error.localizedDescription)")
            showError("Failed to run installer: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Check if app is running from expected location
    static func isInCorrectLocation() -> Bool {
        let bundlePath = Bundle.main.bundlePath
        
        // Check if in /Applications or ~/Applications
        let applicationsPath = "/Applications/MeetingScribe.app"
        let userApplicationsPath = "\(NSHomeDirectory())/Applications/MeetingScribe.app"
        
        return bundlePath == applicationsPath || bundlePath == userApplicationsPath
    }
    
    /// Get the current installation status
    static func getInstallationStatus() -> (installed: Bool, location: String?) {
        if FileManager.default.fileExists(atPath: installMarkerPath) {
            if let installedPath = try? String(contentsOfFile: installMarkerPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
                return (true, installedPath)
            }
            return (true, nil)
        }
        return (false, nil)
    }
    
    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Installation Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
    
    private static func showWelcomeDialog() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Welcome to MeetingScribe!"
        alert.informativeText = """
        This wizard will:
        
        1. Set up the background daemon
        2. Install command-line tools  
        3. Configure required permissions
        
        Click Continue to begin setup.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }
    
    static func showCompletionDialogPublic() {
        showCompletionDialog()
    }
    
    private static func showCompletionDialog() {
        let processId = ProcessInfo.processInfo.processIdentifier
        logger.info("[PID \(processId)] showCompletionDialog() called - displaying Installation Complete dialog")
        
        // This is called after permissions are granted
        let alert = NSAlert()
        alert.messageText = "✅ Installation Complete!"
        alert.informativeText = """
        MeetingScribe is now running in the background.
        Look for the microphone icon in your menu bar.
        
        ⚠️ REQUIRED: Configure your LLM provider API key
        
        The Preferences window will open where you can:
        • Add your API key (Anthropic, OpenAI, or Ollama)
        • Configure transcription settings
        • Customize notifications and templates
        
        You can access Preferences anytime from the menu bar.
        
        CLI Commands:
          meetingscribe-ctl status   - Check status
          meetingscribe-ctl restart  - Restart after config
          meetingscribe-ctl logs     - View logs
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Preferences")
        alert.runModal()
        
        // Open the Preferences window
        DispatchQueue.main.async {
            PreferencesWindowController.show()
        }
    }
}
