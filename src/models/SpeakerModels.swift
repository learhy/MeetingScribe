import Foundation

// MARK: - Core Models

/// A speaker in the database
struct Speaker: Identifiable, Codable, Hashable {
    let id: String
    var name: String?
    var nameConfidence: Double?
    var email: String?
    var embeddingCount: Int
    var createdAt: Date
    var lastSeenAt: Date?
    
    var displayName: String {
        name ?? "Speaker \(id.prefix(8))..."
    }
    
    var isNamed: Bool {
        name != nil && !name!.isEmpty
    }
    
    /// Convenience alias for lastSeenAt
    var lastSeen: Date {
        lastSeenAt ?? createdAt
    }
    
    enum CodingKeys: String, CodingKey {
        case id = "speaker_id"
        case name
        case nameConfidence = "name_confidence"
        case email
        case embeddingCount = "embedding_count"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
    }
}

/// A pending name suggestion requiring user confirmation
struct PendingNameSuggestion: Identifiable, Codable {
    let id: String
    let speakerId: String
    let suggestedName: String
    let source: String
    let confidence: Double
    let context: String?
    let createdAt: Date
    
    var sourceDescription: String {
        switch source {
        case "transcript": return "Mentioned in transcript"
        case "calendar": return "From calendar event"
        case "manual": return "Manually suggested"
        default: return source.capitalized
        }
    }
    
    var confidenceLevel: ConfidenceLevel {
        switch confidence {
        case 0.8...: return .high
        case 0.5..<0.8: return .medium
        default: return .low
        }
    }
    
    enum ConfidenceLevel {
        case high, medium, low
        
        var description: String {
            switch self {
            case .high: return "High confidence"
            case .medium: return "Medium confidence"
            case .low: return "Low confidence"
            }
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case id = "suggestion_id"
        case speakerId = "speaker_id"
        case suggestedName = "suggested_name"
        case source
        case confidence
        case context
        case createdAt = "created_at"
    }
}

/// A term associated with a speaker
struct SpeakerTerm: Codable {
    let text: String
    let category: String
    let frequency: Int
}

/// An embedding sample for a speaker
struct SpeakerEmbedding: Codable {
    let embeddingId: String
    let audioSource: String?
    let qualityScore: Double?
    let createdAt: Date
    
    enum CodingKeys: String, CodingKey {
        case embeddingId = "embedding_id"
        case audioSource = "audio_source"
        case qualityScore = "quality_score"
        case createdAt = "created_at"
    }
}

/// Detailed speaker information including terms and embeddings
struct SpeakerDetail: Codable {
    let speaker: Speaker
    let terms: [SpeakerTerm]
    let embeddings: [SpeakerEmbedding]
    let pendingNames: [PendingNameSuggestion]
    
    enum CodingKeys: String, CodingKey {
        case speaker
        case terms
        case embeddings
        case pendingNames = "pending_names"
    }
}

/// Database statistics
struct DatabaseStats: Codable {
    let speakerCount: Int
    let namedSpeakerCount: Int
    let embeddingCount: Int
    let cacheCount: Int
    let termCount: Int
    let pendingCount: Int
    let dbSizeMb: Double
    
    // Computed properties for UI convenience
    var totalSpeakers: Int { speakerCount }
    var namedSpeakers: Int { namedSpeakerCount }
    var totalEmbeddings: Int { embeddingCount }
    var pendingSuggestions: Int { pendingCount }
    var databaseSizeBytes: Int { Int(dbSizeMb * 1024 * 1024) }
    
    enum CodingKeys: String, CodingKey {
        case speakerCount = "speaker_count"
        case namedSpeakerCount = "named_speaker_count"
        case embeddingCount = "embedding_count"
        case cacheCount = "cache_count"
        case termCount = "term_count"
        case pendingCount = "pending_count"
        case dbSizeMb = "db_size_mb"
    }
}

// MARK: - CLI Response Wrappers

/// Generic wrapper for CLI JSON responses
struct CLIResponse<T: Codable>: Codable {
    let success: Bool
    let data: T?
    let error: String?
    let timestamp: String
}

/// Response for confirm command
struct ConfirmResponse: Codable {
    let confirmed: Bool
    let suggestionId: String
    let speakerId: String
    let name: String
    
    enum CodingKeys: String, CodingKey {
        case confirmed
        case suggestionId = "suggestion_id"
        case speakerId = "speaker_id"
        case name
    }
}

/// Response for reject command
struct RejectResponse: Codable {
    let rejected: Bool
    let suggestionId: String
    
    enum CodingKeys: String, CodingKey {
        case rejected
        case suggestionId = "suggestion_id"
    }
}

/// Response for rename command
struct RenameResponse: Codable {
    let renamed: Bool
    let speakerId: String
    let name: String
    
    enum CodingKeys: String, CodingKey {
        case renamed
        case speakerId = "speaker_id"
        case name
    }
}

/// Response for merge command
struct MergeResponse: Codable {
    let merged: Bool
    let keptSpeakerId: String
    let mergedSpeakerId: String
    let backupPath: String
    let embeddingsTransferred: Int?
    
    enum CodingKeys: String, CodingKey {
        case merged
        case keptSpeakerId = "kept_speaker_id"
        case mergedSpeakerId = "merged_speaker_id"
        case backupPath = "backup_path"
        case embeddingsTransferred = "embeddings_transferred"
    }
}

/// Response for split command
struct SplitResponse: Codable {
    let split: Bool
    let originalSpeakerId: String
    let newSpeakerId: String
    let embeddingsMoved: Int
    let backupPath: String
    
    enum CodingKeys: String, CodingKey {
        case split
        case originalSpeakerId = "original_speaker_id"
        case newSpeakerId = "new_speaker_id"
        case embeddingsMoved = "embeddings_moved"
        case backupPath = "backup_path"
    }
}

/// Response for delete command
struct DeleteResponse: Codable {
    let deleted: Bool
    let speakerId: String
    let backupPath: String
    
    enum CodingKeys: String, CodingKey {
        case deleted
        case speakerId = "speaker_id"
        case backupPath = "backup_path"
    }
}

/// Response for cleanup command
struct CleanupResponse: Codable {
    let backupPath: String
    let staleSpeakersRemoved: Int
    let orphanedEmbeddingsRemoved: Int
    let cacheEntriesPruned: Int
    let expiredSuggestionsRemoved: Int?
    
    enum CodingKeys: String, CodingKey {
        case backupPath = "backup_path"
        case staleSpeakersRemoved = "stale_speakers_removed"
        case orphanedEmbeddingsRemoved = "orphaned_embeddings_removed"
        case cacheEntriesPruned = "cache_entries_pruned"
        case expiredSuggestionsRemoved = "expired_suggestions_removed"
    }
}

/// Response for check command
struct CheckResponse: Codable {
    let healthy: Bool
    let issues: [String]
    let totalChecks: Int?
    
    var isHealthy: Bool { healthy }
    
    enum CodingKeys: String, CodingKey {
        case healthy
        case issues
        case totalChecks = "total_checks"
    }
}

/// Response for backup command
struct BackupResponse: Codable {
    let backupPath: String
    
    enum CodingKeys: String, CodingKey {
        case backupPath = "backup_path"
    }
}
