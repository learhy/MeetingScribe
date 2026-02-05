import Foundation

/// Double Metaphone phonetic algorithm implementation
/// Based on Lawrence Philips' algorithm, producing primary and secondary codes
/// Reference: https://en.wikipedia.org/wiki/Metaphone#Double_Metaphone
class DoubleMetaphone {
    
    /// Result containing primary and secondary phonetic codes
    struct Result {
        let primary: String
        let secondary: String
        
        /// Returns true if either code matches the given code
        func matches(_ other: Result) -> Bool {
            return primary == other.primary || 
                   primary == other.secondary ||
                   secondary == other.primary ||
                   secondary == other.secondary
        }
    }
    
    /// Maximum length of metaphone codes
    private let maxCodeLength = 4
    
    /// Vowel characters
    private static let vowels: Set<Character> = ["A", "E", "I", "O", "U"]
    
    /// Generate Double Metaphone codes for a word
    /// - Parameter word: The word to encode
    /// - Returns: Result containing primary and secondary codes
    func encode(_ word: String) -> Result {
        guard !word.isEmpty else {
            return Result(primary: "", secondary: "")
        }
        
        let upper = word.uppercased()
        let chars = Array(upper)
        let length = chars.count
        
        var primary = ""
        var secondary = ""
        var current = 0
        
        // Skip initial silent letters
        if hasPrefix(chars, ["GN", "KN", "PN", "WR", "PS"]) {
            current += 1
        }
        
        // Initial X is pronounced Z
        if chars[0] == "X" {
            primary += "S"
            secondary += "S"
            current += 1
        }
        
        while current < length && (primary.count < maxCodeLength || secondary.count < maxCodeLength) {
            let char = chars[current]
            
            switch char {
            case "A", "E", "I", "O", "U":
                // Vowels at start
                if current == 0 {
                    primary += "A"
                    secondary += "A"
                }
                current += 1
                
            case "B":
                primary += "P"
                secondary += "P"
                current += (current + 1 < length && chars[current + 1] == "B") ? 2 : 1
                
            case "Ç":
                primary += "S"
                secondary += "S"
                current += 1
                
            case "C":
                (primary, secondary, current) = handleC(chars, current, length, primary, secondary)
                
            case "D":
                (primary, secondary, current) = handleD(chars, current, length, primary, secondary)
                
            case "F":
                primary += "F"
                secondary += "F"
                current += (current + 1 < length && chars[current + 1] == "F") ? 2 : 1
                
            case "G":
                (primary, secondary, current) = handleG(chars, current, length, primary, secondary)
                
            case "H":
                // H is silent if between vowels or after certain consonants
                if current == 0 || (current > 0 && Self.vowels.contains(chars[current - 1])) {
                    if current + 1 < length && Self.vowels.contains(chars[current + 1]) {
                        primary += "H"
                        secondary += "H"
                    }
                }
                current += 1
                
            case "J":
                (primary, secondary, current) = handleJ(chars, current, length, primary, secondary)
                
            case "K":
                primary += "K"
                secondary += "K"
                current += (current + 1 < length && chars[current + 1] == "K") ? 2 : 1
                
            case "L":
                primary += "L"
                secondary += "L"
                current += (current + 1 < length && chars[current + 1] == "L") ? 2 : 1
                
            case "M":
                primary += "M"
                secondary += "M"
                current += (current + 1 < length && chars[current + 1] == "M") ? 2 : 1
                
            case "N":
                primary += "N"
                secondary += "N"
                current += (current + 1 < length && chars[current + 1] == "N") ? 2 : 1
                
            case "Ñ":
                primary += "N"
                secondary += "N"
                current += 1
                
            case "P":
                if current + 1 < length && chars[current + 1] == "H" {
                    primary += "F"
                    secondary += "F"
                    current += 2
                } else {
                    primary += "P"
                    secondary += "P"
                    current += (current + 1 < length && chars[current + 1] == "P") ? 2 : 1
                }
                
            case "Q":
                primary += "K"
                secondary += "K"
                current += (current + 1 < length && chars[current + 1] == "Q") ? 2 : 1
                
            case "R":
                primary += "R"
                secondary += "R"
                current += (current + 1 < length && chars[current + 1] == "R") ? 2 : 1
                
            case "S":
                (primary, secondary, current) = handleS(chars, current, length, primary, secondary)
                
            case "T":
                (primary, secondary, current) = handleT(chars, current, length, primary, secondary)
                
            case "V":
                primary += "F"
                secondary += "F"
                current += (current + 1 < length && chars[current + 1] == "V") ? 2 : 1
                
            case "W":
                (primary, secondary, current) = handleW(chars, current, length, primary, secondary)
                
            case "X":
                primary += "KS"
                secondary += "KS"
                current += (current + 1 < length && chars[current + 1] == "X") ? 2 : 1
                
            case "Z":
                primary += "S"
                secondary += "S"
                current += (current + 1 < length && chars[current + 1] == "Z") ? 2 : 1
                
            default:
                current += 1
            }
        }
        
        return Result(
            primary: String(primary.prefix(maxCodeLength)),
            secondary: String(secondary.prefix(maxCodeLength))
        )
    }
    
