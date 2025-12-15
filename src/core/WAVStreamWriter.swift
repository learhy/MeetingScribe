import Foundation

final class WAVStreamWriter {
    private let logger = DualLogger(category: "WAVStreamWriter")

    let fileURL: URL
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16

    private var fileHandle: FileHandle?
    private var dataBytesWritten: UInt32 = 0

    /// Create a writer at an explicit file URL.
    init(fileURL: URL, sampleRate: UInt32 = 48_000, channels: UInt16 = 2, bitsPerSample: UInt16 = 16) throws {
        self.fileURL = fileURL
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample

        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        self.logger.info("Creating WAV file: \(self.fileURL.path)")

        FileManager.default.createFile(atPath: self.fileURL.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: self.fileURL)

        try writeHeaderPlaceholder()
        self.logger.info("✅ WAV stream writer ready")
    }

    /// Convenience: create in ~/Documents/AudioCapture with a generated meeting_ timestamp filename.
    convenience init(sampleRate: UInt32 = 48_000, channels: UInt16 = 2, bitsPerSample: UInt16 = 16) throws {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputDir = documentsDir.appendingPathComponent("AudioCapture")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let filename = "meeting_\(timestamp).wav"

        try self.init(fileURL: outputDir.appendingPathComponent(filename),
                      sampleRate: sampleRate,
                      channels: channels,
                      bitsPerSample: bitsPerSample)
    }

    func appendInterleavedInt16(_ samples: UnsafeBufferPointer<Int16>) throws {
        guard let fh = self.fileHandle else {
            throw NSError(domain: "WAVStreamWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "FileHandle not available"])
        }

        // Write raw PCM samples
        let byteCount = samples.count * MemoryLayout<Int16>.size
        let data = Data(bytes: samples.baseAddress!, count: byteCount)
        try fh.write(contentsOf: data)

        // Track bytes written (data chunk payload only)
        let newTotal = UInt64(self.dataBytesWritten) + UInt64(byteCount)
        self.dataBytesWritten = UInt32(min(newTotal, UInt64(UInt32.max)))
    }

    func finalize() {
        logger.info("Finalizing mixed WAV file...")
        guard let fh = self.fileHandle else {
            logger.warning("No file handle to finalize")
            return
        }

        do {
            try patchHeaderSizes(fileHandle: fh)
            try fh.close()
            self.logger.info("✅ Mixed WAV finalized: \(self.fileURL.path)")
        } catch {
            self.logger.error("Failed to finalize WAV: \(error.localizedDescription)")
        }

        self.fileHandle = nil
    }

    // MARK: - WAV header

    private func writeHeaderPlaceholder() throws {
        guard let fh = self.fileHandle else { return }

        // RIFF header (44 bytes total for PCM)
        // ChunkID "RIFF"
        // ChunkSize (fileSize - 8) -> patched later
        // Format "WAVE"
        // Subchunk1ID "fmt "
        // Subchunk1Size 16
        // AudioFormat 1 (PCM)
        // NumChannels
        // SampleRate
        // ByteRate
        // BlockAlign
        // BitsPerSample
        // Subchunk2ID "data"
        // Subchunk2Size (data bytes) -> patched later

        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = UInt16(channels) * UInt16(bitsPerSample) / 8

        var header = Data()
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        header.append(contentsOf: [0, 0, 0, 0]) // chunk size placeholder
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE

        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt 
        header.append(UInt32(16).littleEndianData)
        header.append(UInt16(1).littleEndianData) // PCM
        header.append(channels.littleEndianData)
        header.append(sampleRate.littleEndianData)
        header.append(byteRate.littleEndianData)
        header.append(blockAlign.littleEndianData)
        header.append(bitsPerSample.littleEndianData)

        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        header.append(contentsOf: [0, 0, 0, 0]) // data size placeholder

        try fh.write(contentsOf: header)
    }

    private func patchHeaderSizes(fileHandle fh: FileHandle) throws {
        // File size = 44 + dataBytesWritten
        let riffChunkSize = UInt32(36) &+ dataBytesWritten
        let dataChunkSize = dataBytesWritten

        // Patch RIFF chunk size at offset 4
        try fh.seek(toOffset: 4)
        try fh.write(contentsOf: riffChunkSize.littleEndianData)

        // Patch data chunk size at offset 40
        try fh.seek(toOffset: 40)
        try fh.write(contentsOf: dataChunkSize.littleEndianData)
    }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var le = self.littleEndian
        return Data(bytes: &le, count: MemoryLayout<Self>.size)
    }
}
