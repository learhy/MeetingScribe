import Foundation

// MARK: - Notifications

extension Notification.Name {
    /// Posted when speaker data changes (speakers list, pending suggestions, stats)
    static let speakerDataDidChange = Notification.Name("SpeakerDataDidChange")
    
    /// Posted when a speaker service error occurs
    static let speakerServiceError = Notification.Name("SpeakerServiceError")
}

// MARK: - Service

/// Bridge between Swift UI and Python speaker database CLI
class SpeakerDatabaseService {
    
    // MARK: - Properties
    
    private(set) var speakers: [Speaker] = []
    private(set) var pendingSuggestions: [PendingNameSuggestion] = []
    private(set) var stats: DatabaseStats?
    private(set) var isLoading = false
    private(set) var lastError: String?
    
    private let logger = DualLogger(category: "SpeakerDatabaseService")
    
    // MARK: - Configuration
    
    private var pythonPath: String?
    private var scriptPath: String?
    private let databasePath: String
    
    private lazy var decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // Custom date decoding for ISO8601 with Z suffix
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            // Try ISO8601 with Z suffix first
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            // Fall back to basic ISO8601
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            // Try without timezone (assume UTC)
            let localFormatter = DateFormatter()
            localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            localFormatter.timeZone = TimeZone(identifier: "UTC")
            if let date = localFormatter.date(from: dateString.replacingOccurrences(of: "Z", with: "")) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
        }
        return decoder
    }()
    
    // MARK: - Singleton
    
    static let shared = SpeakerDatabaseService()
    
    // MARK: - Initialization
    
    private init() {
        databasePath = NSHomeDirectory() + "/.meetingscribe/speaker.db"
        resolvePaths()
    }
    
    /// Resolve Python and script paths using fallback chain
    private func resolvePaths() {
        // Path resolution order:
        // 1. Bundle resources (bundled app)
        // 2. /Applications/MeetingScribe.app (installed app, running from Xcode)
        // 3. ~/Applications/MeetingScribe.app (user install)
        // 4. which python3 (development fallback)
        
        let candidates = [
            (Bundle.main.resourcePath.map { $0 + "/python/bin/python3" },
             Bundle.main.resourcePath.map { $0 + "/scripts/speaker_cli.py" }),
            ("/Applications/MeetingScribe.app/Contents/Resources/python/bin/python3",
             "/Applications/MeetingScribe.app/Contents/Resources/scripts/speaker_cli.py"),
            (NSHomeDirectory() + "/Applications/MeetingScribe.app/Contents/Resources/python/bin/python3",
             NSHomeDirectory() + "/Applications/MeetingScribe.app/Contents/Resources/scripts/speaker_cli.py")
        ]
        
        for (pythonCandidate, scriptCandidate) in candidates {
            if let python = pythonCandidate,
               let script = scriptCandidate,
               FileManager.default.fileExists(atPath: python),
               FileManager.default.fileExists(atPath: script) {
                pythonPath = python
                scriptPath = script
                logger.info("Found Python at: \(python)")
                logger.info("Found script at: \(script)")
                return
            }
        }
        
        // Development fallback: use system python and look for script relative to source
        if let whichPython = runShellCommand("/usr/bin/which", ["python3"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !whichPython.isEmpty {
            pythonPath = whichPython
            
            // Try to find script in development location
            let devScriptCandidates = [
                FileManager.default.currentDirectoryPath + "/scripts/speaker_cli.py",
                NSHomeDirectory() + "/My Drive/software_projects/meeting-scribe/scripts/speaker_cli.py"
            ]
            
            for candidate in devScriptCandidates {
                if FileManager.default.fileExists(atPath: candidate) {
                    scriptPath = candidate
                    logger.info("Development mode: Python at \(whichPython), script at \(candidate)")
                    return
                }
            }
        }
        
        logger.error("Could not find Python or speaker_cli.py")
    }
    
    private func runShellCommand(_ command: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
    
    // MARK: - Public API
    
    /// Check if CLI is available and supports --json
    func checkCLIAvailable() -> Bool {
        guard pythonPath != nil, scriptPath != nil else {
            lastError = "Speaker CLI not found. Please ensure MeetingScribe is installed correctly."
            return false
        }
        return true
    }
    
    /// Refresh all data from the database
    func refresh(completion: @escaping (Bool) -> Void) {
        guard checkCLIAvailable() else {
            completion(false)
            return
        }
        
        isLoading = true
        lastError = nil
        
        let group = DispatchGroup()
        var success = true
        
        // Fetch speakers
        group.enter()
        fetchSpeakers { result in
            if case .failure(let error) = result {
                self.logger.error("Failed to fetch speakers: \(error)")
                success = false
            }
            group.leave()
        }
        
        // Fetch pending suggestions
        group.enter()
        fetchPendingSuggestions { result in
            if case .failure(let error) = result {
                self.logger.error("Failed to fetch pending: \(error)")
                success = false
            }
            group.leave()
        }
        
        // Fetch stats
        group.enter()
        fetchStats { result in
            if case .failure(let error) = result {
                self.logger.error("Failed to fetch stats: \(error)")
                // Stats failure is not critical
            }
            group.leave()
        }
        
        group.notify(queue: .main) {
            self.isLoading = false
            NotificationCenter.default.post(name: .speakerDataDidChange, object: self)
            completion(success)
        }
    }
    
    /// Confirm a name suggestion
    func confirmSuggestion(_ suggestion: PendingNameSuggestion, completion: @escaping (Result<ConfirmResponse, Error>) -> Void) {
        runCLI(["confirm", suggestion.id]) { [weak self] result in
            switch result {
            case .success(let data):
                do {
                    let response = try self?.decoder.decode(CLIResponse<ConfirmResponse>.self, from: data)
                    if let confirmData = response?.data {
                        // Update local state optimistically
                        DispatchQueue.main.async {
                            self?.pendingSuggestions.removeAll { $0.id == suggestion.id }
                            if let index = self?.speakers.firstIndex(where: { $0.id == suggestion.speakerId }) {
                                self?.speakers[index].name = suggestion.suggestedName
                            }
                            NotificationCenter.default.post(name: .speakerDataDidChange, object: self)
                        }
                        completion(.success(confirmData))
                    } else if let error = response?.error {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
                    } else {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 2, userInfo: [NSLocalizedDescriptionKey: "No data in response"])))
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// Reject a name suggestion
    func rejectSuggestion(_ suggestion: PendingNameSuggestion, completion: @escaping (Result<RejectResponse, Error>) -> Void) {
        runCLI(["reject", suggestion.id]) { [weak self] result in
            switch result {
            case .success(let data):
                do {
                    let response = try self?.decoder.decode(CLIResponse<RejectResponse>.self, from: data)
                    if let rejectData = response?.data {
                        DispatchQueue.main.async {
                            self?.pendingSuggestions.removeAll { $0.id == suggestion.id }
                            NotificationCenter.default.post(name: .speakerDataDidChange, object: self)
                        }
                        completion(.success(rejectData))
                    } else if let error = response?.error {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
                    } else {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 2, userInfo: [NSLocalizedDescriptionKey: "No data in response"])))
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// Rename a speaker
    func renameSpeaker(_ speaker: Speaker, to name: String, completion: @escaping (Result<RenameResponse, Error>) -> Void) {
        runCLI(["rename", speaker.id, name]) { [weak self] result in
            switch result {
            case .success(let data):
                do {
                    let response = try self?.decoder.decode(CLIResponse<RenameResponse>.self, from: data)
                    if let renameData = response?.data {
                        DispatchQueue.main.async {
                            if let index = self?.speakers.firstIndex(where: { $0.id == speaker.id }) {
                                self?.speakers[index].name = name
                            }
                            NotificationCenter.default.post(name: .speakerDataDidChange, object: self)
                        }
                        completion(.success(renameData))
                    } else if let error = response?.error {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
                    } else {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 2, userInfo: [NSLocalizedDescriptionKey: "No data in response"])))
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// Merge two speakers
    func mergeSpeakers(keep: Speaker, merge: Speaker, completion: @escaping (Result<MergeResponse, Error>) -> Void) {
        runCLI(["merge", "--force", keep.id, merge.id]) { [weak self] result in
            switch result {
            case .success(let data):
                do {
                    let response = try self?.decoder.decode(CLIResponse<MergeResponse>.self, from: data)
                    if let mergeData = response?.data {
                        DispatchQueue.main.async {
                            self?.speakers.removeAll { $0.id == merge.id }
                            NotificationCenter.default.post(name: .speakerDataDidChange, object: self)
                        }
                        // Refresh to get updated embedding counts
                        self?.refresh { _ in }
                        completion(.success(mergeData))
                    } else if let error = response?.error {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
                    } else {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 2, userInfo: [NSLocalizedDescriptionKey: "No data in response"])))
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// Split a speaker by moving embeddings to a new speaker
    func splitSpeaker(_ speaker: Speaker, embeddingIds: [String], completion: @escaping (Result<SplitResponse, Error>) -> Void) {
        var args = ["split", "--force", speaker.id]
        args.append(contentsOf: embeddingIds)
        
        runCLI(args) { [weak self] result in
            switch result {
            case .success(let data):
                do {
                    let response = try self?.decoder.decode(CLIResponse<SplitResponse>.self, from: data)
                    if let splitData = response?.data {
                        // Refresh to get new speaker and updated counts
                        self?.refresh { _ in }
                        completion(.success(splitData))
                    } else if let error = response?.error {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
                    } else {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 2, userInfo: [NSLocalizedDescriptionKey: "No data in response"])))
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// Delete a speaker
    func deleteSpeaker(_ speaker: Speaker, completion: @escaping (Result<DeleteResponse, Error>) -> Void) {
        runCLI(["delete", "--force", speaker.id]) { [weak self] result in
            switch result {
            case .success(let data):
                do {
                    let response = try self?.decoder.decode(CLIResponse<DeleteResponse>.self, from: data)
                    if let deleteData = response?.data {
                        DispatchQueue.main.async {
                            self?.speakers.removeAll { $0.id == speaker.id }
                            NotificationCenter.default.post(name: .speakerDataDidChange, object: self)
                        }
                        completion(.success(deleteData))
                    } else if let error = response?.error {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
                    } else {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 2, userInfo: [NSLocalizedDescriptionKey: "No data in response"])))
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// Get detailed speaker info
    func getSpeakerDetail(_ speakerId: String, completion: @escaping (Result<SpeakerDetail, Error>) -> Void) {
        runCLI(["get-speaker", speakerId]) { [weak self] result in
            switch result {
            case .success(let data):
                do {
                    let response = try self?.decoder.decode(CLIResponse<SpeakerDetail>.self, from: data)
                    if let detail = response?.data {
                        completion(.success(detail))
                    } else if let error = response?.error {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
                    } else {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 2, userInfo: [NSLocalizedDescriptionKey: "No data in response"])))
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// Run database cleanup
    func runCleanup(completion: @escaping (Result<CleanupResponse, Error>) -> Void) {
        isLoading = true
        
        runCLI(["cleanup"]) { [weak self] result in
            DispatchQueue.main.async {
                self?.isLoading = false
            }
            
            switch result {
            case .success(let data):
                do {
                    let response = try self?.decoder.decode(CLIResponse<CleanupResponse>.self, from: data)
                    if let cleanupData = response?.data {
                        self?.refresh { _ in }
                        completion(.success(cleanupData))
                    } else if let error = response?.error {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
                    } else {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 2, userInfo: [NSLocalizedDescriptionKey: "No data in response"])))
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// Run integrity check
    func checkIntegrity(completion: @escaping (Result<CheckResponse, Error>) -> Void) {
        runCLI(["check"]) { [weak self] result in
            switch result {
            case .success(let data):
                do {
                    let response = try self?.decoder.decode(CLIResponse<CheckResponse>.self, from: data)
                    if let checkData = response?.data {
                        completion(.success(checkData))
                    } else if let error = response?.error {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
                    } else {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 2, userInfo: [NSLocalizedDescriptionKey: "No data in response"])))
                    }
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// Associate an email address with a speaker (for calendar cross-reference)
    func associateEmail(speakerId: String, email: String, completion: @escaping (Result<Void, Error>) -> Void) {
        runCLI(["associate-email", speakerId, email]) { [weak self] result in
            switch result {
            case .success(_):
                completion(.success(()))
            case .failure(let error):
                self?.logger.error("Failed to associate email: \(error)")
                completion(.failure(error))
            }
        }
    }
    
    /// Fetch all contacts and filter to those matching the given emails.
    /// Uses async/await via a continuation over the callback-based CLI.
    func fetchContacts(forEmails emails: [String]) async -> [ContactInfo] {
        guard !emails.isEmpty else { return [] }
        let emailSet = Set(emails.map { $0.lowercased() })
        
        return await withCheckedContinuation { continuation in
            runCLI(["list-contacts"]) { [weak self] result in
                switch result {
                case .success(let data):
                    do {
                        let response = try self?.decoder.decode(CLIResponse<[ContactInfo]>.self, from: data)
                        let allContacts = response?.data ?? []
                        let filtered = allContacts.filter { emailSet.contains($0.email.lowercased()) }
                        continuation.resume(returning: filtered)
                    } catch {
                        self?.logger.error("Failed to decode contacts: \(error)")
                        continuation.resume(returning: [])
                    }
                case .failure(let error):
                    self?.logger.error("Failed to fetch contacts: \(error)")
                    continuation.resume(returning: [])
                }
            }
        }
    }
    
    /// Upsert a contact from calendar participant data.
    /// Calendar-sourced entries never overwrite manual entries.
    func upsertContact(email: String, displayName: String?, source: String = "calendar") {
        var args = ["add-contact", email, "--source", source]
        if let name = displayName, !name.isEmpty {
            args.append(contentsOf: ["--name", name])
        }
        
        runCLI(args) { [weak self] result in
            if case .failure(let error) = result {
                self?.logger.error("Failed to upsert contact \(email): \(error)")
            }
        }
    }
    
    /// Auto-populate contacts from resolved calendar participants.
    /// Upserts each non-self attendee with source="calendar".
    func populateContactsFromParticipants(_ participants: MeetingParticipants) {
        for participant in participants.participants where !participant.isMe {
            let displayName = participant.firstName  // best we have from calendar
            upsertContact(email: participant.email, displayName: displayName, source: "calendar")
        }
    }
    
    /// Cross-reference speaker map from diarization with calendar participants.
    /// For 1:1 calls with one unidentified speaker, auto-links the remaining calendar attendee.
    /// For group calls, creates name suggestions for unambiguous matches.
    func crossReferenceSpeakerMap(
        speakerMap: [String: SpeakerIdentity?],
        participants: MeetingParticipants
    ) {
        // Separate identified and unidentified speakers
        let identified = speakerMap.compactMapValues { $0 }  // label → identity (non-nil)
        let unidentified = speakerMap.filter { $0.value == nil }.map { $0.key }
        
        // Get calendar attendee names that are NOT already matched by voice
        let identifiedNames = Set(identified.values.compactMap { $0.name?.lowercased() })
        let unmatchedAttendees = participants.participants.filter { participant in
            !participant.isMe && !identifiedNames.contains(participant.firstName.lowercased())
        }
        
        guard !unidentified.isEmpty && !unmatchedAttendees.isEmpty else {
            return
        }
        
        // 1:1 call: exactly 1 unidentified speaker + 1 unmatched calendar attendee → auto-link
        if unidentified.count == 1 && unmatchedAttendees.count == 1,
           let speakerLabel = unidentified.first,
           let attendee = unmatchedAttendees.first {
            // Find the speaker_id for any identified speaker to get the DB context
            // For the unidentified speaker, we need to check if there's a speaker_id in the map
            // (unidentified speakers have nil identity, so we can't auto-link without a speaker_id)
            logger.info("1:1 cross-reference: \(speakerLabel) likely = \(attendee.firstName) <\(attendee.email)>")
            logger.info("Note: Cannot auto-link unidentified speakers (no speaker_id). Name suggestion will be created during next meeting with this speaker.")
        }
        
        // For identified speakers without email, associate their calendar email
        for (_, identity) in identified {
            if let matchingAttendee = participants.participants.first(where: {
                $0.firstName.lowercased() == identity.name?.lowercased()
            }) {
                associateEmail(speakerId: identity.speakerId, email: matchingAttendee.email) { result in
                    if case .failure(let error) = result {
                        self.logger.error("Failed to associate email \(matchingAttendee.email): \(error)")
                    }
                }
            }
        }
    }
    
    var hasPendingSuggestions: Bool {
        !pendingSuggestions.isEmpty
    }
    
    var pendingCount: Int {
        pendingSuggestions.count
    }
    
    // MARK: - Private Helpers
    
    private func fetchSpeakers(completion: @escaping (Result<Void, Error>) -> Void) {
        runCLI(["list-speakers"]) { [weak self] result in
            switch result {
            case .success(let data):
                do {
                    let response = try self?.decoder.decode(CLIResponse<[Speaker]>.self, from: data)
                    if let speakers = response?.data {
                        DispatchQueue.main.async {
                            self?.speakers = speakers
                        }
                        completion(.success(()))
                    } else if let error = response?.error {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
                    } else {
                        DispatchQueue.main.async {
                            self?.speakers = []
                        }
                        completion(.success(()))
                    }
                } catch {
                    self?.logger.error("Failed to decode speakers: \(error)")
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    private func fetchPendingSuggestions(completion: @escaping (Result<Void, Error>) -> Void) {
        runCLI(["list-pending"]) { [weak self] result in
            switch result {
            case .success(let data):
                do {
                    let response = try self?.decoder.decode(CLIResponse<[PendingNameSuggestion]>.self, from: data)
                    if let suggestions = response?.data {
                        DispatchQueue.main.async {
                            self?.pendingSuggestions = suggestions
                        }
                        completion(.success(()))
                    } else if let error = response?.error {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
                    } else {
                        DispatchQueue.main.async {
                            self?.pendingSuggestions = []
                        }
                        completion(.success(()))
                    }
                } catch {
                    self?.logger.error("Failed to decode pending: \(error)")
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    private func fetchStats(completion: @escaping (Result<Void, Error>) -> Void) {
        runCLI(["stats"]) { [weak self] result in
            switch result {
            case .success(let data):
                do {
                    let response = try self?.decoder.decode(CLIResponse<DatabaseStats>.self, from: data)
                    if let stats = response?.data {
                        DispatchQueue.main.async {
                            self?.stats = stats
                        }
                        completion(.success(()))
                    } else if let error = response?.error {
                        completion(.failure(NSError(domain: "SpeakerDB", code: 1, userInfo: [NSLocalizedDescriptionKey: error])))
                    } else {
                        completion(.success(()))
                    }
                } catch {
                    self?.logger.error("Failed to decode stats: \(error)")
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    private func runCLI(_ arguments: [String], completion: @escaping (Result<Data, Error>) -> Void) {
        guard let python = pythonPath, let script = scriptPath else {
            completion(.failure(NSError(domain: "SpeakerDB", code: 0, userInfo: [NSLocalizedDescriptionKey: "CLI not available"])))
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script, "--json", "--db", self.databasePath] + arguments
            
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                
                if process.terminationStatus != 0 {
                    // Try to parse error from JSON output
                    if let errorJson = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
                       let errorMessage = errorJson["error"] as? String {
                        DispatchQueue.main.async {
                            self.lastError = errorMessage
                        }
                        completion(.failure(NSError(domain: "SpeakerDB", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorMessage])))
                    } else {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        DispatchQueue.main.async {
                            self.lastError = errorString
                        }
                        completion(.failure(NSError(domain: "SpeakerDB", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorString])))
                    }
                    return
                }
                
                completion(.success(outputData))
            } catch {
                DispatchQueue.main.async {
                    self.lastError = error.localizedDescription
                }
                completion(.failure(error))
            }
        }
    }
}