    // MARK: - Helper Methods
    
    private func hasPrefix(_ chars: [Character], _ prefixes: [String]) -> Bool {
        let str = String(chars)
        return prefixes.contains { str.hasPrefix($0) }
    }
    
    private func substringAt(_ chars: [Character], _ start: Int, _ len: Int) -> String {
        guard start >= 0 && start < chars.count else { return "" }
        let end = min(start + len, chars.count)
        return String(chars[start..<end])
    }
    
    private func isVowel(_ chars: [Character], _ index: Int) -> Bool {
        guard index >= 0 && index < chars.count else { return false }
        return Self.vowels.contains(chars[index])
    }
    
    // MARK: - Character Handlers
    
    private func handleC(_ chars: [Character], _ current: Int, _ length: Int, 
                         _ primary: String, _ secondary: String) -> (String, String, Int) {
        var p = primary
        var s = secondary
        var cur = current
        
        // Various Germanic rules
        if cur > 1 && !isVowel(chars, cur - 2) && 
           substringAt(chars, cur - 1, 3) == "ACH" &&
           (chars[safe: cur + 2] != "I" && (chars[safe: cur + 2] != "E" || 
            substringAt(chars, cur - 2, 6) == "BACHER" || substringAt(chars, cur - 2, 6) == "MACHER")) {
            p += "K"
            s += "K"
            cur += 2
        } else if cur == 0 && substringAt(chars, cur, 6) == "CAESAR" {
            p += "S"
            s += "S"
            cur += 2
        } else if substringAt(chars, cur, 2) == "CH" {
            // CH handling
            if substringAt(chars, cur, 4) == "CHIA" {
                p += "K"
                s += "K"
                cur += 2
            } else if cur > 0 && substringAt(chars, cur, 4) == "CHAE" {
                p += "K"
                s += "X"
                cur += 2
            } else if cur == 0 && 
                      (substringAt(chars, cur + 1, 5) == "HARAC" || substringAt(chars, cur + 1, 5) == "HARIS" ||
                       substringAt(chars, cur + 1, 3) == "HOR" || substringAt(chars, cur + 1, 3) == "HYM" ||
                       substringAt(chars, cur + 1, 3) == "HIA" || substringAt(chars, cur + 1, 3) == "HEM") {
                p += "K"
                s += "K"
                cur += 2
            } else {
                p += "X"
                s += "X"
                cur += 2
            }
        } else if substringAt(chars, cur, 2) == "CZ" && substringAt(chars, cur - 2, 4) != "WICZ" {
            p += "S"
            s += "X"
            cur += 2
        } else if substringAt(chars, cur + 1, 3) == "CIA" {
            p += "X"
            s += "X"
            cur += 3
        } else if substringAt(chars, cur, 2) == "CC" && !(cur == 1 && chars[0] == "M") {
            if ["I", "E", "H"].contains(String(chars[safe: cur + 2] ?? " ")) && substringAt(chars, cur + 2, 2) != "HU" {
                if (cur == 1 && chars[0] == "A") || 
                   ["UCCEE", "UCCES"].contains(substringAt(chars, cur - 1, 5)) {
                    p += "KS"
                    s += "KS"
                } else {
                    p += "X"
                    s += "X"
                }
                cur += 3
            } else {
                p += "K"
                s += "K"
                cur += 2
            }
        } else if ["CK", "CG", "CQ"].contains(substringAt(chars, cur, 2)) {
            p += "K"
            s += "K"
            cur += 2
        } else if ["CI", "CE", "CY"].contains(substringAt(chars, cur, 2)) {
            if ["CIO", "CIE", "CIA"].contains(substringAt(chars, cur, 3)) {
                p += "S"
                s += "X"
            } else {
                p += "S"
                s += "S"
            }
            cur += 2
        } else {
            p += "K"
            s += "K"
            if ["C ", "CK", "CG", "CQ"].contains(substringAt(chars, cur + 1, 2)) {
                cur += 3
            } else if ["C", "K", "Q"].contains(String(chars[safe: cur + 1] ?? " ")) && 
                      !["CE", "CI"].contains(substringAt(chars, cur + 1, 2)) {
                cur += 2
            } else {
                cur += 1
            }
        }
        
        return (p, s, cur)
    }
    
