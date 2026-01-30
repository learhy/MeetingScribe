import Foundation
import AppKit

/// Handles installation of the meetingscribe-ctl CLI tool
class CLIInstaller {
    private static let cliToolName = "meetingscribe-ctl"
    private static let cliInstallPath = "/usr/local/bin/\(cliToolName)"
    private static let userDefaultsKey = "CLIToolInstalled"
    
    /// Check if the CLI tool is already installed
    static func isInstalled() -> Bool {
        return FileManager.default.fileExists(atPath: cliInstallPath)
    }
    
    /// Check if we've already prompted the user about CLI installation
    static func hasPromptedUser() -> Bool {
        return UserDefaults.standard.bool(forKey: userDefaultsKey)
    }
    
    /// Mark that we've prompted the user
    static func markAsPrompted() {
        UserDefaults.standard.set(true, forKey: userDefaultsKey)
    }
    
    /// Prompt user to install CLI tool and install if they agree
    static func promptAndInstall() {
        // Skip if already installed or already prompted
        if isInstalled() {
            print("CLI tool already installed at \(cliInstallPath)")
            markAsPrompted()
            return
        }
        
        if hasPromptedUser() {
            print("User already prompted about CLI tool installation")
            return
        }
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Install CLI Tool?"
            alert.informativeText = """
            MeetingScribe includes a command-line tool (meetingscribe-ctl) for controlling the app from Terminal.
            
            Would you like to install it to /usr/local/bin/?
            
            This will require administrator privileges.
            
            You can skip this and the app will still work normally from the menu bar.
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Skip")
            
            let response = alert.runModal()
            
            // Mark as prompted regardless of response
            markAsPrompted()
            
            if response == .alertFirstButtonReturn {
                // User clicked "Install"
                installCLITool()
            } else {
                print("User skipped CLI tool installation")
            }
        }
    }
    
    /// Install the CLI tool (requires sudo)
    private static func installCLITool() {
        // Find the script in the app bundle's Resources/scripts directory
        guard let resourcePath = Bundle.main.resourcePath else {
            showError("Could not find app resources")
            return
        }
        
        let scriptPath = "\(resourcePath)/scripts/meetingscribe-ctl.sh"
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            showError("CLI script not found at \(scriptPath)")
            return
        }
        
        // Create an AppleScript that uses 'do shell script with administrator privileges'
        // This will prompt for password
        let appleScript = """
        do shell script "mkdir -p /usr/local/bin && cp '\(scriptPath)' '\(cliInstallPath)' && chmod +x '\(cliInstallPath)'" with administrator privileges
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: appleScript) {
            _ = scriptObject.executeAndReturnError(&error)
            
            if let error = error {
                print("Failed to install CLI tool: \(error)")
                showError("Failed to install CLI tool. You can install it manually by running:\n\nsudo cp '\(scriptPath)' '\(cliInstallPath)' && sudo chmod +x '\(cliInstallPath)'")
            } else {
                print("CLI tool installed successfully to \(cliInstallPath)")
                showSuccess()
            }
        } else {
            showError("Failed to create installation script")
        }
    }
    
    private static func showSuccess() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "CLI Tool Installed"
            alert.informativeText = """
            The meetingscribe-ctl command is now available in your terminal.
            
            Try running:
              meetingscribe-ctl status
              meetingscribe-ctl logs
            """
            alert.alertStyle = .informational
            alert.runModal()
        }
    }
    
    private static func showError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Installation Failed"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
