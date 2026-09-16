import XCTest
@testable import MeetingScribe

// P1-1: CorrectionDictionary + TeachCommand parsing/store logic.
final class CorrectionDictionaryTests: XCTestCase {

    private var tempDir: URL!
    private var storePath: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ms-dict-tests-\(UUID().uuidString)")
        storePath = tempDir.appendingPathComponent("corrections.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Teach argument parsing

    func testParseTeachArgumentArrow() throws {
        let pair = try CorrectionDictionary.parseTeachArgument("Ratchna->Rachana")
        XCTAssertEqual(pair.wrong, "Ratchna")
        XCTAssertEqual(pair.right, "Rachana")
    }

    func testParseTeachArgumentVariants() throws {
        for arg in ["Ratchna=>Rachana", "Ratchna=Rachana", "Ratchna→Rachana"] {
            let pair = try CorrectionDictionary.parseTeachArgument(arg)
            XCTAssertEqual(pair.wrong, "Ratchna", arg)
            XCTAssertEqual(pair.right, "Rachana", arg)
        }
    }

    func testParseTeachArgumentTrimsWhitespace() throws {
        let pair = try CorrectionDictionary.parseTeachArgument("  Ratchna ->  Rachana ")
        XCTAssertEqual(pair.wrong, "Ratchna")
        XCTAssertEqual(pair.right, "Rachana")
    }

    func testParseTeachArgumentMissingSeparator() {
        XCTAssertThrowsError(try CorrectionDictionary.parseTeachArgument("Ratchna Rachana"))
    }

    func testParseTeachArgumentEmptySide() {
        XCTAssertThrowsError(try CorrectionDictionary.parseTeachArgument("->Rachana"))
        XCTAssertThrowsError(try CorrectionDictionary.parseTeachArgument("Ratchna->"))
    }

    // MARK: - Store round-trip

    func testLoadMissingFileReturnsEmpty() {
        let file = CorrectionDictionary.load(path: storePath)
        XCTAssertTrue(file.entries.isEmpty)
    }

    func testAddAndSaveRoundTrip() {
        var file = CorrectionDictionary.load(path: storePath)
        file = CorrectionDictionary.add(file: file, wrong: "Ratchna", right: "Rachana", now: 100)
        file = CorrectionDictionary.add(file: file, wrong: "Marodi", right: "Marodia", now: 200)
        XCTAssertTrue(CorrectionDictionary.save(file, path: storePath))

        let reloaded = CorrectionDictionary.load(path: storePath)
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertEqual(reloaded.entries[0].wrong, "Ratchna")
        XCTAssertEqual(reloaded.entries[0].source, "manual")
        XCTAssertEqual(reloaded.entries[1].updatedAt, 200)
    }

    func testAddUpdatesExistingEntryLastWriteWins() {
        var file = CorrectionDictionary.load(path: storePath)
        file = CorrectionDictionary.add(file: file, wrong: "Ratchna", right: "Rachana", now: 100)
        file = CorrectionDictionary.add(file: file, wrong: "Ratchna", right: "Rachana Reddy", now: 200)
        XCTAssertEqual(file.entries.count, 1)
        XCTAssertEqual(file.entries[0].right, "Rachana Reddy")
        XCTAssertEqual(file.entries[0].updatedAt, 200)
    }

    func testRemove() {
        var file = CorrectionDictionary.load(path: storePath)
        file = CorrectionDictionary.add(file: file, wrong: "Ratchna", right: "Rachana")
        let removed = CorrectionDictionary.remove(file: file, wrong: "Ratchna")
        XCTAssertEqual(removed?.entries.count, 0)
        // Removing a non-existent entry returns nil
        XCTAssertNil(CorrectionDictionary.remove(file: file, wrong: "NoSuch"))
    }

    // MARK: - Consumption

    func testCorrectionsMapExcludesNoOps() {
        var file = CorrectionDictionary.load(path: storePath)
        file = CorrectionDictionary.add(file: file, wrong: "Ratchna", right: "Rachana")
        file = CorrectionDictionary.add(file: file, wrong: "same", right: "Same")
        let map = CorrectionDictionary.correctionsMap(file: file)
        XCTAssertEqual(map["Ratchna"], "Rachana")
        XCTAssertNil(map["same"], "case-insensitive no-op entries are excluded")
    }

    func testFormatCorrections() {
        let text = CorrectionDictionary.formatCorrections(["Ratchna": "Rachana", "Marodi": "Marodia"])
        XCTAssertTrue(text.contains("## USER-TAUGHT CORRECTIONS"))
        XCTAssertTrue(text.contains("Ratchna → Rachana"))
        XCTAssertTrue(text.contains("Marodi → Marodia"))
        XCTAssertTrue(CorrectionDictionary.formatCorrections([:]).isEmpty)
    }

    func testRenderListEmpty() {
        let text = CorrectionDictionary.renderList(CorrectionDictionary.File())
        XCTAssertTrue(text.contains("No corrections taught"))
    }

    func testRenderListAndExport() {
        var file = CorrectionDictionary.load(path: storePath)
        file = CorrectionDictionary.add(file: file, wrong: "Ratchna", right: "Rachana", now: 1_700_000_000)
        let list = CorrectionDictionary.renderList(file)
        XCTAssertTrue(list.contains("Ratchna → Rachana"))
        XCTAssertTrue(list.contains("[manual"))
        let exported = CorrectionDictionary.renderJSON(file)
        XCTAssertTrue(exported.contains("Ratchna"))
        XCTAssertTrue(exported.contains("Rachana"))
    }
}

// P1-3: ArtifactWriter naming/immutability.
final class ArtifactWriterTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ms-artifact-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testMeetingIDFromAudioPath() {
        XCTAssertEqual(
            ArtifactWriter.meetingID(audioFilePath: "/recordings/meeting_20260916_141530.wav"),
            "meeting_20260916_141530")
        XCTAssertEqual(
            ArtifactWriter.meetingID(audioFilePath: "/x/y/audio.wav"),
            "audio")
    }