    private func handleD(_ chars: [Character], _ current: Int, _ length: Int,
                         _ primary: String, _ secondary: String) -> (String, String, Int) {
        var p = primary
        var s = secondary
        var cur = current
        
        if substringAt(chars, cur, 2) == "DG" {
            if ["I", "E", "Y"].contains(String(chars[safe: cur + 2] ?? " ")) {
                p += "J"
                s += "J"
                cur += 3
            } else {
                p += "TK"
                s += "TK"
                cur += 2
            }
        } else if ["DT", "DD"].contains(substringAt(chars, cur, 2)) {
            p += "T"
            s += "T"
            cur += 2
        } else {
            p += "T"
            s += "T"
            cur += 1
        }
        
        return (p, s, cur)
    }
    
    private func handleG(_ chars: [Character], _ current: Int, _ length: Int,
                         _ primary: String, _ secondary: String) -> (String, String, Int) {
        var p = primary
        var s = secondary
        var cur = current
        
        if cur + 1 < length && chars[cur + 1] == "H" {
            if cur > 0 && !isVowel(chars, cur - 1) {
                p += "K"
                s += "K"
                cur += 2
            } else if cur == 0 {
                if cur + 2 < length && chars[cur + 2] == "I" {
                    p += "J"
                    s += "J"
                } else {
                    p += "K"
                    s += "K"
                }
                cur += 2
            } else if (cur > 1 && ["B", "H", "D"].contains(String(chars[cur - 2]))) ||
                      (cur > 2 && ["B", "H", "D"].contains(String(chars[cur - 3]))) ||
                      (cur > 3 && ["B", "H"].contains(String(chars[cur - 4]))) {
                cur += 2
            } else {
                if cur > 2 && chars[cur - 1] == "U" && 
                   ["C", "G", "L", "R", "T"].contains(String(chars[cur - 3])) {
                    p += "F"
                    s += "F"
                } else if cur > 0 && chars[cur - 1] != "I" {
                    p += "K"
                    s += "K"
                }
                cur += 2
            }
        } else if cur + 1 < length && chars[cur + 1] == "N" {
            if cur == 1 && isVowel(chars, 0) {
                p += "KN"
                s += "N"
            } else if substringAt(chars, cur + 2, 2) != "EY" && chars[cur + 1] != "Y" {
                p += "N"
                s += "KN"
            } else {
                p += "KN"
                s += "KN"
            }
            cur += 2
        } else if substringAt(chars, cur + 1, 2) == "LI" {
            p += "KL"
            s += "L"
            cur += 2
        } else if cur == 0 && (chars[safe: cur + 1] == "Y" || 
                               ["ES", "EP", "EB", "EL", "EY", "IB", "IL", "IN", "IE", "EI", "ER"].contains(substringAt(chars, cur + 1, 2))) {
            p += "K"
            s += "J"
            cur += 2
        } else if (substringAt(chars, cur + 1, 2) == "ER" || chars[safe: cur + 1] == "Y") &&
                  !["DANGER", "RANGER", "MANGER"].contains(substringAt(chars, 0, 6)) &&
                  !["E", "I"].contains(String(chars[safe: cur - 1] ?? " ")) &&
                  !["RGY", "OGY"].contains(substringAt(chars, cur - 1, 3)) {
            p += "K"
            s += "J"
            cur += 2
        } else if ["E", "I", "Y"].contains(String(chars[safe: cur + 1] ?? " ")) ||
                  ["AGGI", "OGGI"].contains(substringAt(chars, cur - 1, 4)) {
            if ["VAN ", "VON "].contains(substringAt(chars, 0, 4)) || substringAt(chars, 0, 3) == "SCH" ||
               substringAt(chars, cur + 1, 2) == "ET" {
                p += "K"
                s += "K"
            } else if substringAt(chars, cur + 1, 4) == "IER " {
                p += "J"
                s += "J"
            } else {
                p += "J"
                s += "K"
            }
            cur += 2
        } else if chars[safe: cur + 1] == "G" {
            cur += 2
            p += "K"
            s += "K"
        } else {
            cur += 1
            p += "K"
            s += "K"
        }
        
        return (p, s, cur)
    }
    
