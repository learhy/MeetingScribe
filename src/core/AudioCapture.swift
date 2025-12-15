import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import AudioToolbox
import CoreGraphics

class StreamHandler: NSObject, SCStreamDelegate, SCStreamOutput {
    private let logger = DualLogger(category: "StreamHandler")
    private let application: SCRunningApplication
    private let outputDirOverride: URL?
    private let micEnabled: Bool

    private var stream: SCStream?

    private var mixer: AudioMixer?
    private var micCapture: MicCapture?

    private var sessionTimestamp: String?
    private(set) var mixedAudioFilePath: String?

    // System-audio conversion
    private var sysSourceFormat: AVAudioFormat?
    private var sysConverter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 48_000,
                                             channels: 2,
                                             interleaved: true)!

    // Important: keep screen and audio on different queues.
    // If audio writing blocks, ScreenCaptureKit can backlog *video* sample buffers and memory grows quickly.
    private let audioQueue = DispatchQueue(label: "com.audiocapture.output.audio", qos: .userInitiated)
    private let screenQueue = DispatchQueue(label: "com.audiocapture.output.screen", qos: .background)

    private var isStopped = false
    private let stoppedSemaphore = DispatchSemaphore(value: 0)
    
    // Track if we've attempted mic restart (to avoid infinite retries)
    private var micRestartAttempted = false
    private var systemAudioBufferCount = 0
    private var hasDetectedSignificantAudio = false

    init(application: SCRunningApplication, outputDir: URL?, micEnabled: Bool) {
        self.application = application
        self.outputDirOverride = outputDir
        self.micEnabled = micEnabled
        super.init()
    }

    func startCapture() async throws {
        self.logger.info("Starting capture for \(self.application.applicationName)...")

        // Get shareable content
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: false)

        logger.info("Shareable content: displays=\(content.displays.count) windows=\(content.windows.count) applications=\(content.applications.count)")

        // Prefer choosing a "real" Teams window (not tiny menu bar / offscreen helper windows).
        let teamsWindows = content.windows.filter { win in
            win.owningApplication?.bundleIdentifier == application.bundleIdentifier
        }
        logger.info("Teams windows found: \(teamsWindows.count) (bundleId=\(application.bundleIdentifier))")

        // Pick the largest plausible Teams window to decide which display to capture.
        // We filter out very small windows (e.g. 1px/24px height) that often correspond to menu/titlebar helpers.
        let primaryTeamsWindow = teamsWindows
            .filter { $0.frame.width >= 200 && $0.frame.height >= 200 }
            .max { a, b in (a.frame.width * a.frame.height) < (b.frame.width * b.frame.height) }
            ?? teamsWindows.max { a, b in (a.frame.width * a.frame.height) < (b.frame.width * b.frame.height) }

        if let w = primaryTeamsWindow {
            logger.info("Primary Teams window: windowID=\(w.windowID) frame=\(NSStringFromRect(w.frame))")
        } else {
            logger.warning("No Teams windows available for display selection")
        }

        func isTeamsFamilyApp(_ app: SCRunningApplication) -> Bool {
            // In practice, Teams may spawn helper processes that render audio but have different bundle IDs.
            // Keep anything that looks like Teams.
            let bid = app.bundleIdentifier.lowercased()
            if bid.hasPrefix("com.microsoft.teams") { return true }
            let name = app.applicationName.lowercased()
            return name.contains("teams")
        }

        // Choose the display that contains the selected Teams window, then scope capture by excluding *non-Teams* apps.
        let filter: SCContentFilter
        if let teamsWindow = primaryTeamsWindow {
            guard let display = content.displays.first(where: { $0.frame.intersects(teamsWindow.frame) }) ?? content.displays.first else {
                throw NSError(domain: "StreamHandler", code: 2,
                             userInfo: [NSLocalizedDescriptionKey: "No displays available for capture"])
            }

            logger.info("Using display-based filter for Teams display: displayID=\(display.displayID) frame=\(NSStringFromRect(display.frame))")

            let excludedApps = content.applications.filter { !isTeamsFamilyApp($0) }
            logger.info("Excluding \(excludedApps.count) non-Teams apps; keeping Teams-family apps")

            filter = SCContentFilter(display: display,
                                     excludingApplications: excludedApps,
                                     exceptingWindows: [])
        } else {
            logger.warning("No Teams windows found; falling back to first display-based filter")

            guard let display = content.displays.first else {
                throw NSError(domain: "StreamHandler", code: 2,
                             userInfo: [NSLocalizedDescriptionKey: "No displays available for capture"])
            }

            let excludedApps = content.applications.filter { !isTeamsFamilyApp($0) }
            logger.info("Excluding \(excludedApps.count) non-Teams apps; keeping Teams-family apps")

            filter = SCContentFilter(display: display,
                                     excludingApplications: excludedApps,
                                     exceptingWindows: [])
        }

        // Configure stream primarily for audio.
        // We still attach a screen output (macOS 15.x quirk), so strongly limit video delivery.
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // For debugging, keep our own process audio included; excluding shouldn't affect Teams,
        // but we want to eliminate any chance this flag is over-broad on certain macOS versions.
        config.excludesCurrentProcessAudio = false

        // Limit queued sample buffers to avoid unbounded memory growth if the consumer falls behind.
        config.queueDepth = 2

        // Minimize video work (we don't actually use it) while keeping a screen output attached.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // ~1 fps

        logger.info("Stream configuration:")
        logger.info("  - Sample rate: \(config.sampleRate) Hz")
        logger.info("  - Channels: \(config.channelCount)")
        logger.info("  - Captures audio: \(config.capturesAudio)")
        logger.info("  - Queue depth: \(config.queueDepth)")
        logger.info("  - Video: \(config.width)x\(config.height) @ ~\(config.minimumFrameInterval.seconds)s")

        // Create the stream
        stream = SCStream(filter: filter, configuration: config, delegate: self)

        guard let stream = stream else {
            throw NSError(domain: "StreamHandler", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create stream"])
        }

        // Add stream outputs.
        // On macOS 15.x we've observed that audio callbacks may not fire unless a screen output is also attached.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

        // Create output file(s) before starting the stream so we don't drop initial buffers.
        // IMPORTANT: system capture must not depend on mic capture.
        if self.mixer == nil {
            do {
                let baseDir: URL
                if let override = self.outputDirOverride {
                    baseDir = override
                } else {
                    // Use ~/Library/Logs/AudioCapture/recordings instead of ~/Documents
                    // Documents requires additional entitlements that don't work reliably in LaunchAgent context
                    let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                    baseDir = logsDir.appendingPathComponent("Logs/AudioCapture/recordings")
                }
                try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                let ts = formatter.string(from: Date())
                self.sessionTimestamp = ts

                let mixedURL = baseDir.appendingPathComponent("meeting_\(ts)_mixed.wav")
                let mixedWriter = try WAVStreamWriter(fileURL: mixedURL, sampleRate: 48_000, channels: 2, bitsPerSample: 16)
                
                // Create AudioMixer with system gain=2.0x, mic gain=0.8x
                self.mixer = AudioMixer(writer: mixedWriter, sysGain: 2.0, micGain: 0.8)
                self.mixedAudioFilePath = mixedURL.path
                self.logger.info("✅ Mixed WAV: \(mixedURL.path)")

                if self.micEnabled {
                    // Mic is optional; failures must not break system capture.
                    do {
                        self.micCapture = try MicCapture(onSamples: { [weak self] samples in
                            guard let self else { return }
                            self.mixer?.appendMic(samples)
                        })
                        try self.micCapture?.start()
                        self.logger.info("✅ Mic capture started (will mix into mixed.wav)")
                    } catch {
                        self.logger.warning("Mic capture unavailable; continuing with system-only: \(error.localizedDescription)")
                        self.micCapture = nil
                    }
                } else {
                    self.logger.warning("Microphone permission not granted; writing system-only track")
                }
            } catch {
                self.logger.error("Failed to initialize recording: \(error.localizedDescription)")
                self.mixer = nil
                self.micCapture = nil
                self.sessionTimestamp = nil
            }
        }

        // Start capture
        try await stream.startCapture()

        logger.info("✅ Stream capture started")
    }

    func stopCapture() {
        logger.info("Stopping capture...")

        Task {
            do {
                try await stream?.stopCapture()
                logger.info("Stream stopped")
            } catch {
                logger.error("Error stopping stream: \(error.localizedDescription)")
            }

            micCapture?.stop()
            micCapture = nil

            mixer?.finalize()
            mixer = nil
            sessionTimestamp = nil

            sysSourceFormat = nil
            sysConverter = nil

            isStopped = true
            stoppedSemaphore.signal()
        }
    }

    func waitUntilStopped() async {
        // Avoid capturing non-Sendable `self` in the global queue closure.
        let sema = self.stoppedSemaphore
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                sema.wait()
                continuation.resume()
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Ignore screen buffers; we attach them to help ensure audio delivery.
        guard type == .audio else { return }

        if !CMSampleBufferIsValid(sampleBuffer) {
            self.logger.warning("Received invalid audio CMSampleBuffer")
            return
        }

        guard let mixer = self.mixer else {
            return
        }

        // Convert the system-audio CMSampleBuffer to 48kHz stereo interleaved int16 and send to mixer.
        if let samples = self.convertSystemAudioToTarget(sampleBuffer: sampleBuffer) {
            mixer.appendSystem(samples)
            
            // Detect if we're receiving significant audio (not just silence)
            if !hasDetectedSignificantAudio && !micRestartAttempted {
                // Check first 100 samples for non-zero audio
                let sampleCount = min(100, samples.count)
                let nonZeroCount = samples.prefix(sampleCount).filter { abs($0) > 100 }.count
                
                if nonZeroCount > 10 {
                    hasDetectedSignificantAudio = true
                    logger.info("🔊 Detected actual audio in system stream (call likely started)")
                    
                    // Now restart mic to reclaim it from Teams
                    if micEnabled && micCapture != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                            self?.restartMicrophoneCapture()
                        }
                    }
                }
            }
        }
    }

    
    private func restartMicrophoneCapture() {
        micRestartAttempted = true
        
        logger.info("🔄 Attempting to restart microphone capture (Teams may have released exclusive access)")
        
        // Stop existing mic capture
        micCapture?.stop()
        micCapture = nil
        
        // Wait a moment for audio routing to settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.mixer != nil else { return }
            
            do {
                self.micCapture = try MicCapture(onSamples: { [weak self] samples in
                    guard let self else { return }
                    self.mixer?.appendMic(samples)
                })
                try self.micCapture?.start()
                self.logger.info("✅ Microphone capture restarted successfully")
            } catch {
                self.logger.warning("Failed to restart microphone: \(error.localizedDescription)")
            }
        }
    }

    private func convertSystemAudioToTarget(sampleBuffer: CMSampleBuffer) -> [Int16]? {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        if frameCount == 0 { return nil }

        // Source format from CMSampleBuffer
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
            self.logger.warning("System convert: missing format description")
            return nil
        }

        guard let sourceFormat = AVAudioFormat(streamDescription: asbdPtr) else {
            self.logger.warning("System convert: failed to build AVAudioFormat from ASBD")
            return nil
        }

        if self.sysSourceFormat == nil || self.sysSourceFormat != sourceFormat {
            self.sysSourceFormat = sourceFormat
            self.sysConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            self.logger.info("System audio source format: \(sourceFormat)")
        }

        guard let converter = self.sysConverter else { return nil }

        // Pull audio payload into an AVAudioPCMBuffer
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            return nil
        }
        sourceBuffer.frameLength = frameCount

        // Fill sourceBuffer from the CMSampleBuffer's AudioBufferList
        var blockBuffer: CMBlockBuffer?
        var sizeNeeded = 0
        let status1 = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status1 == noErr, sizeNeeded > 0 else {
            self.logger.warning("System convert: failed sizing AudioBufferList (OSStatus=\(status1))")
            return nil
        }

        let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded,
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPtr.deallocate() }
        let ablPtr = rawPtr.assumingMemoryBound(to: AudioBufferList.self)
        ablPtr.pointee.mNumberBuffers = 0

        let status2 = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: ablPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status2 == noErr else {
            self.logger.warning("System convert: failed fetching AudioBufferList (OSStatus=\(status2))")
            return nil
        }

        let dstABL = sourceBuffer.audioBufferList

        // Copy buffer payloads.
        // If layouts differ (interleaved vs non-interleaved), AVAudioPCMBuffer's audioBufferList matches sourceFormat.
        let srcList = UnsafeMutableAudioBufferListPointer(ablPtr)
        let dstList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: dstABL))

        let n = min(srcList.count, dstList.count)
        for i in 0..<n {
            let src = srcList[i]
            var dst = dstList[i]

            guard let srcData = src.mData, let dstData = dst.mData else { continue }
            let bytes = min(Int(src.mDataByteSize), Int(dst.mDataByteSize))
            memcpy(dstData, srcData, bytes)

            // Ensure the destination byte size matches what we copied.
            dst.mDataByteSize = UInt32(bytes)
            dstList[i] = dst
        }

        // Convert to target (int16 interleaved stereo @ 48k)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
            return nil
        }

        var error: NSError?
        var didSupply = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if didSupply {
                outStatus.pointee = .noDataNow
                return nil
            }
            didSupply = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if let error {
            self.logger.error("System convert error: \(error.localizedDescription)")
            return nil
        }

        guard let int16Ptr = outBuffer.int16ChannelData else {
            self.logger.warning("System convert: missing int16ChannelData")
            return nil
        }

        let frames = Int(outBuffer.frameLength)
        let samples = frames * Int(targetFormat.channelCount)
        let base = int16Ptr[0]
        return Array(UnsafeBufferPointer(start: base, count: samples))
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Stream stopped with error: \(error.localizedDescription)")
        stopCapture()
    }
}
