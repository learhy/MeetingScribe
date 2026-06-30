import Foundation

// MARK: - Canonical Name Models

/// Source of a name assignment, ranked by reliability (higher = more trustworthy).
enum NameSource: Int, Comparable {
    case transcriptMention = 1
    case calendar = 2
    case contacts = 3
    case voiceMatch = 4

    static func < (lhs: NameSource, rhs: NameSource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A canonical name resolved from one or more sources for a single speaker label.
struct CanonicalName {
    let displayName: String       // "Rachana Reddy"
    let firstName: String         // "Rachana"
    let source: NameSource         // .voiceMatch / .calendar / .contacts / .transcriptMention
    let confidence: Double
    let email: String?

    /// Neutral display label when no name could be resolved.
    /// Converts "SPEAKER_00" → "Speaker 1" (1-indexed, human-friendly).
    static func neutralLabel(for speakerLabel: String) -> String {
        // Extract the speaker number from labels like "SPEAKER_00", "SPEAKER_01"
        let pattern = #"SPEAKER_(\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: speakerLabel, range: NSRange(speakerLabel.startIndex..., in: speakerLabel)),
           let range = Range(match.range(at: 1), in: speakerLabel),
           let num = Int(speakerLabel[range]) {
            return "Speaker \(num + 1)"
        }
        // If it doesn't match the pattern, just capitalize words and replace underscores
        return speakerLabel
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

// MARK: - NameResolver

/// Merges all name sources (voice matching, calendar, contacts, transcript mentions)
/// into a single canonical map per speaker label plus a flat known-people list for LLM prompts.
///
/// This replaces the ad-hoc name resolution previously scattered across
/// `TranscriptionService.formatDiarizedTranscript`, `TranscriptPostProcessor`,
/// and `CalendarParticipantResolver`.
struct NameResolver {

    /// Configurable confidence threshold for accepting voice-matched names.
    /// Lowered from the original 0.8 to 0.6 to identify more speakers,
    /// with fuzzy reconciliation catching misspellings.
    static let voiceMatchConfidenceThreshold: Double = 0.6

    /// Maximum phonetic (Levenshtein) distance for fuzzy name reconciliation.
    /// If a voice-matched name is within this distance of a contact name,
    /// the contact spelling is preferred.
    static let maxReconcileDistance: Int = 3

    // MARK: - Resolution Result

    struct ResolutionResult {
        /// Maps each speaker label (e.g. "SPEAKER_00") to its canonical name.
        let labelMap: [String: CanonicalName]

        /// Flat list of all known people for LLM prompt injection.
        let knownPeople: [ContactInfo]
    }

    // MARK: - Resolve

    /// Resolve canonical names from all available sources.
    ///
    /// - Parameters:
    ///   - participants: Calendar-resolved meeting participants (nil if calendar failed).
    ///   - speakerMap: Diarization voice-match map (label → SpeakerIdentity?; nil = unmatched).
    ///   - contacts: Contacts fetched from the people database.
    ///   - transcript: The transcript text (for future NER-based mention extraction).
    /// - Returns: A resolution result with per-label canonical names and a flat known-people list.
    static func resolve(
        participants: MeetingParticipants?,
        speakerMap: [String: SpeakerIdentity?]?,
        contacts: [ContactInfo],
        transcript: String
    ) -> ResolutionResult {

        // Build a contacts-by-email lookup
        let contactsByEmail = Dictionary(
            contacts.map { ($0.email.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Build a contacts-by-firstName lookup for fuzzy matching
        let contactsByFirstName: [String: ContactInfo] = {
            var dict: [String: ContactInfo] = [:]
            for contact in contacts {
                if let name = contact.bestName, !name.isEmpty {
                    let firstWord = name.split(separator: " ").first.map(String.init)?.lowercased() ?? name.lowercased()
                    if dict[firstWord] == nil {
                        dict[firstWord] = contact
                    }
                }
            }
            return dict
        }()

        var labelMap: [String: CanonicalName] = [:]
        var unresolvedLabels: [String] = []

        // Collect all speaker labels from the speakerMap
        let allLabels = speakerMap?.keys.sorted() ?? []

        // 1. Process voice-matched speakers
        if let speakerMap = speakerMap {
            for label in allLabels {
                // speakerMap values are Optional<Optional<SpeakerIdentity>> — unwrap twice
                if let identity = speakerMap[label].flatMap({ $0 }), let name = identity.name, !name.isEmpty {
                    let confidence = identity.confidence

                    if confidence >= voiceMatchConfidenceThreshold {
                        // Voice match is strong enough — try fuzzy reconciliation against contacts
                        let reconciledName = reconcileName(
                            voiceMatched: name,
                            contacts: contacts,
                            contactsByEmail: contactsByEmail,
                            contactsByFirstName: contactsByFirstName
                        )

                        let source: NameSource = reconciledName.source
                        let displayName = reconciledName.displayName
                        let firstName = displayName.split(separator: " ").first.map(String.init) ?? displayName

                        labelMap[label] = CanonicalName(
                            displayName: displayName,
                            firstName: firstName,
                            source: source,
                            confidence: max(confidence, 0.85), // boost after reconciliation
                            email: reconciledName.email
                        )
                    } else {
                        // Voice match too weak — mark as unresolved for now
                        unresolvedLabels.append(label)
                    }
                } else {
                    // No identity or nil identity
                    unresolvedLabels.append(label)
                }
            }
        }

        // 2. Calendar-based assignment for unresolved speakers
        if let participants = participants {
            assignCalendarNames(
                participants: participants,
                contactsByEmail: contactsByEmail,
                labelMap: &labelMap,
                unresolvedLabels: &unresolvedLabels
            )
        }

        // 3. Build the flat knownPeople list from all sources
        var knownPeople = contacts

        // Also include voice-matched names that aren't in contacts
        let contactEmails = Set(contacts.map { $0.email.lowercased() })
        for (_, canonical) in labelMap {
            // If this name came from voice match and isn't in contacts, add a synthetic ContactInfo
            if canonical.source == .voiceMatch && canonical.email == nil {
                let syntheticContact = ContactInfo(
                    email: "voice-\(canonical.firstName.lowercased())@voice.match",
                    displayName: canonical.displayName,
                    preferredName: canonical.firstName,
                    pronunciation: nil,
                    aliases: nil,
                    role: nil,
                    team: nil,
                    source: "voice"
                )
                if !contactEmails.contains(syntheticContact.email.lowercased()) {
                    knownPeople.append(syntheticContact)
                }
            }
        }

        // Also include calendar participant names if not already covered
        if let participants = participants {
            for participant in participants.participants {
                let emailKey = participant.email.lowercased()
                if !contactEmails.contains(emailKey) {
                    // Check if this name is already covered by a voice match
                    let alreadyCovered = labelMap.values.contains { $0.firstName.lowercased() == participant.firstName.lowercased() }
                    if !alreadyCovered {
                        knownPeople.append(ContactInfo(
                            email: participant.email,
                            displayName: participant.firstName,
                            preferredName: participant.firstName,
                            pronunciation: nil,
                            aliases: nil,
                            role: nil,
                            team: nil,
                            source: "calendar"
                        ))
                    }
                }
            }
        }

        return ResolutionResult(labelMap: labelMap, knownPeople: knownPeople)
    }

    // MARK: - Fuzzy Reconciliation

    /// Check a voice-matched name against the contacts list and correct misspellings.
    /// If the voice-matched name is phonetically close to a contact name, prefer the contact spelling.
    struct ReconciledName {
        let displayName: String
        let email: String?
        let source: NameSource
    }

    static func reconcileName(
        voiceMatched: String,
        contacts: [ContactInfo],
        contactsByEmail: [String: ContactInfo],
        contactsByFirstName: [String: ContactInfo]
    ) -> ReconciledName {

        let voiceLower = voiceMatched.lowercased()
        let voiceFirstWord = voiceMatched.split(separator: " ").first.map(String.init)?.lowercased() ?? voiceLower

        // Helper: get the best display name for a contact (prefer displayName for full name)
        func fullName(for contact: ContactInfo) -> String {
            contact.displayName ?? contact.preferredName ?? contact.email
        }

        // 1. Exact match on full name (case-insensitive)
        for contact in contacts {
            if let name = contact.bestName, name.lowercased() == voiceLower {
                return ReconciledName(displayName: fullName(for: contact), email: contact.email, source: .contacts)
            }
        }

        // 2. Exact match on first name
        if let contact = contactsByFirstName[voiceFirstWord] {
            return ReconciledName(displayName: fullName(for: contact), email: contact.email, source: .contacts)
        }

        // 3. Fuzzy match using Levenshtein distance on first name
        let metaphone = DoubleMetaphone()
        let voiceCode = metaphone.encode(voiceFirstWord)

        var bestMatch: (contact: ContactInfo, distance: Int)? = nil

        for contact in contacts {
            let contactFullName = fullName(for: contact)
            guard !contactFullName.isEmpty else { continue }

            // Compare against both the first word of the full name AND the preferred name
            // (preferred name may be a nickname that's closer to the voice-matched name)
            let candidateNames: [String] = [
                contactFullName.split(separator: " ").first.map(String.init)?.lowercased() ?? contactFullName.lowercased(),
                contact.preferredName?.lowercased() ?? "",
                contact.displayName?.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
            ].filter { !$0.isEmpty }

            var bestDistanceForContact = Int.max
            for candidate in candidateNames {
                let distance = voiceFirstWord.levenshteinDistance(to: candidate)
                if distance < bestDistanceForContact {
                    bestDistanceForContact = distance
                }
            }

            if bestDistanceForContact <= maxReconcileDistance {
                // Check if this is a better match than what we have
                if bestMatch == nil || bestDistanceForContact < bestMatch!.distance {
                    // Also check phonetic match for extra confidence
                    let contactCode = metaphone.encode(candidateNames[0])

                    if voiceCode.matches(contactCode) || bestDistanceForContact <= maxReconcileDistance {
                        bestMatch = (contact, bestDistanceForContact)
                    }
                }
            }
        }

        if let match = bestMatch {
            return ReconciledName(displayName: fullName(for: match.contact), email: match.contact.email, source: .contacts)
        }

        // 4. No close match found — use the voice-matched name as-is
        return ReconciledName(displayName: voiceMatched, email: nil, source: .voiceMatch)
    }

    // MARK: - Calendar Assignment

    /// Assign calendar participant names to unresolved speaker labels.
    /// For 1:1 calls: if one speaker is matched and one isn't, assign the unmatched
    /// calendar attendee to the unresolved speaker.
    private static func assignCalendarNames(
        participants: MeetingParticipants,
        contactsByEmail: [String: ContactInfo],
        labelMap: inout [String: CanonicalName],
        unresolvedLabels: inout [String]
    ) {
        guard !unresolvedLabels.isEmpty else { return }

        // Get calendar attendee names not already matched by voice
        let resolvedNames = Set(labelMap.values.map { $0.firstName.lowercased() })
        let unmatchedNonMeParticipants = participants.participants.filter { p in
            !p.isMe && !resolvedNames.contains(p.firstName.lowercased())
        }

        // 1:1 call fallback: one unresolved speaker + one unmatched calendar attendee
        if unresolvedLabels.count == 1 && unmatchedNonMeParticipants.count == 1,
           let label = unresolvedLabels.first,
           let attendee = unmatchedNonMeParticipants.first {

            // Enrich with contact data if available
            let contact = contactsByEmail[attendee.email.lowercased()]
            let displayName = contact?.displayName ?? contact?.preferredName ?? attendee.firstName

            labelMap[label] = CanonicalName(
                displayName: displayName,
                firstName: attendee.firstName,
                source: contact != nil ? .contacts : .calendar,
                confidence: 0.75, // calendar inference — decent but not voice-grade
                email: attendee.email
            )
            unresolvedLabels.removeAll { $0 == label }
            return
        }

        // Group call: try to match unresolved speakers to ALL unmatched calendar participants (including "me")
        let meAssigned = labelMap.values.contains {
            $0.email == participants.myEmail || $0.firstName.lowercased() == participants.myFirstName.lowercased()
        }
        var allUnmatchedParticipants = unmatchedNonMeParticipants
        if !meAssigned, let meParticipant = participants.participants.first(where: { $0.isMe }) {
            allUnmatchedParticipants.append(meParticipant)
        }

        // Only assign if counts match exactly (unambiguous)
        if unresolvedLabels.count == allUnmatchedParticipants.count {
            // Sort both for deterministic assignment
            let sortedLabels = unresolvedLabels.sorted()
            let sortedAttendees = allUnmatchedParticipants.sorted { $0.firstName < $1.firstName }

            for (label, attendee) in zip(sortedLabels, sortedAttendees) {
                let contact = contactsByEmail[attendee.email.lowercased()]
                let displayName = contact?.displayName ?? contact?.preferredName ?? attendee.firstName

                labelMap[label] = CanonicalName(
                    displayName: displayName,
                    firstName: attendee.firstName,
                    source: contact != nil ? .contacts : .calendar,
                    confidence: 0.6,
                    email: attendee.email
                )
            }
            unresolvedLabels.removeAll()
            return
        }

        // "Me" assignment: if there are still unresolved labels and "me" hasn't been assigned,
        // and there's exactly one unresolved label left, assign "me"
        if !meAssigned && unresolvedLabels.count == 1 && participants.participants.count >= 1,
           let label = unresolvedLabels.first {

            let contact = contactsByEmail[participants.myEmail.lowercased()]
            let displayName = contact?.displayName ?? contact?.preferredName ?? participants.myFirstName

            labelMap[label] = CanonicalName(
                displayName: displayName,
                firstName: participants.myFirstName,
                source: contact != nil ? .contacts : .calendar,
                confidence: 0.6,
                email: participants.myEmail
            )
            unresolvedLabels.removeAll { $0 == label }
        }
    }

    // MARK: - Attendees List

    /// Build a formatted attendees string using resolved display names.
    /// Falls back to calendar first names when no resolution is available.
    /// Strips any SPEAKER_XX artifacts.
    static func attendeesList(
        participants: MeetingParticipants?,
        labelMap: [String: CanonicalName]
    ) -> String {
        guard let participants = participants else {
            // No calendar participants — try to build from labelMap
            let names = labelMap.values.sorted { $0.firstName < $1.firstName }.map { $0.displayName }
            return names.isEmpty ? "" : names.joined(separator: ", ")
        }

        // Build a set of resolved display names from the label map
        let resolvedDisplayNames = Set(labelMap.values.map { $0.displayName.lowercased() })
        var attendees: [String] = []
        var seen: Set<String> = []

        // Add "me" first
        let meContact = participants.participants.first(where: { $0.isMe })
        let myDisplayName: String = {
            // Check if "me" was resolved via labelMap
            let meFromMap = labelMap.values.first { $0.email == participants.myEmail }
            if let me = meFromMap { return me.displayName }
            return meContact?.firstName ?? participants.myFirstName
        }()

        if !myDisplayName.isEmpty && !seen.contains(myDisplayName.lowercased()) {
            attendees.append(myDisplayName)
            seen.insert(myDisplayName.lowercased())
        }

        // Add other attendees
        for participant in participants.participants where !participant.isMe {
            // Check if this participant was resolved via labelMap
            let fromMap = labelMap.values.first { $0.email == participant.email }
            let displayName = fromMap?.displayName ?? participant.firstName

            if !displayName.isEmpty && !seen.contains(displayName.lowercased()) {
                // Skip if already covered by a resolved name that matches
                if !resolvedDisplayNames.contains(displayName.lowercased()) || fromMap != nil {
                    attendees.append(displayName)
                    seen.insert(displayName.lowercased())
                }
            }
        }

        // Add any voice-matched names not in calendar
        for canonical in labelMap.values {
            if canonical.email == nil && !seen.contains(canonical.displayName.lowercased()) {
                attendees.append(canonical.displayName)
                seen.insert(canonical.displayName.lowercased())
            }
        }

        return attendees.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    // MARK: - Label → Display Name Map (for transcript formatting)

    /// Build a simple label → display name string map for use in transcript formatting.
    static func displayNameMap(from result: ResolutionResult) -> [String: String] {
        var map: [String: String] = [:]
        for (label, canonical) in result.labelMap {
            map[label] = canonical.displayName
        }
        return map
    }
}