    private func handleJ(_ chars: [Character], _ current: Int, _ length: Int,
                         _ primary: String, _ secondary: String) -> (String, String, Int) {
        var p = primary
        var s = secondary
        var cur = current
        
        if substringAt(chars, cur, 4) == "JOSE" || substringAt(chars, 0, 4) == "SAN " {
            if (cur == 0 && chars[safe: cur + 4] == " ") || substringAt(chars, 0, 4) == "SAN " {
                p += "H"
                s += "H"
            } else {
                p += "J"
                s += "H"
            }
            cur += 1
        } else if cur == 0 {
            p += "J"
            s += "A"
            cur += 1
        } else if isVowel(chars, cur - 1) && !isVowel(chars, cur + 1) &&
                  (chars[safe: cur + 1] == "A" || chars[safe: cur + 1] == "O") {
            p += "J"
            s += "H"
            cur += 1
        } else if cur == length - 1 {
            p += "J"
            s += ""
            cur += 1
        } else if !["L", "T", "K", "S", "N", "M", "B", "Z"].contains(String(chars[safe: cur + 1] ?? " ")) &&
                  !["S", "K", "L"].contains(String(chars[safe: cur - 1] ?? " ")) {
            p += "J"
            s += "J"
            cur += 1
        } else {
            cur += 1
        }
        
        if chars[safe: cur] == "J" {
            cur += 1
        }
        
        return (p, s, cur)
    }
    
