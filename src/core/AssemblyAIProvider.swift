import Foundation

/// P2-1: AssemblyAI Universal-3 Pro provider (plan §2 P2-1, §3 steps 2–3).
///
/// EVAL-ONLY until Dan promotes it (Dan's Q2 decision: "yes, opt into
/// AssemblyAI Universal-3 Pro for eval only"). The provider ships behind
/// `transcription.provider = "assemblyai"` with its own config block
/// (`transcription.assemblyai`) — the default engine stays whisper-1 + roster.
/// Adoption is harness-gated per docs/engine-swap.md (plan §3): corpus WER must
/// improve by >=1 point AND hard-name accuracy must not regress AND no new
/// failure mode may appear.
///
/// Async job model (their documented flow):
///   1. POST /v2/upload            -> { "upload_url": ... }
///   2. POST /v2/transcript        -> { "id": ... }   (speech_model + keyterms)
///   3. GET  /v2/transcript/{id}   -> poll until status completed|error
///
/// Roster biasing: MeetingScribe's RosterBuilder output (P0-3) is mapped to
/// AssemblyAI's `keyterms` parameter — the plan's "strongest biasing surface"
/// among cloud APIs. On ANY failure the caller (TranscriptionService) falls
/// back per the existing fallback-chain pattern to whisper-1.
///
/// [needs-Mac-build] — network client code. No API key exists on the Linux
/// host and no live calls are made from it; the pure logic (keyterm mapping)
/// is mirrored in tools/eval/p2_logic.py for the host-side regression suite.
class AssemblyAIUniversal3Provider: TranscriptionProvider {

    static let apiBase = "https://api.assemblyai.com/v2"

    /// Keychain account for the AssemblyAI key (SecretsManager, service
    /// "com.meetingscribe" — same storage as the OpenAI key).
    static let keychainAccount = "assemblyai.apiKey"

    /// Keyterms parameter cap — AssemblyAI accepts a large list (up to ~1,500
    /// words per the plan's biasing-surface table), but the roster budget keeps
    /// us far below it; 50 terms is generous headroom.
    static let maxKeyterms = 50

    private let apiKey: String
    private let model: String
    private let keyterms: [String]
    private let pollIntervalSeconds: Double
    private let maxPollAttempts: Int
    private let logger = DualLogger(category: "AssemblyAI")

    init(
        apiKey: String,
        model: String = "universal-3-pro",
        keyterms: [String] = [],
        pollIntervalSeconds: Double = 3.0,
        maxPollAttempts: Int = 600
    ) {
        self.apiKey = apiKey
        self.model = model
        self.keyterms = keyterms
        self.pollIntervalSeconds = pollIntervalSeconds
        self.maxPollAttempts = maxPollAttempts
    }

    // MARK: - TranscriptionProvider

    func transcribe(audioFileURL: URL) async throws -> String {
        logger.info("Transcribing via AssemblyAI \(model): \(audioFileURL.lastPathComponent)")
        guard FileManager.default.fileExists(atPath: audioFileURL.path) else {
            throw TranscriptionError.invalidAudioFile
        }
        if !keyterms.isEmpty {
            logger.info("Using \(keyterms.count) keyterms for roster biasing")
        }

        // 1. Upload (returns a session-backed URL)
        let audioKey = try await upload(audioFileURL)
        logger.info("Upload complete")

        // 2. Create the transcript job
        let transcriptID = try await createTranscript(audioURL: audioKey)
        logger.info("Transcript job created: \(transcriptID)")

        // 3. Poll until terminal state
        return try await pollTranscript(id: transcriptID)
    }

    // MARK: - API steps

