import XCTest
@testable import MeetingScribe

/// Integration tests that exercise the full pipeline:
/// NameResolver → TranscriptPostProcessor → NotesGeneration → GeneratedNotesParser
/// → NotesLabelCleaner → TitleValidator
///
/// These simulate what happens when a .wav file is processed through processRecording/processAudioFile,
/// without needing actual audio diarization (which requires torch/speechbrain).
final class PipelineIntegrationTests: XCTestCase {

    // MARK: - Full Pipeline: Diarization with Speaker Map → Notes → Bear

    /// Simulates a 1:1 meeting where voice matching identified one speaker
    /// but not the other, and calendar resolution provides the second name.
    func testFullPipeline_1on1WithMixedResolution() {
        // Simulate diarization output: SPEAKER_00 matched to "Ratchna" (misspelled),
        // SPEAKER_01 not matched
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id-1", name: "Ratchna", confidence: 0.75),
            "SPEAKER_01": nil
        ]

        // Calendar participants
        let participants = MeetingParticipants(
            meetingTitle: "Dan/Rachana 1:1",
            myEmail: "dan@example.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@example.com"],
            attendeeFirstNames: ["Rachana"],
            participants: [
                Participant(email: "dan@example.com", firstName: "Dan", isMe: true, inferredRole: "local"),
                Participant(email: "rachana@example.com", firstName: "Rachana", isMe: false, inferredRole: "remote")
            ]
        )

        // Contacts database has the correct spelling
        let contacts = [
            ContactInfo(email: "rachana@example.com", displayName: "Rachana Reddy",
                       preferredName: "Rachana", pronunciation: "rah-CHAH-nah",
                       aliases: ["Rachna"], role: "Engineer", team: "Platform",
                       source: "manual")
        ]

        // 1. Run NameResolver
        let resolution = NameResolver.resolve(
            participants: participants,
            speakerMap: speakerMap,
            contacts: contacts,
            transcript: "Ratchna: Let's discuss the roadmap.\nSPEAKER_01: Sure."
        )

        // SPEAKER_00 should be reconciled from "Ratchna" to "Rachana Reddy"
        XCTAssertEqual(resolution.labelMap["SPEAKER_00"]?.displayName, "Rachana Reddy")
        XCTAssertEqual(resolution.labelMap["SPEAKER_00"]?.source, .contacts)

        // SPEAKER_01 should be assigned via calendar fallback (Dan, the unmatched participant)
        XCTAssertEqual(resolution.labelMap["SPEAKER_01"]?.displayName, "Dan")
        XCTAssertEqual(resolution.labelMap["SPEAKER_01"]?.source, .calendar)

        // 2. Build display name map for transcript formatting
        let displayNameMap = NameResolver.displayNameMap(from: resolution)
        XCTAssertEqual(displayNameMap["SPEAKER_00"], "Rachana Reddy")
        XCTAssertEqual(displayNameMap["SPEAKER_01"], "Dan")

        // 3. Attendees list should use display names
        let attendees = NameResolver.attendeesList(participants: participants, labelMap: resolution.labelMap)
        XCTAssertTrue(attendees.contains("Dan"))
        XCTAssertTrue(attendees.contains("Rachana Reddy"))
        XCTAssertFalse(attendees.contains("SPEAKER"))

        // 4. Simulate LLM-generated notes with SPEAKER_XX labels leaking into summary
        let llmNotes = """
        # Meeting Notes

        ## Summary
        SPEAKER_00 and SPEAKER_01 discussed the Q3 roadmap priorities. SPEAKER_00 raised concerns about the PEDM framework.

        ## Key Points
        - SPEAKER_00 presented the agentic prioritization proposal
        - SPEAKER_01 agreed to review by Friday
        """

        // 5. Split notes
        let splitNotes = GeneratedNotesParser.split(llmNotes)

        // 6. Clean SPEAKER_XX from summary and notes
        let cleanedSummary = NotesLabelCleaner.clean(splitNotes.summary, labelMap: resolution.labelMap)
        let cleanedNotes = NotesLabelCleaner.clean(splitNotes.notes, labelMap: resolution.labelMap)

        // Summary should have real names, not SPEAKER_XX
        XCTAssertFalse(cleanedSummary.contains("SPEAKER_00"))
        XCTAssertFalse(cleanedSummary.contains("SPEAKER_01"))
        XCTAssertTrue(cleanedSummary.contains("Rachana Reddy"))
        XCTAssertTrue(cleanedSummary.contains("Dan"))

        // Notes should also be cleaned
        XCTAssertFalse(cleanedNotes.contains("SPEAKER_00"))
        XCTAssertFalse(cleanedNotes.contains("SPEAKER_01"))
        XCTAssertTrue(cleanedNotes.contains("Rachana Reddy"))

        // 7. Title validation — calendar title is "Dan/Rachana 1:1" (bare pattern)
        let title = TitleValidator.resolve(
            llmTitle: nil,
            calendarTitle: "Dan/Rachana 1:1",
            date: Date()
        )

        // Should be a bare 1:1 pattern → disambiguate with topic from summary
        XCTAssertTrue(TitleValidator.isBareOneOnOnePattern(title))

        let topic = TitleValidator.extractTopic(from: cleanedSummary)
        let disambiguated = TitleValidator.disambiguate(title: title, topic: topic, date: Date())

        // Should have topic appended
        XCTAssertTrue(disambiguated.contains("Dan/Rachana 1:1"))
        XCTAssertTrue(disambiguated.count > "Dan/Rachana 1:1".count)
    }

    // MARK: - Full Pipeline: LLM Refusal Title

    /// Simulates the case where the LLM produces a refusal sentence as the title.
    func testFullPipeline_LLMRefusalTitle() {
        // LLM generated a refusal instead of a title
        let llmTitle = "I'd be happy to help generate meeting notes, but I don't see a transcript in your message."

        // No calendar title available
        let title = TitleValidator.resolve(
            llmTitle: llmTitle,
            calendarTitle: nil,
            date: Date()
        )

        // Should fall back to date-based title
        XCTAssertTrue(title.hasPrefix("Meeting Notes - "))
        XCTAssertFalse(title.contains("happy to help"))
        XCTAssertFalse(title.contains("transcript"))
    }

    // MARK: - Full Pipeline: LLM Meta-Sentence Title

    /// Simulates the case where the LLM produces "Meeting Transcript Correction Request"
    func testFullPipeline_LLMMetaTitle() {
        let llmTitle = "Meeting Transcript Correction Request [Pending]"

        let title = TitleValidator.resolve(
            llmTitle: llmTitle,
            calendarTitle: "Weekly Team Sync",
            date: Date()
        )

        // Should fall back to calendar title
        XCTAssertEqual(title, "Weekly Team Sync")
    }

    // MARK: - Full Pipeline: No Calendar, Voice Match Only

    /// Simulates a meeting where calendar resolution failed but voice matching worked.
    /// KNOWN PEOPLE should still be injected from voice match results.
    func testFullPipeline_NoCalendarVoiceMatchOnly() {
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id-1", name: "Anando", confidence: 0.9),
            "SPEAKER_01": SpeakerIdentity(speakerId: "id-2", name: "Dan", confidence: 0.85)
        ]

        // No calendar participants
        let resolution = NameResolver.resolve(
            participants: nil,
            speakerMap: speakerMap,
            contacts: [],
            transcript: ""
        )

        // Both speakers should be resolved
        XCTAssertEqual(resolution.labelMap["SPEAKER_00"]?.displayName, "Anando")
        XCTAssertEqual(resolution.labelMap["SPEAKER_01"]?.displayName, "Dan")

        // Known people should include voice-matched names (for KNOWN PEOPLE injection)
        XCTAssertTrue(resolution.knownPeople.contains { $0.displayName == "Anando" })
        XCTAssertTrue(resolution.knownPeople.contains { $0.displayName == "Dan" })

        // Attendees list should use voice-matched names
        let attendees = NameResolver.attendeesList(participants: nil, labelMap: resolution.labelMap)
        XCTAssertTrue(attendees.contains("Anando"))
        XCTAssertTrue(attendees.contains("Dan"))
    }

    // MARK: - Full Pipeline: Preamble Stripping

    /// Simulates LLM notes with preamble that should be stripped
    func testFullPipeline_PreambleStripping() {
        let notesWithPreamble = """
        Here is the corrected transcript:

        ## Summary
        The team discussed Q3 priorities.

        ## Notes
        - Action item: review roadmap
        """

        let split = GeneratedNotesParser.split(notesWithPreamble)

        // Preamble should be stripped
        XCTAssertFalse(split.summary.contains("Here is the corrected transcript"))
        XCTAssertFalse(split.notes.contains("Here is the corrected transcript"))

        // Real content should remain
        XCTAssertTrue(split.summary.contains("Q3 priorities") || split.notes.contains("Q3 priorities"))
    }

    func testFullPipeline_GeneratedMeetingNotesPreamble() {
        let notesWithPreamble = """
        Generated meeting notes:

        ## Summary
        Discussion about the new architecture.

        ## Notes
        - Need to migrate by Q3
        """

        let split = GeneratedNotesParser.split(notesWithPreamble)

        XCTAssertFalse(split.summary.contains("Generated meeting notes"))
        XCTAssertFalse(split.notes.contains("Generated meeting notes"))
    }

    // MARK: - Full Pipeline: Group Call

    /// Simulates a 3-person meeting where only one speaker was voice-matched
    func testFullPipeline_GroupCallPartialMatch() {
        let speakerMap: [String: SpeakerIdentity?] = [
            "SPEAKER_00": SpeakerIdentity(speakerId: "id-1", name: "Dan", confidence: 0.9),
            "SPEAKER_01": nil,
            "SPEAKER_02": nil
        ]

        let participants = MeetingParticipants(
            meetingTitle: "Team Sync",
            myEmail: "dan@example.com",
            myFirstName: "Dan",
            attendeeEmails: ["rachana@example.com", "anando@example.com"],
            attendeeFirstNames: ["Rachana", "Anando"],
            participants: [
                Participant(email: "dan@example.com", firstName: "Dan", isMe: true, inferredRole: nil),
                Participant(email: "rachana@example.com", firstName: "Rachana", isMe: false, inferredRole: nil),
                Participant(email: "anando@example.com", firstName: "Anando", isMe: false, inferredRole: nil)
            ]
        )

        let resolution = NameResolver.resolve(
            participants: participants,
            speakerMap: speakerMap,
            contacts: [],
            transcript: ""
        )

        // SPEAKER_00 should be Dan (voice match)
        XCTAssertEqual(resolution.labelMap["SPEAKER_00"]?.displayName, "Dan")

        // The other two should be assigned from calendar (unambiguous: 2 labels, 2 unmatched participants)
        let assignedNames = Set(resolution.labelMap.values.map { $0.firstName })
        XCTAssertTrue(assignedNames.contains("Rachana"))
        XCTAssertTrue(assignedNames.contains("Anando"))

        // All 3 speakers should be resolved
        XCTAssertEqual(resolution.labelMap.count, 3)
    }

    // MARK: - Full Pipeline: Fuzzy Name Reconciliation

    /// Tests the specific name misspellings from the plan's evidence section
    func testFullPipeline_NameMisspellingCorrections() {
        let contacts = [
            ContactInfo(email: "rachana@example.com", displayName: "Rachana Reddy",
                       preferredName: "Rachana", pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "manual"),
            ContactInfo(email: "sapta@example.com", displayName: "Saptaparni Das",
                       preferredName: "Sapta", pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "manual"),
            ContactInfo(email: "anando@example.com", displayName: "Anando Gupta",
                       preferredName: "Anando", pronunciation: nil, aliases: nil,
                       role: nil, team: nil, source: "manual")
        ]

        let contactsByEmail = Dictionary(contacts.map { ($0.email.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let contactsByFirstName = Dictionary(
            contacts.compactMap { c -> (String, ContactInfo)? in
                guard let name = c.bestName else { return nil }
                let first = name.split(separator: " ").first.map(String.init)?.lowercased() ?? name.lowercased()
                return (first, c)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // "Ratchna" → "Rachana"
        let r1 = NameResolver.reconcileName(voiceMatched: "Ratchna", contacts: contacts, contactsByEmail: contactsByEmail, contactsByFirstName: contactsByFirstName)
        XCTAssertEqual(r1.displayName, "Rachana Reddy")

        // "Saptana" → "Sapta" (preferred name match)
        let r2 = NameResolver.reconcileName(voiceMatched: "Saptana", contacts: contacts, contactsByEmail: contactsByEmail, contactsByFirstName: contactsByFirstName)
        XCTAssertEqual(r2.displayName, "Saptaparni Das")

        // "Anand" → "Anando" (distance 1)
        let r3 = NameResolver.reconcileName(voiceMatched: "Anand", contacts: contacts, contactsByEmail: contactsByEmail, contactsByFirstName: contactsByFirstName)
        XCTAssertEqual(r3.displayName, "Anando Gupta")

        // "Krishan" → not in contacts, should keep voice-matched name
        let r4 = NameResolver.reconcileName(voiceMatched: "Krishan", contacts: contacts, contactsByEmail: contactsByEmail, contactsByFirstName: contactsByFirstName)
        XCTAssertEqual(r4.displayName, "Krishan")
        XCTAssertEqual(r4.source, .voiceMatch)
    }

    // MARK: - Full Pipeline: Title Disambiguation

    func testFullPipeline_TitleDisambiguationWithTopic() {
        let title = "Dan/Anando 1:1"
        let topic = "PEDM vs Agentic Prioritization"
        let date = Date()

        let result = TitleValidator.disambiguate(title: title, topic: topic, date: date)
        XCTAssertEqual(result, "Dan/Anando 1:1: PEDM vs Agentic Prioritization")
    }

    func testFullPipeline_TitleDisambiguationNoTopic() {
        let title = "Dan/Rachana 1:1"
        let date = Date()

        let result = TitleValidator.disambiguate(title: title, topic: nil, date: date)
        XCTAssertTrue(result.hasPrefix("Dan/Rachana 1:1 - "))
    }

    // MARK: - Full Pipeline: Complete Notes Cleaning

    func testFullPipeline_CompleteNotesCleaning() {
        let labelMap: [String: CanonicalName] = [
            "SPEAKER_00": CanonicalName(displayName: "Dan Rohan", firstName: "Dan",
                                        source: .contacts, confidence: 0.9, email: "dan@example.com"),
            "SPEAKER_01": CanonicalName(displayName: "Rachana Reddy", firstName: "Rachana",
                                        source: .contacts, confidence: 0.85, email: "rachana@example.com")
        ]

        // Simulate notes where LLM used SPEAKER_XX everywhere
        let summary = "SPEAKER_00 and SPEAKER_01 discussed the roadmap. SPEAKER_00 will follow up."
        let notes = "- SPEAKER_00: action item\n- SPEAKER_01: review needed\n- SPEAKER_02: joined late"

        let cleanedSummary = NotesLabelCleaner.clean(summary, labelMap: labelMap)
        let cleanedNotes = NotesLabelCleaner.clean(notes, labelMap: labelMap)

        XCTAssertEqual(cleanedSummary, "Dan Rohan and Rachana Reddy discussed the roadmap. Dan Rohan will follow up.")
        XCTAssertTrue(cleanedNotes.contains("Dan Rohan: action item"))
        XCTAssertTrue(cleanedNotes.contains("Rachana Reddy: review needed"))
        // SPEAKER_02 is not in labelMap → should get neutral label
        XCTAssertTrue(cleanedNotes.contains("Speaker 3: joined late"))
    }
}