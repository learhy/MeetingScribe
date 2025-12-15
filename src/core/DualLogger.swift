import Foundation
import os.log

/// Logger that mirrors messages to both Unified Logging and stderr.
///
/// Why: when running `./build/audiocapture` in a terminal, `os.Logger` output does not
/// automatically show up on stdout/stderr, which makes the process look like it's "hanging".
/// Writing to stderr also makes LaunchAgent redirection work as expected (logs land in
/// `~/Library/Logs/AudioCapture/stderr.log`).
final class DualLogger {
    private let os: Logger
    private let category: String

    /// Set `AUDIOCAPTURE_LOG_STDERR=0` to disable stderr mirroring.
    private static let mirrorToStderr: Bool = {
        ProcessInfo.processInfo.environment["AUDIOCAPTURE_LOG_STDERR"] != "0"
    }()

    init(subsystem: String = "com.audiocapture.daemon", category: String) {
        self.os = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    func info(_ message: String) {
        os.info("\(message, privacy: .public)")
        emit("INFO", message)
    }

    func warning(_ message: String) {
        os.warning("\(message, privacy: .public)")
        emit("WARN", message)
    }

    func error(_ message: String) {
        os.error("\(message, privacy: .public)")
        emit("ERROR", message)
    }

    func debug(_ message: String) {
        os.debug("\(message, privacy: .public)")
        emit("DEBUG", message)
    }

    private func emit(_ level: String, _ message: String) {
        guard Self.mirrorToStderr else { return }

        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] [\(level)] [\(category)] \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
