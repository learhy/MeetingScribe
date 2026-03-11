import Foundation

enum MixMode: String {
    case stereoSeparated = "stereo_separated"
    case monoMixed = "mono_mixed"
}

final class AudioMixer {
    private let logger = DualLogger(category: "AudioMixer")

    // Interleaved stereo Int16 samples (append-only with read indices to avoid O(n) removeFirst)
    private var sys: [Int16] = []
    private var mic: [Int16] = []
    private var sysRead: Int = 0
    private var micRead: Int = 0

    // Per-channel gain controls.
    private let sysGain: Float
    private let micGain: Float

    private let mode: MixMode

    // Simple level telemetry
    private var sysPeak: Int16 = 0
    private var micPeak: Int16 = 0
    private var lastLevelLog = Date.distantPast

    // Serialize all mixing to avoid races between SCK callback queue and AVAudioEngine tap.
    private let queue = DispatchQueue(label: "com.audiocapture.mixer")

    private let writer: WAVStreamWriter

    // Mix on a stable cadence to avoid jitter/choppiness caused by irregular buffer arrival patterns.
    private var timer: DispatchSourceTimer?
    private let chunkSamples: Int  // interleaved stereo sample count per 10ms chunk

    init(writer: WAVStreamWriter, mode: MixMode = .stereoSeparated, sysGain: Float = 1.0, micGain: Float = 1.0, sampleRate: Int = 48_000, channels: Int = 2) {
        self.writer = writer
        self.mode = mode
        self.sysGain = sysGain
        self.micGain = micGain
        // 10ms @ 48kHz => 480 frames. Stereo interleaved => 960 int16 samples.
        self.chunkSamples = (sampleRate / 100) * channels

        logger.info("Mixer mode: \(mode.rawValue)")
        logger.info("Mixer gains: system=\(sysGain)x mic=\(micGain)x")
        logger.info("Mixer cadence: 10ms, chunkSamples=\(self.chunkSamples)")

        startTimer()
    }

    func appendSystem(_ samples: [Int16]) {
        queue.async {
            self.sysPeak = max(self.sysPeak, Self.peak(samples))
            self.sys.append(contentsOf: samples)
            self.maybeLogLevelsLocked()
            self.compactLocked(force: false)
        }
    }

    func appendMic(_ samples: [Int16]) {
        queue.async {
            self.micPeak = max(self.micPeak, Self.peak(samples))
            self.mic.append(contentsOf: samples)
            self.maybeLogLevelsLocked()
            self.compactLocked(force: false)
        }
    }

