import Foundation

/// P1-4: Audio-quality guards (plan §2 P1-4).
///
/// Pure-logic guards evaluated BEFORE transcription starts; capture-side
/// telemetry wiring is [needs-Mac-build] (ScreenCaptureKit/AVAudioFile).
/// Conservative by design: refuse only when the audio clearly cannot hold a
/// meeting (< 5 s duration or near-silent content).
struct AudioGuards {

    enum GuardResult: Equatable {
        case ok(AudioQualityMetrics)
        case rejected(reason: String)
    }

    /// Minimum audio duration to attempt transcription (seconds).
    static let minimumDurationSeconds: Double = 5.0

    /// RMS below this fraction of int16 full scale is considered silence.
    static let silenceRMSFloor: Double = 0.001  // ≈ -60 dBFS

    /// Fraction of silent frames above which audio is "near-silent".
    static let nearSilentFractionThreshold: Double = 0.98

    /// Audio-quality telemetry computed from 16-bit PCM samples.
    struct AudioQualityMetrics: Equatable {
        var durationSeconds: Double
        var rms: Double            // 0..1 of full scale
        var peak: Double           // 0..1 of full scale
        var clippingFraction: Double  // fraction of samples at ≥ 0.99 full scale
        var silentFrameFraction: Double

        var snrEstimateDB: Double {
            // Crude SNR estimate: signal RMS vs silence floor.
            guard rms > 0 else { return -120 }
            return 20 * log10(rms / AudioGuards.silenceRMSFloor)
        }
    }

    /// Evaluate raw interleaved 16-bit PCM samples.
    /// - Parameters:
    ///   - samples: interleaved PCM int16 samples
    ///   - sampleRate: samples per second (per channel counted as written)
    ///   - channels: channel count (duration = frames / sampleRate)
    static func evaluate(
        samples: [Int16],
        sampleRate: Double,
        channels: Int = 1
    ) -> GuardResult {
        guard !samples.isEmpty else {
            return .rejected(reason: "Audio contains no samples (empty capture)")
        }
        let frames = Double(samples.count) / Double(max(1, channels))
        let duration = frames / sampleRate

        var sumSquares: Double = 0
        var peak: Double = 0
        var clipped: Double = 0
        let frameSize = 4800 // 100 ms at 48 kHz
        var silentFrames = 0
        var totalFrames = 0

        var frameSum: Double = 0
        var frameCount = 0
        for sample in samples {
            let normalized = Double(sample) / 32768.0
            let magnitude = abs(normalized)
            sumSquares += normalized * normalized
            if magnitude > peak { peak = magnitude }
            if magnitude >= 0.99 { clipped += 1 }
            frameSum += magnitude
            frameCount += 1
            if frameCount == frameSize {
                if frameSum / Double(frameSize) < silenceRMSFloor { silentFrames += 1 }
                totalFrames += 1
                frameSum = 0
                frameCount = 0
            }
        }
        if frameCount > 0 {
            if frameSum / Double(frameCount) < silenceRMSFloor { silentFrames += 1 }
            totalFrames += 1
        }

        let rms = (sumSquares / Double(samples.count)).squareRoot()
        let metrics = AudioQualityMetrics(
            durationSeconds: duration,
            rms: rms,
            peak: peak,
            clippingFraction: Double(clipped) / Double(samples.count),
            silentFrameFraction: totalFrames > 0 ? Double(silentFrames) / Double(totalFrames) : 1.0
        )

        if duration < minimumDurationSeconds {
            return .rejected(reason: String(
                format: "Audio too short: %.1fs (minimum %.0fs)", duration, minimumDurationSeconds))
        }
        if metrics.rms < silenceRMSFloor || metrics.silentFrameFraction >= nearSilentFractionThreshold {
            return .rejected(reason: String(
                format: "Audio is near-silent: RMS %.6f, %.0f%% silent frames",
                metrics.rms, metrics.silentFrameFraction * 100))
        }
        return .ok(metrics)
    }

