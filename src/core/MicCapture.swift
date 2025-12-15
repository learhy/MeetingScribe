import Foundation
import AVFoundation

final class MicCapture {
    private let logger = DualLogger(category: "MicCapture")

    private let engine = AVAudioEngine()
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat

    private let onSamples: ([Int16]) -> Void

    init(onSamples: @escaping ([Int16]) -> Void) throws {
        self.onSamples = onSamples

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 48_000,
                                         channels: 2,
                                         interleaved: true) else {
            throw NSError(domain: "MicCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create target audio format"])
        }
        self.targetFormat = target

        guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
            throw NSError(domain: "MicCapture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
        }
        self.converter = conv
        
        // Use maximum quality sample rate conversion (critical for Bluetooth 16kHz→48kHz)
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        
        logger.info("Mic input format: \(inputFormat)")
        logger.info("Mic target format: \(target)")
        logger.info("Converter quality: max (for \(inputFormat.sampleRate)Hz→48kHz upsampling)")
    }

    func start() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // Larger buffer size for Bluetooth compatibility (4x larger reduces choppiness).
        let bufferSize: AVAudioFrameCount = 4096

        logger.info("🎤 Mic device details:")
        logger.info("  - Sample rate: \(inputFormat.sampleRate) Hz")
        logger.info("  - Channels: \(inputFormat.channelCount)")
        logger.info("  - Format flags: \(inputFormat.streamDescription.pointee.mFormatFlags)")
        logger.info("  - Bits per channel: \(inputFormat.streamDescription.pointee.mBitsPerChannel)")
        logger.info("  - Bytes per frame: \(inputFormat.streamDescription.pointee.mBytesPerFrame)")
        logger.info("  - Buffer size: \(bufferSize) frames (~\(String(format: "%.1f", Double(bufferSize) / inputFormat.sampleRate * 1000))ms)")

        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.handle(buffer)
        }

        engine.prepare()
        try engine.start()
        logger.info("✅ Mic capture started")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        logger.info("Mic capture stopped")
    }

    private var bufferCount = 0
    private var lastLogTime = Date()
    private var loggedConversionDetails = false

    private func handle(_ buffer: AVAudioPCMBuffer) {
        bufferCount += 1
        
        // Log buffer statistics every 5 seconds
        let now = Date()
        if now.timeIntervalSince(lastLogTime) >= 5.0 {
            let avgFrames = Double(bufferCount) / now.timeIntervalSince(lastLogTime)
            logger.info("📊 Mic buffer stats: \(bufferCount) buffers in 5s (~\(String(format: "%.1f", avgFrames)) buffers/sec), last buffer: \(buffer.frameLength) frames")
            bufferCount = 0
            lastLogTime = now
        }
        
        // CRITICAL: Output buffer must account for sample rate conversion!
        // 16kHz → 48kHz means we need 3x the frame capacity
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameCapacity) * (targetFormat.sampleRate / buffer.format.sampleRate))
        
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            logger.warning("Failed to create output buffer with capacity \(outputCapacity)")
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)

        if let error {
            logger.error("Mic convert error: \(error.localizedDescription)")
            return
        }
        
        // Log conversion details once
        if !loggedConversionDetails {
            logger.info("🔄 Conversion details:")
            logger.info("  - Input frames: \(buffer.frameLength), Output frames: \(outBuffer.frameLength)")
            logger.info("  - Expected ratio: 3.0x (16kHz→48kHz)")
            logger.info("  - Actual ratio: \(String(format: "%.2f", Double(outBuffer.frameLength) / Double(buffer.frameLength)))x")
            loggedConversionDetails = true
        }

        // CRITICAL: Check how many frames were actually converted
        if outBuffer.frameLength == 0 {
            logger.warning("⚠️ Converter produced 0 frames from \(buffer.frameLength) input frames!")
            return
        }
        
        guard let int16Ptr = outBuffer.int16ChannelData else {
            // For interleaved int16, int16ChannelData is non-nil and points to a single channel buffer.
            logger.warning("Mic buffer missing int16ChannelData")
            return
        }

        let frames = Int(outBuffer.frameLength)
        let samples = frames * Int(targetFormat.channelCount)
        
        // Log if we're getting unexpected frame counts (potential sample loss)
        if !loggedConversionDetails && frames != buffer.frameLength * 3 {
            logger.warning("⚠️ Unexpected frame conversion: \(buffer.frameLength) input → \(frames) output (expected ~\(buffer.frameLength * 3))")
        }

        // Interleaved: channelData[0] is the whole interleaved buffer.
        let base = int16Ptr[0]
        let buf = UnsafeBufferPointer(start: base, count: samples)
        onSamples(Array(buf))
    }
}