    func finalize() {
        queue.sync {
            timer?.cancel()
            timer = nil

            // Flush remaining samples by mixing until both buffers are drained.
            while (sys.count - sysRead) > 0 || (mic.count - micRead) > 0 {
                mixOneChunkLocked(flush: true)
            }
            compactLocked(force: true)
        }
        writer.finalize()
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 10ms cadence
        t.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.mixOneChunkLocked(flush: false)
        }
        t.resume()
        self.timer = t
    }

    private func mixOneChunkLocked(flush: Bool) {
        switch mode {
        case .stereoSeparated:
            mixStereoSeparatedLocked(flush: flush)
        case .monoMixed:
            mixMonoMixedLocked(flush: flush)
        }
    }

    /// Stereo separation: system audio → left channel, mic audio → right channel.
    /// Input buffers are interleaved stereo (L,R,L,R…). We extract the left (even-index)
    /// sample from each source as its mono signal and write them to separate output channels.
    private func mixStereoSeparatedLocked(flush: Bool) {
        // Available interleaved samples in each buffer
        let sysAvail = sys.count - sysRead
        let micAvail = mic.count - micRead

        if !flush && sysAvail <= 0 && micAvail <= 0 { return }

        // Work in frames (1 frame = 2 interleaved samples: L + R)
        let outCount = flush ? max(sysAvail, micAvail) : chunkSamples
        if outCount <= 0 { return }

        // Ensure outCount is even (complete frames)
        let frameAlignedCount = outCount & ~1
        if frameAlignedCount <= 0 { return }

        var out = Array(repeating: Int16(0), count: frameAlignedCount)

        // Step through interleaved pairs: index 0,1 = frame 0 (L,R), index 2,3 = frame 1 (L,R), etc.
        var i = 0
        while i < frameAlignedCount {
            // System → left channel (even index in output)
            // Take the left sample (even index) from the interleaved system buffer
            let sysL: Int16 = (i < sysAvail) ? sys[sysRead + i] : 0
            out[i] = Self.applyGain(sysL, gain: self.sysGain)

            // Mic → right channel (odd index in output)
            // Take the left sample (even index) from the interleaved mic buffer as its mono signal
            let micL: Int16 = (i < micAvail) ? mic[micRead + i] : 0
            out[i + 1] = Self.applyGain(micL, gain: self.micGain)

            i += 2
        }

        sysRead += min(frameAlignedCount, sysAvail)
        micRead += min(frameAlignedCount, micAvail)

        out.withUnsafeBufferPointer { buf in
            do {
                try self.writer.appendInterleavedInt16(buf)
            } catch {
                self.logger.error("Failed writing stereo-separated audio: \(error.localizedDescription)")
            }
        }

        compactLocked(force: false)
    }

    /// Legacy mono mixing: sum system + mic into both channels (original behavior).
    private func mixMonoMixedLocked(flush: Bool) {
        let sysAvail = sys.count - sysRead
        let micAvail = mic.count - micRead

        if !flush && sysAvail <= 0 && micAvail <= 0 { return }

        let outCount = flush ? max(sysAvail, micAvail) : chunkSamples
        if outCount <= 0 { return }

        var out = Array(repeating: Int16(0), count: outCount)

        for i in 0..<outCount {
            let a0: Int16 = (i < sysAvail) ? sys[sysRead + i] : 0
            let b0: Int16 = (i < micAvail) ? mic[micRead + i] : 0

            let a = Self.applyGain(a0, gain: self.sysGain)
            let b = Self.applyGain(b0, gain: self.micGain)

            let sum = Int32(a) + Int32(b)
            if sum > Int32(Int16.max) {
                out[i] = Int16.max
            } else if sum < Int32(Int16.min) {
                out[i] = Int16.min
            } else {
                out[i] = Int16(sum)
            }
        }

        sysRead += min(outCount, sysAvail)
        micRead += min(outCount, micAvail)

        out.withUnsafeBufferPointer { buf in
            do {
                try self.writer.appendInterleavedInt16(buf)
            } catch {
                self.logger.error("Failed writing mixed audio: \(error.localizedDescription)")
            }
        }

        compactLocked(force: false)
    }

    private func compactLocked(force: Bool) {
        // If we've consumed a lot from the front, drop it in one go.
        // This avoids O(n) per-buffer removeFirst.
        let threshold = 48_000 * 2 // ~1s of stereo samples
        if force || sysRead > threshold {
            sys.removeFirst(sysRead)
            sysRead = 0
        }
        if force || micRead > threshold {
            mic.removeFirst(micRead)
            micRead = 0
        }
    }

    private func maybeLogLevelsLocked() {
        // Log about once per second.
        let now = Date()
        if now.timeIntervalSince(lastLevelLog) < 1.0 { return }
        lastLevelLog = now

        // Convert peaks to dBFS for readability.
        func dbfs(_ peak: Int16) -> String {
            if peak == 0 { return "-inf" }
            let v = Float(peak) / 32767.0
            let db = 20.0 * log10(v)
            return String(format: "%.1f", db)
        }

        let modeLabel = mode == .stereoSeparated ? "L=sys R=mic" : "mixed"
        logger.info("Levels (\(modeLabel), peak dBFS): system=\(dbfs(sysPeak)) mic=\(dbfs(micPeak))")
        sysPeak = 0
        micPeak = 0
    }

    private static func peak(_ samples: [Int16]) -> Int16 {
        var p: Int16 = 0
        for v in samples {
            let absV = v == Int16.min ? Int16.max : abs(v)
            if absV > p { p = absV }
        }
        return p
    }

    private static func applyGain(_ v: Int16, gain: Float) -> Int16 {
        if gain == 1.0 { return v }
        let scaled = Int(round(Float(v) * gain))
        if scaled > Int(Int16.max) { return Int16.max }
        if scaled < Int(Int16.min) { return Int16.min }
        return Int16(scaled)
    }
}