    /// Convenience: evaluate a WAV file's PCM payload by parsing the header.
    /// Works with the 48 kHz 16-bit PCM files MeetingScribe writes.
    static func evaluateWAVFile(url: URL) -> GuardResult? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        guard let (sampleRate, channels, pcm) = parseWAV(data) else { return nil }
        return evaluate(samples: pcm, sampleRate: Double(sampleRate), channels: channels)
    }

    /// Minimal WAV parser: find the fmt and data chunks.
    static func parseWAV(_ data: Data) -> (sampleRate: Int, channels: Int, samples: [Int16])? {
        let bytes = [UInt8](data)
        guard bytes.count > 44,
              String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else { return nil }

        var sampleRate = 48000
        var channels = 1
        var pcmStart: Int?
        var pcmLength = 0
        var offset = 12
        while offset + 8 <= bytes.count {
            let chunkID = String(bytes: bytes[offset..<offset+4], encoding: .ascii) ?? ""
            let chunkSize = Int(bytes[offset+4]) | (Int(bytes[offset+5]) << 8)
                | (Int(bytes[offset+6]) << 16) | (Int(bytes[offset+7]) << 24)
            let bodyStart = offset + 8
            if chunkID == "fmt ", bodyStart + 16 <= bytes.count {
                channels = Int(bytes[bodyStart+2]) | (Int(bytes[bodyStart+3]) << 8)
                sampleRate = Int(bytes[bodyStart+4]) | (Int(bytes[bodyStart+5]) << 8)
                    | (Int(bytes[bodyStart+6]) << 16) | (Int(bytes[bodyStart+7]) << 24)
            } else if chunkID == "data" {
                pcmStart = bodyStart
                pcmLength = min(chunkSize, bytes.count - bodyStart)
            }
            offset = bodyStart + chunkSize + (chunkSize % 2) // chunks are word-aligned
        }
        guard let start = pcmStart, pcmLength > 0 else { return nil }

        var samples: [Int16] = []
        samples.reserveCapacity(pcmLength / 2)
        var i = start
        let end = start + pcmLength - 1
        while i < end {
            let lo = Int16(bytes[i])
            let hi = Int16(bytes[i+1])
            samples.append(hi << 8 | lo & 0xFF)
            i += 2
        }
        return (sampleRate, channels, samples)
    }
}

/// P1-4: 30-day audio retention (Dan's Q1 decision).
///
/// The 48 kHz WAV per meeting is kept for a configurable window (default
/// 30 days), then auto-deleted. The retained pool is what the eval harness
/// draws from and what enables "re-run with current pipeline" — every
/// pipeline improvement applies retroactively to recent meetings.
struct AudioRetentionPolicy {

    /// Default retention window: 30 days (Dan's Q1 decision).
    static let defaultRetentionDays: Int = 30

    /// Delete retained WAV files older than the window.
    /// - Parameters:
    ///   - directory: the recordings directory (config audio.outputDirectory, expanded).
    ///   - retentionDays: window in days.
    ///   - extensions: file extensions considered retained audio (default wav).
    ///   - now: current time (injectable for tests).
    /// - Returns: (deletedFiles, freedBytes) for logging/telemetry.
    static func enforceRetention(
        directory: URL,
        retentionDays: Int = AudioRetentionPolicy.defaultRetentionDays,
        extensions: Set<String> = ["wav"],
        now: Date = Date()
    ) -> (deletedFiles: [String], freedBytes: Int64) {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        guard retentionDays > 0,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return ([], 0)
        }

        var deleted: [String] = []
        var freed: Int64 = 0
        for file in files where extensions.contains(file.pathExtension.lowercased()) {
            let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let modified = attrs?.contentModificationDate, modified < cutoff else { continue }
            let size = Int64(attrs?.fileSize ?? 0)
            if (try? FileManager.default.removeItem(at: file)) != nil {
                deleted.append(file.lastPathComponent)
                freed += size
            }
        }
        return (deleted, freed)
    }

    /// True when a retained meeting can be re-run with the current pipeline.
    static func canRerun(audioFilePath: URL, now: Date = Date(), retentionDays: Int = defaultRetentionDays) -> Bool {
        let attrs = try? audioFilePath.resourceValues(forKeys: [.contentModificationDateKey])
        guard let modified = attrs?.contentModificationDate else { return false }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        return modified >= cutoff
    }
}
