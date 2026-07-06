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
    private let logger = DualLogger(category: "ProcessWindowDetector")
    
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
            logger.debug("Failed to get windows")
            return nil
        }
        
        logger.debug("Checking \(windows.count) windows at layer 0")
        
        // First try window title matching
        for window in windows {
            if let callInfo = checkWindowForCall(window) {
                logger.info("✅ Call detected via window title: \(callInfo.platform) - \(callInfo.windowTitle)")
                return callInfo
            }
        }
        
        // Fallback: check window count (for when titles are empty)
        if let platform = checkWindowCount(windows) {
            logger.info("✅ Call detected via window count: \(platform)")
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
            let ownerLower = owner.lowercased()
            // Check for all Teams variants
            return ownerLower.contains("teams") || ownerLower.contains("msteams")
        }.count
        
        logger.debug("Teams window count at layer 0: \(teamsWindowCount) (threshold: \(teamsCallWindowThreshold))")
        
        if teamsWindowCount >= teamsCallWindowThreshold {
            logger.info("Teams call detected via window count (\(teamsWindowCount) >= \(teamsCallWindowThreshold))")
            return "teams"
        }
        
        return nil
    }
}

// MARK: - AV Device Detector

class AVDeviceDetector {
    private let logger = DualLogger(category: "AVDeviceDetector")
    
    struct AVSignals {
        let udpCount: Int
        let mediaPortsCount: Int
        let tcpCount: Int
        let confident: Bool
    }
    
    func detectAVUsage() -> (platform: String, signals: AVSignals)? {
        var teamsMediaPorts = 0
        var teamsUDP = 0
        var teamsTCP = 0
        var zoomUDP = 0
        
        // Enumerate all running processes
        let processCount = proc_listallpids(nil, 0)
        guard processCount > 0 else {
            logger.debug("Failed to get process count")
            return nil
        }
        
        var pids = [pid_t](repeating: 0, count: Int(processCount))
        let actualCount = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        
        guard actualCount > 0 else {
            logger.debug("Failed to get process list")
            return nil
        }
        
        // Check each process
        for i in 0..<Int(actualCount) {
            let pid = pids[i]
            guard pid > 0 else { continue }
            
            // Get process name
            let maxSize = 4096  // MAXPATHLEN * 4
            var pathBuffer = [CChar](repeating: 0, count: maxSize)
            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(maxSize))
            
            guard pathLen > 0 else { continue }
            
            let processPath = String(cString: pathBuffer)
            let processName = (processPath as NSString).lastPathComponent
            let processNameLower = processName.lowercased()
            
            // Check if this is Teams or Zoom
            let isTeams = processNameLower.contains("teams") || processNameLower.contains("msteams")
            let isZoom = processNameLower.contains("zoom")
            
            guard isTeams || isZoom else { continue }
            
            // Get socket file descriptors for this process
            let udpPortsInfo = getUDPPortsWithRemoteInfo(forPid: pid)
            
            if isTeams {
                teamsUDP += udpPortsInfo.count
                
                // Check for Teams media ports (50000-50089, no remote)
                // These indicate active media processing during a call.
                // Note: media ports may be owned by "MSTeams" or helper
                // processes like "Microsoft Teams ModuleHost" depending on
                // the Teams version, so we check all Teams processes.
                for portInfo in udpPortsInfo {
                    // Media ports with no remote connection
                    if portInfo.localPort >= 50000 && portInfo.localPort <= 50089 && !portInfo.hasRemote {
                        teamsMediaPorts += 1
                    }
                }
                
                // Also count TCP connections for Teams processes.
                // Teams may fall back to TCP 443 for media transport when UDP
                // is blocked or unreliable (VPN, firewall, network conditions).
                // An active call typically has 3+ TCP connections to Microsoft
                // media/turn servers.
                teamsTCP += getTCPConnectionCount(forPid: pid)
            } else if isZoom {
                zoomUDP += udpPortsInfo.count
            }
        }
        
        logger.debug("AV signals: teams_udp=\(teamsUDP), teams_media_ports=\(teamsMediaPorts), teams_tcp=\(teamsTCP), zoom_udp=\(zoomUDP)")
        
        // Check Teams - primary signal is UDP media ports (50000-50089)
        // Idle: 1 media port, In call: 4-5+ media ports
        if teamsMediaPorts >= 3 {
            let teamsCPU = getCPUUsage(platformSubstring: "teams")
            logger.info("Teams AV signals: udp=\(teamsUDP) media_ports=\(teamsMediaPorts) tcp=\(teamsTCP) cpu=\(String(format: "%.1f", teamsCPU))")
            return ("teams", AVSignals(
                udpCount: teamsUDP,
                mediaPortsCount: teamsMediaPorts,
                tcpCount: teamsTCP,
                confident: true
            ))
        }
        