    private func handleS(_ chars: [Character], _ current: Int, _ length: Int,
                         _ primary: String, _ secondary: String) -> (String, String, Int) {
        var p = primary
        var s = secondary
        var cur = current
        
        if ["ISL", "YSL"].contains(substringAt(chars, cur - 1, 3)) {
            cur += 1
        } else if cur == 0 && substringAt(chars, cur, 5) == "SUGAR" {
            p += "X"
            s += "S"
            cur += 1
        } else if substringAt(chars, cur, 2) == "SH" {
            if ["HEIM", "HOEK", "HOLM", "HOLZ"].contains(substringAt(chars, cur + 1, 4)) {
                p += "S"
                s += "S"
            } else {
                p += "X"
                s += "X"
            }
            cur += 2
        } else if ["SIO", "SIA"].contains(substringAt(chars, cur, 3)) || substringAt(chars, cur, 4) == "SIAN" {
            p += "S"
            s += "X"
            cur += 3
        } else if (cur == 0 && ["M", "N", "L", "W"].contains(String(chars[safe: cur + 1] ?? " "))) ||
                  chars[safe: cur + 1] == "Z" {
            p += "S"
            s += "X"
            cur += 1
        } else if substringAt(chars, cur, 2) == "SC" {
            if chars[safe: cur + 2] == "H" {
                if ["OO", "ER", "EN", "UY", "ED", "EM"].contains(substringAt(chars, cur + 3, 2)) {
                    if ["ER", "EN"].contains(substringAt(chars, cur + 3, 2)) {
                        p += "X"
                        s += "SK"
                    } else {
                        p += "SK"
                        s += "SK"
                    }
                    cur += 3
                } else {
                    if cur == 0 && !isVowel(chars, 3) && chars[safe: 3] != "W" {
                        p += "X"
                        s += "S"
                    } else {
                        p += "X"
                        s += "X"
                    }
                    cur += 3
                }
            } else if ["I", "E", "Y"].contains(String(chars[safe: cur + 2] ?? " ")) {
                p += "S"
                s += "S"
                cur += 3
            } else {
                p += "SK"
                s += "SK"
                cur += 3
            }
        } else if cur == length - 1 && ["AI", "OI"].contains(substringAt(chars, cur - 2, 2)) {
            p += ""
            s += "S"
            cur += 1
        } else {
            p += "S"
            s += "S"
            if ["S", "Z"].contains(String(chars[safe: cur + 1] ?? " ")) {
                cur += 2
            } else {
                cur += 1
            }
        }
        
        return (p, s, cur)
    }
    
    private func handleT(_ chars: [Character], _ current: Int, _ length: Int,
                         _ primary: String, _ secondary: String) -> (String, String, Int) {
        var p = primary
        var s = secondary
        var cur = current
        
        if substringAt(chars, cur, 4) == "TION" {
            p += "X"
            s += "X"
            cur += 3
        } else if ["TIA", "TCH"].contains(substringAt(chars, cur, 3)) {
            p += "X"
            s += "X"
            cur += 3
        } else if substringAt(chars, cur, 2) == "TH" || substringAt(chars, cur, 3) == "TTH" {
            if ["OM", "AM"].contains(substringAt(chars, cur + 2, 2)) ||
               ["VAN ", "VON "].contains(substringAt(chars, 0, 4)) ||
               substringAt(chars, 0, 3) == "SCH" {
                p += "T"
                s += "T"
            } else {
                p += "0"  // θ sound represented as 0
                s += "T"
            }
            cur += 2
        } else if ["T", "D"].contains(String(chars[safe: cur + 1] ?? " ")) {
            cur += 2
            p += "T"
            s += "T"
        } else {
            cur += 1
            p += "T"
            s += "T"
        }
        
        return (p, s, cur)
    }
    
    private func handleW(_ chars: [Character], _ current: Int, _ length: Int,
                         _ primary: String, _ secondary: String) -> (String, String, Int) {
        var p = primary
        var s = secondary
        var cur = current
        
        if substringAt(chars, cur, 2) == "WR" {
            p += "R"
            s += "R"
            cur += 2
        } else if cur == 0 && (isVowel(chars, cur + 1) || substringAt(chars, cur, 2) == "WH") {
            if isVowel(chars, cur + 1) {
                p += "A"
                s += "F"
            } else {
                p += "A"
                s += "A"
            }
            cur += 1
        } else if (cur == length - 1 && isVowel(chars, cur - 1)) ||
                  ["EWSKI", "EWSKY", "OWSKI", "OWSKY"].contains(substringAt(chars, cur - 1, 5)) ||
                  substringAt(chars, 0, 3) == "SCH" {
            p += ""
            s += "F"
            cur += 1
        } else if ["WICZ", "WITZ"].contains(substringAt(chars, cur, 4)) {
            p += "TS"
            s += "FX"
            cur += 4
        } else {
            cur += 1
        }
        
        return (p, s, cur)
    }
}

// MARK: - Array Safe Subscript Extension

private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