    func testArtifactPaths() {
        let paths = ArtifactWriter.artifactPaths(meetingID: "m1", directory: tempDir)
        XCTAssertEqual(paths.raw.lastPathComponent, "m1.raw.md")
        XCTAssertEqual(paths.note.lastPathComponent, "m1.note.md")
    }

    func testRawArtifactImmutable() {
        ArtifactWriter.writeRaw(meetingID: "m1", rawTranscript: "SPEAKER_00: hello", directory: tempDir)
        // Second write must NOT overwrite (immutability contract)
        ArtifactWriter.writeRaw(meetingID: "m1", rawTranscript: "overwritten!", directory: tempDir)
        let content = ArtifactWriter.readRaw(meetingID: "m1", directory: tempDir)
        XCTAssertEqual(content, "SPEAKER_00: hello")
    }

    func testNoteArtifactRegenerable() {
        ArtifactWriter.writeNote(meetingID: "m1", note: "v1", directory: tempDir)
        ArtifactWriter.writeNote(meetingID: "m1", note: "v2", directory: tempDir)
        let paths = ArtifactWriter.artifactPaths(meetingID: "m1", directory: tempDir)
        XCTAssertEqual(try? String(contentsOf: paths.note, encoding: .utf8), "v2")
    }

    func testListedMeetings() {
        ArtifactWriter.writeRaw(meetingID: "b-second", rawTranscript: "x", directory: tempDir)
        ArtifactWriter.writeRaw(meetingID: "a-first", rawTranscript: "y", directory: tempDir)
        // Note-only artifact without raw doesn't count
        ArtifactWriter.writeNote(meetingID: "c-note-only", note: "z", directory: tempDir)
        XCTAssertEqual(ArtifactWriter.listedMeetings(directory: tempDir), ["a-first", "b-second"])
    }
}