        // Fallback: Teams using TCP transport (no UDP media ports).
        // During a call over TCP, Teams maintains 3+ TCP connections to
        // Microsoft media/TURN servers and uses significantly more CPU.
        // Require both TCP count and CPU to avoid false positives from
        // idle Teams background sync connections.
        if teamsTCP >= 3 {
            let teamsCPU = getCPUUsage(platformSubstring: "teams")
            if teamsCPU > 8.0 {
                logger.info("Teams AV signals (TCP fallback): udp=\(teamsUDP) media_ports=\(teamsMediaPorts) tcp=\(teamsTCP) cpu=\(String(format: "%.1f", teamsCPU))")
                return ("teams", AVSignals(
                    udpCount: teamsUDP,
                    mediaPortsCount: teamsMediaPorts,
                    tcpCount: teamsTCP,
                    confident: true
                ))
            }
        }
        
        // Check Zoom (match spike): require 7+ UDP connections and cpu > 15 for confidence
        if zoomUDP >= 7 {
            let zoomCPU = getCPUUsage(platformSubstring: "zoom")
            let confident = zoomCPU > 15
            logger.info("Zoom AV signals: udp=\(zoomUDP) cpu=\(String(format: "%.1f", zoomCPU)) confident=\(confident)")
            return ("zoom", AVSignals(
                udpCount: zoomUDP,
                mediaPortsCount: 0,
                tcpCount: 0,
                confident: confident
            ))
        }
        
        return nil
    }
    
    struct UDPPortInfo {
        let localPort: UInt16
        let hasRemote: Bool
    }
    
    private func getUDPPortsWithRemoteInfo(forPid pid: pid_t) -> [UDPPortInfo] {
        var portInfos = [UDPPortInfo]()
        
        // Get file descriptor info
        var bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return portInfos }
        
        let fdCount = bufferSize / Int32(MemoryLayout<proc_fdinfo>.size)
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(fdCount))
        
        bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufferSize)
        guard bufferSize > 0 else { return portInfos }
        
        // Check each file descriptor
        for fd in fds {
            // Check if it's a socket
            guard fd.proc_fdtype == PROX_FDTYPE_SOCKET else { continue }
            
            // Get socket info
            var socketInfo = socket_fdinfo()
            let socketSize = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, Int32(MemoryLayout<socket_fdinfo>.size))
            guard socketSize > 0 else { continue }
            
            // Check if it's UDP (SOCK_DGRAM)
            guard socketInfo.psi.soi_type == SOCK_DGRAM else { continue }
            
            // NOTE: proc_info.h uses in_sockinfo for both IPv4 and IPv6; insi_vflag tells which.
            let sockInfo = socketInfo.psi.soi_proto.pri_in
            
            // Ports are in network byte order.
            // IMPORTANT: insi_lport/insi_fport are signed in the proc_info structs, and can be negative.
            // Converting a negative Int32 to UInt32 traps (“Negative value is not representable”).
            // Preserve the raw bit pattern, then byte-swap.
            let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: sockInfo.insi_lport))
            let remotePort = UInt16(bigEndian: UInt16(truncatingIfNeeded: sockInfo.insi_fport))
            
            // Match psutil semantics: remote exists if foreign addr is non-zero AND foreign port is non-zero.
            let hasRemoteAddr: Bool = {
                if sockInfo.insi_vflag == INI_IPV4 {
                    // insi_faddr.ina_46.i46a_addr4.s_addr
                    return sockInfo.insi_faddr.ina_46.i46a_addr4.s_addr != 0
                } else if sockInfo.insi_vflag == INI_IPV6 {
                    // insi_faddr.ina_6 (struct in6_addr)
                    return withUnsafeBytes(of: sockInfo.insi_faddr.ina_6) { bytes in
                        return bytes.contains { $0 != 0 }
                    }
                } else {
                    return false
                }
            }()
            
            let hasRemote = hasRemoteAddr && remotePort > 0
            
            if localPort > 0 {
                portInfos.append(UDPPortInfo(localPort: localPort, hasRemote: hasRemote))
            }
        }
        
        return portInfos
    }
    
    /// Count established TCP connections for a process.
    /// Used to detect Teams calls that fall back to TCP transport.
    private func getTCPConnectionCount(forPid pid: pid_t) -> Int {
        var bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return 0 }
        
        let fdCount = bufferSize / Int32(MemoryLayout<proc_fdinfo>.size)
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(fdCount))
        
        bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufferSize)
        guard bufferSize > 0 else { return 0 }
        
        var tcpCount = 0
        for fd in fds {
            guard fd.proc_fdtype == PROX_FDTYPE_SOCKET else { continue }
            
            var socketInfo = socket_fdinfo()
            let socketSize = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, Int32(MemoryLayout<socket_fdinfo>.size))
            guard socketSize > 0 else { continue }
            
            // Only count TCP sockets (SOCK_STREAM)
            guard socketInfo.psi.soi_type == SOCK_STREAM else { continue }
            
            // Only count established connections
            let soiState = socketInfo.psi.soi_proto.pri_tcp.tcpsi_state
            // TSI_S_ESTABLISHED = 4 in macOS TCP states
            if soiState == 4 {
                tcpCount += 1
            }
        }
        
        return tcpCount
    }

    private func getCPUUsage(platformSubstring: String) -> Double {
        // Match spike intent (aggregate CPU across processes whose command contains platformSubstring)
        // Implementation uses `ps` as a pragmatic equivalent of psutil on macOS.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pcpu,comm"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        
        do {
            try process.run()
        } catch {
            return 0.0
        }

        // IMPORTANT: Drain stdout before waiting to avoid deadlock if `ps` output exceeds pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return 0.0 }

        guard let output = String(data: data, encoding: .utf8) else { return 0.0 }
        
        let needle = platformSubstring.lowercased()
        var total: Double = 0
        
        for line in output.split(separator: "\n") {
            // Format: "%CPU COMMAND"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            
            // Split once on whitespace
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            
            let cpuStr = parts[0]
            let cmd = parts[1].lowercased()
            guard cmd.contains(needle) else { continue }
            
            if let cpu = Double(cpuStr) {
                total += cpu
            }
        }
        
        return total
    }
}

