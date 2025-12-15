import Foundation

final class AudioMixer {
    private let logger = DualLogger(category: "AudioMixer")

    // Interleaved stereo Int16 samples (append-only with read indices to avoid O(n) removeFirst)
    private var sys: [Int16] = []
    private var mic: [Int16] = []
    private var sysRead: Int = 0
    private var micRead: Int = 0

    // Gains applied before mixing. Tunable.
    private let sysGain: Float
    private let micGain: Float

    // Simple level telemetry
    private var sysPeak: Int16 = 0
    private var micPeak: Int16 = 0
    private var lastLevelLog = Date.distantPast

    // Serialize all mixing to avoid races between SCK callback queue and AVAudioEngine tap.
    private let queue = DispatchQueue(label: "com.audiocapture.mixer")

    private let writer: WAVStreamWriter

    // Mix on a stable cadence to avoid jitter/choppiness caused by irregular buffer arrival patterns.
    private var timer: DispatchSourceTimer?
    private let chunkSamples: Int

    init(writer: WAVStreamWriter, sysGain: Float = 2.0, micGain: Float = 0.8, sampleRate: Int = 48_000, channels: Int = 2) {
        self.writer = writer
        self.sysGain = sysGain
        self.micGain = micGain
        // 10ms @ 48kHz => 480 frames. Stereo interleaved => 960 int16 samples.
        self.chunkSamples = (sampleRate / 100) * channels

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
        let sysAvail = sys.count - sysRead
        let micAvail = mic.count - micRead

        // If not flushing and there's nothing to output yet, do nothing.
        if !flush && sysAvail <= 0 && micAvail <= 0 { return }

        // Always output a fixed-size chunk while running to keep playback smooth.
        // On flush, output whatever remains.
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

        // Consume what we actually read.
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

        logger.info("Levels (peak dBFS): system=\(dbfs(sysPeak)) mic=\(dbfs(micPeak))")
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