// P1-4: AudioRetentionPolicy.
final class AudioRetentionPolicyTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ms-retention-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeWAV(_ name: String, modifiedDaysAgo: Int, now: Date) {
        let url = tempDir.appendingPathComponent(name)
        try? Data("fake".utf8).write(to: url)
        let modified = now.addingTimeInterval(-Double(modifiedDaysAgo) * 86400)
        try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func testEnforceRetentionDeletesOldWAVsOnly() throws {
        let now = Date()
        writeWAV("old-meeting.wav", modifiedDaysAgo: 40, now: now)
        writeWAV("recent-meeting.wav", modifiedDaysAgo: 10, now: now)
        writeWAV("old-note.md", modifiedDaysAgo: 40, now: now) // wrong extension, kept

        let (deleted, freed) = AudioRetentionPolicy.enforceRetention(directory: tempDir, retentionDays: 30, now: now)
        XCTAssertEqual(deleted, ["old-meeting.wav"])
        XCTAssertGreaterThan(freed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("recent-meeting.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("old-note.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("old-meeting.wav").path))
    }

    func testZeroRetentionDisablesDeletion() {
        let now = Date()
        writeWAV("old-meeting.wav", modifiedDaysAgo: 400, now: now)
        let (deleted, _) = AudioRetentionPolicy.enforceRetention(directory: tempDir, retentionDays: 0, now: now)
        XCTAssertTrue(deleted.isEmpty, "retentionDays=0 disables auto-deletion")
    }

    func testCanRerun() {
        let now = Date()
        let oldURL = tempDir.appendingPathComponent("old.wav")
        let recentURL = tempDir.appendingPathComponent("recent.wav")
        try? Data("x".utf8).write(to: oldURL)
        try? Data("x".utf8).write(to: recentURL)
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-40 * 86400)], ofItemAtPath: oldURL.path)
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86400)], ofItemAtPath: recentURL.path)

        XCTAssertFalse(AudioRetentionPolicy.canRerun(audioFilePath: oldURL, now: now, retentionDays: 30))
        XCTAssertTrue(AudioRetentionPolicy.canRerun(audioFilePath: recentURL, now: now, retentionDays: 30))
    }
}

// P1-2: VerificationPass deterministic helpers.
final class VerificationPassTests: XCTestCase {

    func testNormalizeLabelsResolvedAndUnresolved() {
        let labelMap: [String: CanonicalName] = [
            "SPEAKER_00": CanonicalName(displayName: "Rachana Reddy", source: .contacts, confidence: 0.9)
        ]
        let text = "SPEAKER_00 opened. SPEAKER_01 agreed."
        let cleaned = VerificationPass.normalizeLabels(text, labelMap: labelMap)
        XCTAssertTrue(cleaned.contains("Rachana Reddy opened."))
        XCTAssertTrue(cleaned.contains("Speaker 1 agreed."), "unresolved labels become Speaker N, never raw SPEAKER_XX")
        XCTAssertFalse(cleaned.contains("SPEAKER_"))
    }

    func testRawTextKeepsRawLabels() {
        let diarized = DiarizedTranscript(
            segments: [
                DiarizedSegment(start: 0, end: 1, speaker: "SPEAKER_00", text: "hello"),
                DiarizedSegment(start: 1, end: 2, speaker: "SPEAKER_01", text: "hi"),
            ],
            speakers: ["SPEAKER_00", "SPEAKER_01"],
            numSpeakers: 2,
            audioFile: "x.wav",
            speakerMap: nil)
        let raw = VerificationPass.rawText(of: diarized)
        XCTAssertEqual(raw, "SPEAKER_00: hello\nSPEAKER_01: hi")
    }

    func testIsPlausibleEdit() {
        XCTAssertTrue(VerificationPass.isPlausibleEdit(
            original: "Rachna walked through the plan today",
            candidate: "Rachana walked through the plan today"))
        // Refusal prose is much shorter → implausible edit
        XCTAssertFalse(VerificationPass.isPlausibleEdit(
            original: "Rachna walked through the plan today and discussed the roadmap in detail",
            candidate: "I cannot help with that."))
        XCTAssertFalse(VerificationPass.isPlausibleEdit(original: "some text", candidate: ""))
    }

    func testSuspiciousTokens() {
        let transcript = "Rachna and the boundary team discussed it. Clear follow ups."
        let tokens = VerificationPass.suspiciousTokens(
            in: transcript, rosterNames: ["Rachana"])
        XCTAssertTrue(tokens.contains("Rachna"), "misspelling phonetically near roster name is flagged")
        XCTAssertFalse(tokens.contains("boundary"))
    }
}