    private func upload(_ fileURL: URL) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Self.apiBase)/upload")!)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "authorization")
        request.addValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        try Self.assertOK(response, data: data, logger: logger)

        struct UploadResponse: Codable { let uploadURL: String }
        let decoded = try Self.decode(UploadResponse.self, from: data)
        return decoded.uploadURL
    }

    private func createTranscript(audioURL: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Self.apiBase)/transcript")!)
        request.httpMethod = "POST"
        request.addValue(apiKey, forHTTPHeaderField: "authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "audio_url": audioURL,
            "speech_model": model,
            "language_code": "en",
        ]
        if !keyterms.isEmpty {
            body["keyterms"] = keyterms
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.assertOK(response, data: data, logger: logger)

        struct CreateResponse: Codable { let id: String }
        return try Self.decode(CreateResponse.self, from: data).id
    }

    private func pollTranscript(id: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(Self.apiBase)/transcript/\(id)")!)
        request.httpMethod = "GET"
        request.addValue(apiKey, forHTTPHeaderField: "authorization")

        for attempt in 1...maxPollAttempts {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.assertOK(response, data: data, logger: logger)

            struct PollResponse: Codable {
                let status: String
                let text: String?
                let error: String?
            }
            let decoded = try Self.decode(PollResponse.self, from: data)

            switch decoded.status {
            case "completed":
                guard let text = decoded.text, !text.isEmpty else {
                    throw TranscriptionError.invalidResponse
                }
                logger.info("AssemblyAI transcription completed (\(text.count) chars)")
                return text
            case "error":
                let message = decoded.error ?? "unknown AssemblyAI error"
                logger.error("AssemblyAI job failed: \(message)")
                throw TranscriptionError.apiError(message)
            default:
                if attempt % 10 == 1 {
                    logger.info("Poll \(attempt)/\(maxPollAttempts): status=\(decoded.status)")
                }
                try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
            }
        }
        throw TranscriptionError.apiError("AssemblyAI poll timed out after \(maxPollAttempts) attempts")
    }

    // MARK: - Keyterm mapping (pure logic — mirrored in tools/eval/p2_logic.py)

    static let namesSectionIntro = "The following people may be mentioned in this meeting: "
    static let correctionsSectionIntro = "Common corrections: "
    static let termsSectionIntro = "Technical terms that may come up: "

    /// Map the RosterBuilder prompt (P0-3) to AssemblyAI keyterms.
    ///
    /// Deterministic parse of the three roster sections:
    ///   - attendee names (the strongest biasing signal);
    ///   - "Common corrections" pairs — only the RIGHT side is canonical and
    ///     belongs in the keyterm list;
    ///   - technical glossary terms.
    /// De-duplicated case-insensitively, order preserved (roster rank order),
    /// capped at maxKeyterms. Empty roster prompt -> empty keyterms (biasing
    /// is additive, never fabricated).
    static func keyterms(fromRosterPrompt prompt: String) -> [String] {
        guard !prompt.isEmpty else { return [] }

        var result: [String] = []
        var seen = Set<String>()

        func add(_ raw: String) {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { return }
            let key = term.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(term)
        }

        if let names = section(of: prompt, after: namesSectionIntro) {
            for name in names.split(separator: ",") {
                add(String(name))
            }
        }
        if let corrections = section(of: prompt, after: correctionsSectionIntro) {
            for pair in corrections.split(separator: ",") {
                // "Wrong→Right" — only the right form is the canonical spelling.
                if let arrow = pair.range(of: "→") {
                    add(String(pair[arrow.upperBound...]))
                }
            }
        }
        if let terms = section(of: prompt, after: termsSectionIntro) {
            for term in terms.split(separator: ",") {
                add(String(term))
            }
        }

        return Array(result.prefix(maxKeyterms))
    }

    /// Extract a roster section body: everything after `intro` up to the next
    /// period (sections are sentence-terminated; individual items never
    /// contain ". ").
    static func section(of prompt: String, after intro: String) -> String? {
        guard let introRange = prompt.range(of: intro) else { return nil }
        let tail = prompt[introRange.upperBound...]
        guard let end = tail.range(of: ".") else { return nil }
        let body = String(tail[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    // MARK: - Response helpers

    private static func assertOK(_ response: URLResponse, data: Data, logger: DualLogger) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("AssemblyAI API error (\(http.statusCode)): \(message)")
            throw TranscriptionError.apiError(message)
        }
    }

    private static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw TranscriptionError.invalidResponse
        }
    }
}
