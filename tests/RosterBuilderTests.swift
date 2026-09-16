import XCTest
@testable import MeetingScribe

// MARK: - Test fixtures

private func makeContact(
    email: String,
    displayName: String? = nil,
    preferredName: String? = nil,
    source: String = "calendar"
) -> ContactInfo {
    ContactInfo(
        email: email,
        displayName: displayName,
        preferredName: preferredName,
        pronunciation: nil,
        aliases: nil,
        role: nil,
        team: nil,
        source: source
    )
}

private func makeParticipants(
    myEmail: String = "dan@example.com",
    myName: String = "Dan",
    others: [(email: String, name: String)] = []
) -> MeetingParticipants {
    var participants: [Participant] = [
        Participant(email: myEmail, firstName: myName, isMe: true, inferredRole: "local")
    ]
    for other in others {
        participants.append(
            Participant(email: other.email, firstName: other.name, isMe: false, inferredRole: "remote")
        )
    }
    return MeetingParticipants(
        meetingTitle: nil,
        myEmail: myEmail,
        myFirstName: myName,
        attendeeEmails: others.map { $0.email },
        attendeeFirstNames: others.map { $0.name },
        participants: participants
    )
}

private func makeGlossaryEntry(term: String, context: String? = nil) -> AppConfiguration.Transcription.GlossaryEntry {
    AppConfiguration.Transcription.GlossaryEntry(term: term, pronunciation: nil, context: context, aliases: nil)
}

// MARK: - Tests

final class RosterBuilderTests: XCTestCase {

    // MARK: Ranking

    func testOrganizerRankedFirst() {
        let participants = makeParticipants(
            others: [("krishnan@example.com", "Krishnan")]
        )
        let names = RosterBuilder.rankedNames(participants: participants, contacts: [])
        XCTAssertEqual(names.first, "Dan")
        XCTAssertEqual(names, ["Dan", "Krishnan"])
    }

    func testRepeatAttendeeRankedAboveKnownAboveCalendarOnly() {
        let participants = makeParticipants(others: [
            ("calendaronly@example.com", "Calonly"),
            ("repeat@example.com", "Repeat"),
            ("known@example.com", "Known"),
        ])
        let contacts = [
            makeContact(email: "known@example.com", displayName: "Known Person", source: "speaker_db"),
            makeContact(email: "calendaronly@example.com", displayName: "Calonly Person", source: "calendar"),
        ]
        let names = RosterBuilder.rankedNames(
            participants: participants,
            contacts: contacts,
            priorNames: ["Repeat"]
        )
        XCTAssertEqual(names, ["Dan", "Repeat", "Known Person", "Calonly Person"])
    }

    // MARK: Full display names (Dan's Q3 decision)

    func testFullDisplayNameFromContactsPreferredOverFirstName() {
        let participants = makeParticipants(others: [("rachana@example.com", "Rachana")])
        let contacts = [makeContact(email: "rachana@example.com", displayName: "Rachana Reddy")]
        let names = RosterBuilder.rankedNames(participants: participants, contacts: contacts)
        XCTAssertEqual(names, ["Dan", "Rachana Reddy"])
    }

    func testPreferredNameFallsBackBeforeCalendarFirstName() {
        let participants = makeParticipants(others: [("sapta@example.com", "Sapta")])
        let contacts = [makeContact(email: "sapta@example.com", preferredName: "Saptaparni")]
        let names = RosterBuilder.rankedNames(participants: participants, contacts: contacts)
        XCTAssertEqual(names, ["Dan", "Saptaparni"])
    }

    func testCalendarFirstNameFallbackWhenNoContact() {
        let participants = makeParticipants(others: [("anando@example.com", "Anando")])
        let names = RosterBuilder.rankedNames(participants: participants, contacts: [])
        XCTAssertEqual(names, ["Dan", "Anando"])
    }

    // MARK: De-duplication

    func testDuplicateNamesDedupedCaseInsensitively() {
        let participants = makeParticipants(others: [
            ("a@example.com", "Krishnan"),
            ("b@example.com", "krishnan"),
        ])
        let contacts = [
            makeContact(email: "a@example.com", displayName: "Krishnan Iyer"),
            makeContact(email: "b@example.com", displayName: "krishnan iyer"),
        ]
        let names = RosterBuilder.rankedNames(participants: participants, contacts: contacts)
        XCTAssertEqual(names.count, 2) // Dan + one Krishnan Iyer
        XCTAssertEqual(names.filter { $0.lowercased().contains("krishnan") }.count, 1)
    }

    // MARK: Prompt assembly

    func testPromptContainsNamesSentence() {
        let participants = makeParticipants(others: [("m@example.com", "Mukesh Marodia")])
        let prompt = RosterBuilder.buildPrompt(participants: participants, contacts: [], glossary: [])
        XCTAssertTrue(prompt.contains("Mukesh Marodia"))
        XCTAssertTrue(prompt.hasPrefix("The following people may be mentioned"))
    }

    func testGlossaryTermsAppendedWhileFitting() {
        let participants = makeParticipants(others: [("a@example.com", "Aname")])
        let glossary = [
            makeGlossaryEntry(term: "PEDM", context: "privilege elevation and delegation management"),
            makeGlossaryEntry(term: "OAuth", context: "open standard for authentication"),
        ]
        let prompt = RosterBuilder.buildPrompt(participants: participants, contacts: [], glossary: glossary)
        XCTAssertTrue(prompt.contains("PEDM"))
        XCTAssertTrue(prompt.contains("Technical terms"))
    }

