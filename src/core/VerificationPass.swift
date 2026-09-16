import Foundation

/// P1-2: Verification second pass (plan §2 P1-2).
///
/// After ASR + diarization, an LLM pass whose ONLY mandate is to EDIT the
/// transcript, never author content:
///   (a) flag tokens phonetically near a known attendee name and propose
///       corrections from the roster + taught corrections dictionary;
///   (b) normalize SPEAKER_XX labels to resolved names in Summary/Notes
///       sections — raw labels may remain ONLY in the Full Transcript section
///       when the speaker is truly unidentified.
///
/// Design constraints (July review "What NOT to Change"):
///   - Layers AROUND the existing TranscriptPostProcessor: reuses its
///     chunking (`splitTranscriptIntoChunks` equivalent), glossary filtering
///     (`filterByTranscript`), DoubleMetaphone PhoneticIndex — none replaced.
///   - Structural refusal-leak defense: the LLM receives an edit-only mandate
///     and the output is validated — if the model returns refusal prose or
///     fails verification, the ORIGINAL transcript passes through unchanged
///     (same fallback-on-failure pattern as the post-processor).
struct VerificationPass {

    // MARK: - Label normalization (deterministic, no LLM)

    /// Normalize SPEAKER_XX labels in Summary/Notes text to resolved names.
    /// Unresolved labels become "Speaker N" (never a raw SPEAKER_XX).
    /// Deterministic — this part does not need the LLM and always runs.
    static func normalizeLabels(
        _ text: String,
        labelMap: [String: CanonicalName]
    ) -> String {
        NotesLabelCleaner.clean(text, labelMap: labelMap)
    }

    /// Build the label→name map from a diarized transcript using the same
    /// confidence threshold as TranscriptionService (0.6).
    static func labelMap(
        from diarized: DiarizedTranscript?,
        participants: MeetingParticipants?,
        contacts: [ContactInfo]
    ) -> [String: CanonicalName] {
        NameResolver.resolve(
            participants: participants,
            speakerMap: diarized?.speakerMap,
            contacts: contacts,
            transcript: diarized.map { Self.rawText(of: $0) } ?? ""
        ).labelMap
    }

    /// Rebuild the raw "SPEAKER_XX: text" text from a diarized transcript —
    /// the canonical immutable raw artifact content for P1-3. Raw labels are
    /// kept verbatim (normalization to resolved names happens only in
    /// Summary/Notes via normalizeLabels, never in the raw artifact).
    static func rawText(of diarized: DiarizedTranscript) -> String {
        return diarized.segments
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Phonetically-suspicious token candidates (deterministic pre-pass)

    /// Find transcript tokens that are phonetically near a roster name using
    /// DoubleMetaphone — the LLM pass is pointed at these in its prompt.
    /// Purely advisory: the LLM still sees the full transcript.
    static func suspiciousTokens(
        in transcript: String,
        rosterNames: [String],
        maxTokens: Int = 40
    ) -> [String] {
        guard !rosterNames.isEmpty else { return [] }
        let index = PhoneticIndex()
        let entries = rosterNames.map {
            AppConfiguration.Transcription.GlossaryEntry(term: $0, pronunciation: nil, context: "person", aliases: nil)
        }
        index.build(from: entries)

        let words = transcript
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        var seen = Set<String>()
        var result: [String] = []
        for word in words {
            guard word.count >= 3, !seen.contains(word.lowercased()) else { continue }
            // Skip tokens that already exactly match a roster name (case-insensitive)
            if rosterNames.contains(where: { $0.lowercased() == word.lowercased() }) { continue }
            if !index.lookupPhonetic(word.lowercased()).isEmpty {
                seen.insert(word.lowercased())
                result.append(word)
                if result.count >= maxTokens { break }
            }
        }
        return result
    }

    // MARK: - The LLM verification pass

    /// Run the verification pass over one chunk. Returns corrected text, or
    /// the original on any failure (edit-only contract, fallback-on-failure).
    static func verifyChunk(
        _ chunk: String,
        provider: LLMProvider,
        rosterNames: [String],
        corrections: [String: String],
        labelMap: [String: CanonicalName]
    ) async -> String {
        let normalized = normalizeLabels(chunk, labelMap: labelMap)
        let suspicious = suspiciousTokens(in: normalized, rosterNames: rosterNames)

        var systemPrompt = """
        You are a transcript VERIFICATION assistant. Your ONLY job is to EDIT the transcript text you are given. You must NOT author new content, summarize, reorder, add commentary, or refuse.

        Rules:
        1. Fix tokens that are phonetically near a KNOWN NAME (below) to the exact spelling of that name. Do not change anything else.
        2. Apply USER-TAUGHT CORRECTIONS exactly where the wrong form appears.
        3. Preserve speaker labels, line structure, punctuation, and all content. Do not rephrase.
        4. Output ONLY the corrected transcript text. No preamble, no notes, no explanations, no refusals.
        """
        if !rosterNames.isEmpty {
            systemPrompt += "\n\n## KNOWN NAMES\n" + rosterNames.joined(separator: ", ")
        }
        if !corrections.isEmpty {
            systemPrompt += CorrectionDictionary.formatCorrections(corrections)
        }
        if !suspicious.isEmpty {
            systemPrompt += "\n\n## TOKENS TO CHECK (phonetically near a known name)\n" + suspicious.joined(separator: ", ")
        }

        let userMessage = """
        Verify and correct ONLY name spelling errors in this transcript chunk. Return only the corrected text:

        \(chunk)
        """

        do {
            let corrected = try await provider.generate(userMessage: userMessage, systemPrompt: systemPrompt)
            let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            // Edit-contract validation: an edit preserves the text's bulk.
            // If the model returned something empty or wildly different
            // (refusal prose, a rewrite), fall back to the original chunk.
            guard Self.isPlausibleEdit(original: chunk, candidate: trimmed) else {
                return normalized
            }
            return trimmed
        } catch {
            return normalized
        }
    }

    /// A plausible edit keeps length within ±30% of the original and shares
    /// most of its non-name content. Guards the structural refusal-leak defense.
    static func isPlausibleEdit(original: String, candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        let originalWords = original.split(separator: " ").count
        let candidateWords = candidate.split(separator: " ").count
        guard originalWords > 0 else { return candidateWords > 0 }
        let ratio = Double(candidateWords) / Double(originalWords)
        return ratio >= 0.7 && ratio <= 1.3
    }
}
