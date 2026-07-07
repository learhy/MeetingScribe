import Foundation

// MARK: - Name Source Priority

/// Source of a name resolution, ranked by reliability (highest wins).
enum NameSource: Int, Comparable {
    case voiceMatch = 4
    case contacts = 3
    case calendar = 2
    case transcriptMention = 1

    static func < (lhs: NameSource, rhs: NameSource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Canonical Name

/// A resolved canonical name for a speaker label.
struct CanonicalName {
    let displayName: String       // "Rachana Reddy" — best full name
    let firstName: String         // "Rachana"
    let source: NameSource
    let confidence: Double
    let email: String?

    /// Creates a canonical name from a contact's best name.
    init(displayName: String, firstName: String? = nil, source: NameSource, confidence: Double, email: String? = nil) {
        self.displayName = displayName
        self.firstName = firstName ?? CanonicalName.extractFirstName(from: displayName)
        self.source = source
        self.confidence = confidence
        self.email = email
    }

    /// Extracts the first word from a display name as the first name.
    static func extractFirstName(from displayName: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstSpace = trimmed.firstIndex(of: " ") {
            return String(trimmed[..<firstSpace])
        }
        return trimmed
    }
}

// MARK: - Name Resolver

/// Merges voice-match, calendar, and contacts data into a single canonical name map.
/// Produces per-speaker-label canonical names and a flat known-people list for LLM prompts.
struct NameResolver {

    /// Minimum confidence for voice-match names (lowered from 0.8 to allow more matches,
    /// with fuzzy reconciliation catching misspellings).
    static let voiceMatchThreshold: Double = 0.6

    /// Resolve names for all speaker labels.
    ///
    /// - Parameters:
    ///   - participants: Calendar-resolved meeting participants (nil if calendar resolution failed)
    ///   - speakerMap: Diarization speaker map (label → voice-matched identity, nil = unmatched)
    ///   - contacts: Contacts fetched for meeting participant emails
    ///   - transcript: Full transcript text (for context, currently unused for NER)
    /// - Returns: Tuple of (label → canonical name, known people contacts list)
    static func resolve(
        participants: MeetingParticipants?,
        speakerMap: [String: SpeakerIdentity?]?,
        contacts: [ContactInfo],
        transcript: String
    ) -> (labelMap: [String: CanonicalName], knownPeople: [ContactInfo]) {

        // Build contacts lookup by email
        let contactsByEmail = Dictionary(
            contacts.map { ($0.email.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Build calendar participant lookup by first name (lowercased)
        var calendarByFirstName: [String: Participant] = [:]
        if let participants = participants {
            for p in participants.participants {
                calendarByFirstName[p.firstName.lowercased()] = p
            }
        }

        var labelMap: [String: CanonicalName] = [:]
        var knownPeople: [ContactInfo] = []
        var usedEmails = Set<String>()

        // 1. Process voice-matched speakers
        if let speakerMap = speakerMap {
            for (label, identity) in speakerMap {
                if let identity = identity,
                   let name = identity.name, !name.isEmpty,
                   identity.confidence >= voiceMatchThreshold {

                    // Try to reconcile against contacts for correct spelling
                    let reconciled = reconcileName(
                        voiceMatched: name,
                        contacts: contacts,
                        contactsByEmail: contactsByEmail,
                        calendarByFirstName: calendarByFirstName
                    )

                    let canonical = CanonicalName(
                        displayName: reconciled.name,
                        source: reconciled.source,
                        confidence: max(identity.confidence, reconciled.confidence),
                        email: reconciled.email
                    )
                    labelMap[label] = canonical

                    if let email = reconciled.email, let contact = contactsByEmail[email.lowercased()] {
                        if !usedEmails.contains(email.lowercased()) {
                            knownPeople.append(contact)
                            usedEmails.insert(email.lowercased())
                        }
                    }
                }
            }
        }

        // 2. Fill unmatched labels from calendar (1:1 fallback)
        if let speakerMap = speakerMap, let participants = participants {
            let unmatchedLabels = speakerMap.filter { $0.value == nil }.map { $0.key }
            let identifiedNames = Set(labelMap.values.map { $0.firstName.lowercased() })

            // Calendar attendees not already matched by voice
            let unmatchedAttendees = participants.participants.filter { p in
                !p.isMe && !identifiedNames.contains(p.firstName.lowercased())
            }

            // 1:1 case: exactly 1 unmatched speaker + 1 unmatched attendee
            if unmatchedLabels.count == 1 && unmatchedAttendees.count == 1,
               let label = unmatchedLabels.first,
               let attendee = unmatchedAttendees.first {

                let contact = contactsByEmail[attendee.email.lowercased()]
                let displayName = contact?.displayName ?? contact?.bestName ?? attendee.firstName
                let canonical = CanonicalName(
                    displayName: displayName,
                    source: contact != nil ? .contacts : .calendar,
                    confidence: 0.7,
                    email: attendee.email
                )
                labelMap[label] = canonical

                if let contact = contact, !usedEmails.contains(attendee.email.lowercased()) {
                    knownPeople.append(contact)
                    usedEmails.insert(attendee.email.lowercased())
                }
            }

            // Also try to match "me" to remaining unmatched labels
            let stillUnmatched = unmatchedLabels.filter { labelMap[$0] == nil }
            if stillUnmatched.count == 1,
               let label = stillUnmatched.first,
               let me = participants.participants.first(where: { $0.isMe }) {

                let contact = contactsByEmail[me.email.lowercased()]
                let displayName = contact?.displayName ?? contact?.bestName ?? me.firstName
                labelMap[label] = CanonicalName(
                    displayName: displayName,
                    source: contact != nil ? .contacts : .calendar,
                    confidence: 0.7,
                    email: me.email
                )

                if let contact = contact, !usedEmails.contains(me.email.lowercased()) {
                    knownPeople.append(contact)
                    usedEmails.insert(me.email.lowercased())
                }
            }
        }

        // 3. Add all contacts as known people even if not matched to a label
        for contact in contacts {
            if !usedEmails.contains(contact.email.lowercased()) {
                if contact.bestName != nil {
                    knownPeople.append(contact)
                    usedEmails.insert(contact.email.lowercased())
                }
            }
        }

        return (labelMap, knownPeople)
    }

    // MARK: - Fuzzy Reconciliation

    /// Reconcile a voice-matched name against contacts/calendar for correct spelling.
    /// If the voice-matched name is phonetically close to a contact name, use the contact spelling.
    struct ReconciledName {
        let name: String
        let source: NameSource
        let confidence: Double
        let email: String?
    }

    static func reconcileName(
        voiceMatched: String,
        contacts: [ContactInfo],
        contactsByEmail: [String: ContactInfo],
        calendarByFirstName: [String: Participant]
    ) -> ReconciledName {
        let voiceLower = voiceMatched.lowercased()
        let metaphone = DoubleMetaphone()

        /// Best full name for a contact (prefer displayName for full name, fall back to bestName)
        func fullName(for contact: ContactInfo) -> String {
            contact.displayName ?? contact.bestName ?? contact.email
        }

        /// First word of a name for matching
        func firstWord(_ name: String) -> String {
            name.split(separator: " ").first.map(String.init) ?? name
        }

        // Check exact match against contacts first
        for contact in contacts {
            let bestName = contact.bestName ?? ""
            let full = fullName(for: contact)

            // Match against preferred name or first word of display name
            if !bestName.isEmpty && bestName.lowercased() == voiceLower {
                return ReconciledName(name: full, source: .contacts, confidence: 1.0, email: contact.email)
            }
            if firstWord(full).lowercased() == voiceLower {
                return ReconciledName(name: full, source: .contacts, confidence: 0.95, email: contact.email)
            }
        }

        // Check exact match against calendar — voice-match confirmed by calendar,
        // keep .voiceMatch source since the voice match already found the right name
        if let participant = calendarByFirstName[voiceLower] {
            return ReconciledName(name: participant.firstName, source: .voiceMatch, confidence: 0.9, email: participant.email)
        }

        // Fuzzy: phonetic match against contacts
        let voiceCode = metaphone.encode(voiceMatched)
        for contact in contacts {
            guard let full = contact.displayName ?? contact.bestName else { continue }
            let contactFirstWord = firstWord(full)
            let contactCode = metaphone.encode(contactFirstWord)

            // Check phonetic match (same primary code)
            if !voiceCode.primary.isEmpty && voiceCode.primary == contactCode.primary {
                let confidence = voiceMatched.confidenceScore(comparedTo: contactFirstWord)
                if confidence >= 0.5 {
                    return ReconciledName(name: full, source: .contacts, confidence: confidence, email: contact.email)
                }
            }

            // Also check Levenshtein distance for close matches
            let distance = voiceMatched.levenshteinDistance(to: contactFirstWord)
            if distance <= 2 && contactFirstWord.count >= 4 {
                let confidence = voiceMatched.confidenceScore(comparedTo: contactFirstWord)
                if confidence >= 0.6 {
                    return ReconciledName(name: full, source: .contacts, confidence: confidence, email: contact.email)
                }
            }
        }

        // No reconciliation found — use the voice-matched name as-is
        return ReconciledName(name: voiceMatched, source: .voiceMatch, confidence: 0.8, email: nil)
    }

    // MARK: - Attendees List

    /// Build a formatted attendees string using resolved display names.
    /// Falls back to calendar first names when no contact display name is available.
    static func attendeesList(
        participants: MeetingParticipants?,
        labelMap: [String: CanonicalName],
        contacts: [ContactInfo]
    ) -> String {
        guard let participants = participants else {
            // No calendar data — use resolved names from labelMap
            let names = labelMap.values.map { $0.displayName }
            return names.isEmpty ? "" : names.joined(separator: ", ")
        }

        let contactsByEmail = Dictionary(
            contacts.map { ($0.email.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var names: [String] = []
        var seen = Set<String>()

        // Add "me" first — prefer displayName for full name
        if let me = participants.participants.first(where: { $0.isMe }) {
            let contact = contactsByEmail[me.email.lowercased()]
            let name = contact?.displayName ?? contact?.bestName ?? me.firstName
            if !name.isEmpty && !seen.contains(name.lowercased()) {
                names.append(name)
                seen.insert(name.lowercased())
            }
        } else if !participants.myFirstName.isEmpty {
            names.append(participants.myFirstName)
            seen.insert(participants.myFirstName.lowercased())
        }

        // Add other attendees — prefer displayName for full name
        for participant in participants.participants where !participant.isMe {
            let contact = contactsByEmail[participant.email.lowercased()]
            let name = contact?.displayName ?? contact?.bestName ?? participant.firstName
            if !name.isEmpty && !seen.contains(name.lowercased()) {
                names.append(name)
                seen.insert(name.lowercased())
            }
        }

        // If we still have no names, fall back to labelMap display names
        if names.isEmpty {
            let labelNames = labelMap.values.map { $0.displayName }
            return labelNames.isEmpty ? "" : labelNames.joined(separator: ", ")
        }

        return names.joined(separator: ", ")
    }
}