    func testCorrectionsAppendedWhenTheyFit() {
        let participants = makeParticipants(others: [("a@example.com", "Aname")])
        let prompt = RosterBuilder.buildPrompt(
            participants: participants,
            contacts: [],
            glossary: [],
            corrections: ["Ratchna": "Rachana"]
        )
        XCTAssertTrue(prompt.contains("Ratchna→Rachana"))
    }

    // MARK: Failure / empty cases

    func testNilParticipantsReturnsEmptyPrompt() {
        let prompt = RosterBuilder.buildPrompt(participants: nil, contacts: [], glossary: [])
        XCTAssertEqual(prompt, "")
    }

    func testEmptyParticipantsReturnsEmptyPrompt() {
        let participants = MeetingParticipants(
            meetingTitle: nil, myEmail: "", myFirstName: "", attendeeEmails: [],
            attendeeFirstNames: [], participants: []
        )
        let prompt = RosterBuilder.buildPrompt(participants: participants, contacts: [], glossary: [])
        XCTAssertEqual(prompt, "")
    }

    // MARK: Capping — the core discipline

    func testPromptNeverExceedsTokenBudgetWithHugeRoster() {
        // 200 attendees + 500 glossary entries: prompt must stay within budget.
        var others: [(String, String)] = []
        for i in 0..<200 {
            others.append(("p\(i)@example.com", "Attendee\(i) Longname\(i)"))
        }
        let participants = makeParticipants(others: others)
        var glossary: [AppConfiguration.Transcription.GlossaryEntry] = []
        for i in 0..<500 {
            glossary.append(makeGlossaryEntry(term: "Term\(i)"))
        }
        let prompt = RosterBuilder.buildPrompt(participants: participants, contacts: [], glossary: glossary)
        XCTAssertLessThanOrEqual(RosterBuilder.estimateTokens(prompt), RosterBuilder.tokenBudget)
        XCTAssertLessThanOrEqual(RosterBuilder.wordCount(prompt), RosterBuilder.wordBudget)
    }

    func testNamesDroppedFromTailNeverTruncatedMidName() {
        // A roster long enough that tail names must be dropped. Every name that
        // survives must appear whole — no partial names like "Mukesh Marod".
        var others: [(String, String)] = []
        for i in 0..<150 {
            others.append(("p\(i)@example.com", "Personname\(i) Someotherpart\(i)"))
        }
        let participants = makeParticipants(others: others)
        let prompt = RosterBuilder.buildPrompt(participants: participants, contacts: [], glossary: [])

        // Every full name present in the prompt must be complete.
        let allNames = (0..<150).flatMap { ["Personname\($0) Someotherpart\($0)"] }
        for name in allNames {
            if prompt.contains(name.components(separatedBy: " ").first!) {
                // If any part of the name made it in, the full name must be there.
                XCTAssertTrue(
                    prompt.contains(name),
                    "Name truncated mid-name: expected '\(name)' to appear fully if its first part appeared"
                )
            }
        }
        XCTAssertLessThanOrEqual(RosterBuilder.estimateTokens(prompt), RosterBuilder.tokenBudget)
    }

    func testGlossaryDroppedBeforeNamesWhenTight() {
        // Names take priority: with a very long roster + long terms, terms go first.
        var others: [(String, String)] = []
        for i in 0..<120 {
            others.append(("p\(i)@example.com", "Attendee\(i) Extra\(i)"))
        }
        let participants = makeParticipants(others: others)
        let glossary = (0..<50).map { makeGlossaryEntry(term: "VeryLongTechnicalTerm\($0)") }
        let prompt = RosterBuilder.buildPrompt(participants: participants, contacts: [], glossary: glossary)
        XCTAssertLessThanOrEqual(RosterBuilder.estimateTokens(prompt), RosterBuilder.tokenBudget)
        // Organizer name must survive
        XCTAssertTrue(prompt.contains("Dan"))
    }

    func testExtremelyLongSingleNameStillFitsAlone() {
        // Even a pathological single very long name must not be truncated mid-name:
        // the loop drops whole names, so the result is either the full name or empty.
        let longName = "A" + String(repeating: "b", count: 1000)
        let participants = makeParticipants(others: [("x@example.com", longName)])
        let prompt = RosterBuilder.buildPrompt(participants: participants, contacts: [], glossary: [])
        // The name either appears in full or the prompt fell back to empty.
        XCTAssertTrue(prompt.isEmpty || prompt.contains(longName))
    }

    // MARK: Token estimator sanity

    func testEstimateTokensMonotonicAndNonZero() {
        XCTAssertGreaterThan(RosterBuilder.estimateTokens("hello world"), 0)
        XCTAssertGreaterThan(
            RosterBuilder.estimateTokens("one two three four five"),
            RosterBuilder.estimateTokens("one two")
        )
        XCTAssertEqual(RosterBuilder.estimateTokens(""), 0)
    }

    // MARK: Glossary ranking

    func testPersonContextTermsRankedBeforeTechnical() {
        let glossary = [
            makeGlossaryEntry(term: "OAuth", context: "authentication standard"),
            makeGlossaryEntry(term: "Krishnan", context: "team engineer"),
        ]
        let ranked = RosterBuilder.rankedGlossaryTerms(glossary: glossary, exclude: [])
        XCTAssertEqual(ranked.first, "Krishnan")
    }

    func testGlossaryTermsExcludedWhenAlreadyInRoster() {
        let glossary = [makeGlossaryEntry(term: "Rachana Reddy", context: "team lead")]
        let ranked = RosterBuilder.rankedGlossaryTerms(glossary: glossary, exclude: ["rachana reddy"])
        XCTAssertTrue(ranked.isEmpty)
    }
}
