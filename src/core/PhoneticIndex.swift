import Foundation

/// Index for efficient phonetic lookup of glossary entries
/// Pre-computes Double Metaphone codes at build time for O(1) lookup at query time
class PhoneticIndex {
    
    typealias GlossaryEntry = AppConfiguration.Transcription.GlossaryEntry
    
    /// Maps phonetic code -> list of matching glossary entries
    private var phoneticIndex: [String: [GlossaryEntry]] = [:]
    
    /// Maps exact term/alias (lowercased) -> glossary entry for exact matching
    private var exactIndex: [String: GlossaryEntry] = [:]
    
    /// All indexed entries
    private(set) var entries: [GlossaryEntry] = []
    
    /// Double Metaphone encoder
    private let metaphone = DoubleMetaphone()
    
    /// Logger for observability
    private let logger = DualLogger(category: "PhoneticIndex")
    
    /// Build index from glossary entries
    /// - Parameter entries: Glossary entries to index
    /// - Complexity: O(n) where n is number of entries
    func build(from entries: [GlossaryEntry]) {
        let startTime = Date()
        
        self.entries = entries
        phoneticIndex.removeAll()
        exactIndex.removeAll()
        
        for entry in entries {
            // Index exact matches for term and aliases
            let term = entry.term.lowercased()
            exactIndex[term] = entry
            
            if let aliases = entry.aliases {
                for alias in aliases {
                    exactIndex[alias.lowercased()] = entry
                }
            }
            
            // Index phonetic codes for first word only (handles multi-word terms)
            let firstWord = entry.firstWord
            let result = metaphone.encode(firstWord)
            
            // Add to primary code index
            if !result.primary.isEmpty {
                phoneticIndex[result.primary, default: []].append(entry)
            }
            
            // Add to secondary code index if different
            if !result.secondary.isEmpty && result.secondary != result.primary {
                phoneticIndex[result.secondary, default: []].append(entry)
            }
            
            // Also index aliases phonetically
            if let aliases = entry.aliases {
                for alias in aliases {
                    let aliasFirstWord = alias.split(separator: " ").first.map(String.init) ?? alias
                    let aliasResult = metaphone.encode(aliasFirstWord)
                    
                    if !aliasResult.primary.isEmpty {
                        // Avoid duplicates
                        if !phoneticIndex[aliasResult.primary, default: []].contains(where: { $0.term == entry.term }) {
                            phoneticIndex[aliasResult.primary, default: []].append(entry)
                        }
                    }
                    if !aliasResult.secondary.isEmpty && aliasResult.secondary != aliasResult.primary {
                        if !phoneticIndex[aliasResult.secondary, default: []].contains(where: { $0.term == entry.term }) {
                            phoneticIndex[aliasResult.secondary, default: []].append(entry)
                        }
                    }
                }
            }
        }
        
        let elapsed = Date().timeIntervalSince(startTime) * 1000
        logger.info("Built phonetic index: \(entries.count) entries, \(phoneticIndex.count) phonetic codes in \(String(format: "%.1f", elapsed))ms")
    }
    
    /// Look up entries by exact term/alias match
    /// - Parameter term: Term to look up (case-insensitive)
    /// - Returns: Matching entry or nil
    func lookupExact(_ term: String) -> GlossaryEntry? {
        return exactIndex[term.lowercased()]
    }
    
    /// Look up entries by phonetic code
    /// - Parameter word: Word to encode and look up
    /// - Returns: List of phonetically similar glossary entries
    func lookupPhonetic(_ word: String) -> [GlossaryEntry] {
        let result = metaphone.encode(word)
        
        var matches: Set<String> = []  // Track by term to avoid duplicates
        var entries: [GlossaryEntry] = []
        
        // Check primary code
        if let primaryMatches = phoneticIndex[result.primary] {
            for entry in primaryMatches {
                if !matches.contains(entry.term) {
                    matches.insert(entry.term)
                    entries.append(entry)
                }
            }
        }
        
        // Check secondary code
        if let secondaryMatches = phoneticIndex[result.secondary] {
            for entry in secondaryMatches {
                if !matches.contains(entry.term) {
                    matches.insert(entry.term)
                    entries.append(entry)
                }
            }
        }
        
        return entries
    }
    
    /// Check if a word has any exact match in the index
    /// - Parameter word: Word to check (case-insensitive)
    /// - Returns: True if exact match exists
    func hasExactMatch(_ word: String) -> Bool {
        return exactIndex[word.lowercased()] != nil
    }
    
    /// Get phonetic code for a word (for debugging/testing)
    func getPhoneticCode(_ word: String) -> DoubleMetaphone.Result {
        return metaphone.encode(word)
    }
}

// MARK: - Levenshtein Distance for Confidence Scoring

extension String {
    /// Calculate Levenshtein distance to another string
    /// - Parameter other: String to compare to
    /// - Returns: Edit distance (number of insertions, deletions, substitutions)
    func levenshteinDistance(to other: String) -> Int {
        let s = Array(self.lowercased())
        let t = Array(other.lowercased())
        
        let m = s.count
        let n = t.count
        
        // Handle empty strings
        if m == 0 { return n }
        if n == 0 { return m }
        
        // Create distance matrix
        var d = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        
        // Initialize first row and column
        for i in 0...m { d[i][0] = i }
        for j in 0...n { d[0][j] = j }
        
        // Fill in the rest
        for i in 1...m {
            for j in 1...n {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                d[i][j] = Swift.min(
                    d[i - 1][j] + 1,      // deletion
                    d[i][j - 1] + 1,      // insertion
                    d[i - 1][j - 1] + cost // substitution
                )
            }
        }
        
        return d[m][n]
    }
    
    /// Calculate confidence score (0.0 to 1.0) compared to another string
    /// Higher is better. 1.0 = exact match
    func confidenceScore(comparedTo other: String) -> Double {
        let distance = self.levenshteinDistance(to: other)
        let maxLen = max(self.count, other.count)
        if maxLen == 0 { return 1.0 }
        return 1.0 - (Double(distance) / Double(maxLen))
    }
}