// MARK: - Hybrid Call Detector

class HybridCallDetector {
    private let logger = DualLogger(category: "CallDetector")
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
    
    // Heartbeat tracking
    private var pollCount = 0
    private let heartbeatInterval = 15  // Log heartbeat every 15 polls
    
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
        if let processResult = processResult, avResult != nil {
            logger.debug("Raw detection: Both process and AV agree on \(processResult.platform)")
            return (processResult.platform, 0.95)
        }
        
        // Process/Window only - high confidence
        if let processResult = processResult {
            logger.debug("Raw detection: Process only - \(processResult.platform) (confidence: \(processResult.confidence))")
            return (processResult.platform, processResult.confidence)
        }
        
        // AV only - require confident signal
        if let avResult = avResult, avResult.signals.confident {
            logger.debug("Raw detection: AV only - \(avResult.platform)")
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
                if consecutiveDetections > 0 || lastDetectedPlatform != nil {
                    logger.debug("Debounce reset: no detections for \(debounceChecks) cycles")
                }
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
            logger.debug("Debounce: \(platform) detected \(consecutiveDetections)/\(debounceChecks) times")
        } else {
            // Different platform or first detection
            logger.debug("Debounce: First detection of \(platform)")
            consecutiveDetections = 1
            consecutiveNoDetections = 0
            lastDetectedPlatform = platform
        }
        
        // Only report if we have enough consecutive detections
        if consecutiveDetections >= debounceChecks {
            logger.debug("Debounce: \(platform) confirmed after \(consecutiveDetections) detections")
            return (platform, confidence)
        }
        
        return nil
    }
    
    func startMonitoring() async {
        logger.info("📡 Call detection started")
        logger.info("Poll interval: \(pollInterval)s, Debounce checks: \(debounceChecks)")
        logger.info("Monitoring for Teams/Zoom calls...")
        
        while true {
            pollCount += 1
            
            // Heartbeat log every N polls
            if pollCount % heartbeatInterval == 0 {
                logger.info("💓 Detector heartbeat (\(pollCount) polls, state: \(currentState.rawValue))")
            }
            
            if let result = detectCall() {
                // Call detected
                if currentState == .noCall {
                    logger.info("📞 Call state transition: noCall → inCall (\(result.platform))")
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
                } else {
                    // Already in call - log at debug level to avoid spam
                    if pollCount % 10 == 0 {
                        logger.debug("Call ongoing: \(result.platform)")
                    }
                }
            } else {
                // No call detected
                if currentState == .inCall {
                    logger.info("📴 Call state transition: inCall → noCall")
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
