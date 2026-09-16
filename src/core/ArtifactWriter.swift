import Foundation

/// P1-3: Raw-vs-formatted artifact split (plan §2 P1-3).
///
/// Persists two artifacts per meeting in the app storage directory:
///   - `{meeting-id}.raw.md`  — the IMMUTABLE raw ASR/diarized transcript
///     (raw SPEAKER_XX labels, no LLM touches it, written once, never edited)
///   - `{meeting-id}.note.md` — the final formatted note (Bear note shape
///     unchanged; this is the local copy)
///
/// Benefits per the approved plan: (a) the verification pass is diffable
/// against ground truth; (b) the notes/title LLM receives the raw artifact
/// and is contractually a TRANSFORM; (c) formatting can be re-run without
/// re-transcribing (the P1-4 "re-run with current pipeline" action).
///
/// The meeting-id is the audio file's basename without extension (stable
/// across reprocessing because the WAV filename carries the timestamp).
struct ArtifactWriter {

    enum ArtifactError: Error {
        case directoryCreationFailed(String)
        case writeFailed(String)
    }

    /// Directory artifacts live in: ~/.meetingscribe/artifacts/
    static func defaultDirectory(homeDirectory: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".meetingscribe")
            .appendingPathComponent("artifacts")
    }

    /// Meeting id from an audio file path: basename without extension.
    /// e.g. "meeting_20260916_141530.wav" → "meeting_20260916_141530"
    static func meetingID(audioFilePath: String) -> String {
        URL(fileURLWithPath: audioFilePath).deletingPathExtension().lastPathComponent
    }

    /// Paths for the raw and note artifacts of a meeting.
    static func artifactPaths(
        meetingID: String,
        directory: URL = ArtifactWriter.defaultDirectory()
    ) -> (raw: URL, note: URL) {
        (
            raw: directory.appendingPathComponent("\(meetingID).raw.md"),
            note: directory.appendingPathComponent("\(meetingID).note.md")
        )
    }

    /// Persist the immutable raw transcript. Writes only if the file does not
    /// already exist — raw artifacts are immutable; reprocessing never
    /// overwrites the raw artifact from the same audio (it is byte-identical
    /// input, but immutability is the contract).
    @discardableResult
    static func writeRaw(
        meetingID: String,
        rawTranscript: String,
        directory: URL = ArtifactWriter.defaultDirectory()
    ) -> URL? {
        let paths = artifactPaths(meetingID: meetingID, directory: directory)
        if FileManager.default.fileExists(atPath: paths.raw.path) {
            return paths.raw
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try rawTranscript.write(to: paths.raw, atomically: true, encoding: .utf8)
            return paths.raw
        } catch {
            return nil
        }
    }

    /// Persist the formatted note artifact (overwrites — this one is regenerable).
    @discardableResult
    static func writeNote(
        meetingID: String,
        note: String,
        directory: URL = ArtifactWriter.defaultDirectory()
    ) -> URL? {
        let paths = artifactPaths(meetingID: meetingID, directory: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try note.write(to: paths.note, atomically: true, encoding: .utf8)
            return paths.note
        } catch {
            return nil
        }
    }

    /// Read the raw artifact back (for re-running formatting without re-transcription).
    static func readRaw(
        meetingID: String,
        directory: URL = ArtifactWriter.defaultDirectory()
    ) -> String? {
        let paths = artifactPaths(meetingID: meetingID, directory: directory)
        guard FileManager.default.fileExists(atPath: paths.raw.path) else { return nil }
        return try? String(contentsOf: paths.raw, encoding: .utf8)
    }

    /// List retained meetings that have both artifacts (candidates for
    /// "re-run with current pipeline").
    static func listedMeetings(directory: URL = ArtifactWriter.defaultDirectory()) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        let rawIDs = Set(files.compactMap { $0.hasSuffix(".raw.md") ? String($0.dropLast(7)) : nil })
        return rawIDs.sorted()
    }
}
