import Foundation
import Quartz
import Darwin

// MARK: - Data Models

enum CallState: String {
    case noCall = "no_call"
    case inCall = "in_call"
}

struct CallInfo {
    let platform: String  // "teams" or "zoom"
    let windowTitle: String
    let processId: Int32
    let detectedAt: Date
    let confidence: Double
}

// MARK: - Process Window Detector

class ProcessWindowDetector {
    private let teamsCallPatterns = [
        "Meeting in progress",
        "Call with",
        "Teams Meeting",
        "Meeting Stage"
    ]
    
    private let zoomCallPatterns = [
        "Zoom Meeting",
        "Zoom Webinar",
        "Zoom Cloud Meetings"
    ]
    
    private let teamsCallWindowThreshold = 19
    
    func detectCall() -> CallInfo? {
        guard let windows = getWindowsOnScreenOnly() else {
            return nil
        }
        
        // First try window title matching
        for window in windows {
            if let callInfo = checkWindowForCall(window) {
                return callInfo
            }
        }
        
        // Fallback: check window count (for when titles are empty)
        if let platform = checkWindowCount(windows) {
            return CallInfo(
                platform: platform,
                windowTitle: "(detected via window count)",
                processId: 0,
                detectedAt: Date(),
                confidence: 0.80
            )
        }
        
        return nil
    }
    
    private func getWindowsOnScreenOnly() -> [[String: Any]]? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        
        // Filter for normal windows (layer 0)
        return windowList.filter { window in
            guard let layer = window[kCGWindowLayer as String] as? Int else { return false }
            return layer == 0
        }
    }
    
    private func checkWindowForCall(_ window: [String: Any]) -> CallInfo? {
        guard let title = window[kCGWindowName as String] as? String,
              let owner = window[kCGWindowOwnerName as String] as? String,
              let pid = window[kCGWindowOwnerPID as String] as? Int32 else {
            return nil
        }
        
        let ownerLower = owner.lowercased()
        
        // Check Teams
        if ownerLower.contains("teams") {
            for pattern in teamsCallPatterns {
                if title.range(of: pattern, options: .caseInsensitive) != nil {
                    return CallInfo(
                        platform: "teams",
                        windowTitle: title,
                        processId: pid,
                        detectedAt: Date(),
                        confidence: 0.90
                    )
                }
            }
        }
        
        // Check Zoom
        if ownerLower.contains("zoom") {
            for pattern in zoomCallPatterns {
                if title.range(of: pattern, options: .caseInsensitive) != nil {
                    return CallInfo(
                        platform: "zoom",
                        windowTitle: title,
                        processId: pid,
                        detectedAt: Date(),
                        confidence: 0.90
                    )
                }
            }
            
            // Check for participant count pattern
            let participantPattern = "^\\d+\\s*participants?"
            if title.range(of: participantPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return CallInfo(
                    platform: "zoom",
                    windowTitle: title,
                    processId: pid,
                    detectedAt: Date(),
                    confidence: 0.90
                )
            }
        }
        
        return nil
    }
    
    private func checkWindowCount(_ windows: [[String: Any]]) -> String? {
        // Count Teams windows at layer 0
        let teamsWindowCount = windows.filter { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String else { return false }
            return owner.lowercased().contains("teams")
        }.count
        
        if teamsWindowCount >= teamsCallWindowThreshold {
            return "teams"
        }
        
        return nil
    }
}

// MARK: - AV Device Detector

class AVDeviceDetector {
    struct AVSignals {
        let udpCount: Int
        let mediaPortsCount: Int
        let confident: Bool
    }
    
    func detectAVUsage() -> (platform: String, signals: AVSignals)? {
        var teamsMediaPorts = 0
        var zoomUDP = 0
        
        // Get list of all processes and their network connections
        // Note: This is a simplified implementation. Full implementation would use
        // libproc or BSD sysctl to enumerate network connections by process.
        // For now, we'll return nil as this requires more complex C interop.
        
        // TODO: Implement UDP port monitoring using libproc APIs
        // This would check for:
        // - Teams: UDP ports 50000-50089 with no remote address (media ports)
        // - Zoom: 7+ UDP connections
        
        return nil
    }
}

// MARK: - Hybrid Call Detector

class HybridCallDetector {
    private let pollInterval: TimeInterval
    private let debounceChecks: Int
    private let processDetector = ProcessWindowDetector()
    private let avDetector = AVDeviceDetector()
    
    private var currentState: CallState = .noCall
    private var currentPlatform: String?
    
    // Debouncing state
    private var consecutiveDetections = 0
    private var consecutiveNoDetections = 0
    private var lastDetectedPlatform: String?
    
    // Callbacks
    var onCallStarted: ((CallInfo) -> Void)?
    var onCallEnded: ((String) -> Void)?
    
    init(pollInterval: TimeInterval = 2.0, debounceChecks: Int = 2) {
        self.pollInterval = pollInterval
        self.debounceChecks = debounceChecks
    }
    
    func detectCallRaw() -> (platform: String, confidence: Double)? {
        let processResult = processDetector.detectCall()
        let avResult = avDetector.detectAVUsage()
        
        // Both agree - highest confidence
        if let processResult = processResult, let avResult = avResult {
            return (processResult.platform, 0.95)
        }
        
        // Process/Window only - high confidence
        if let processResult = processResult {
            return (processResult.platform, processResult.confidence)
        }
        
        // AV only - require confident signal
        if let avResult = avResult, avResult.signals.confident {
            return (avResult.platform, 0.85)
        }
        
        return nil
    }
    
    func detectCall() -> (platform: String, confidence: Double)? {
        guard let rawResult = detectCallRaw() else {
            // No detection
            consecutiveNoDetections += 1
            
            // Reset if we have enough consecutive non-detections
            if consecutiveNoDetections >= debounceChecks {
                consecutiveDetections = 0
                lastDetectedPlatform = nil
            }
            
            return nil
        }
        
        let (platform, confidence) = rawResult
        
        // Same platform detected again
        if platform == lastDetectedPlatform {
            consecutiveDetections += 1
            consecutiveNoDetections = 0
        } else {
            // Different platform or first detection
            consecutiveDetections = 1
            consecutiveNoDetections = 0
            lastDetectedPlatform = platform
        }
        
        // Only report if we have enough consecutive detections
        if consecutiveDetections >= debounceChecks {
            return (platform, confidence)
        }
        
        return nil
    }
    
    func startMonitoring() async {
        while true {
            if let result = detectCall() {
                // Call detected
                if currentState == .noCall {
                    currentState = .inCall
                    currentPlatform = result.platform
                    
                    let callInfo = CallInfo(
                        platform: result.platform,
                        windowTitle: "",
                        processId: 0,
                        detectedAt: Date(),
                        confidence: result.confidence
                    )
                    onCallStarted?(callInfo)
                }
            } else {
                // No call detected
                if currentState == .inCall {
                    currentState = .noCall
                    if let platform = currentPlatform {
                        onCallEnded?(platform)
                    }
                    currentPlatform = nil
                }
            }
            
            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }
}
