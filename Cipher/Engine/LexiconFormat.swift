import Foundation

/// What a posting list in the compiled lexicon is keyed on. Each kind hashes with its own seed
/// into one shared table.
enum IndexKind: UInt64 {
    case rhymeTail = 1      // last stressed vowel onward: perfect rhymes
    case tailVowels         // vowel families of the rhyme tail: slant rhymes
    case wholeVowels        // every vowel in the word: mosaic slots
    case wholePron          // the entire pronunciation: homophones, sound-alike phrases
    case consonants         // consonant skeleton: pararhyme (flip / flop)
    case head               // onset + first vowel: front rhyme
    case romanTight         // a Hindi or Gujarati word as typed in Roman letters
    case romanLoose         // the same, forgiving of looser spelling
    case glossTerm          // an English meaning: translations and associations
    case vowelSuffix2 = 12  // last N vowel families: multisyllabic rhymes
    case vowelSuffix3
    case vowelSuffix4

    static func vowelSuffix(_ count: Int) -> IndexKind? {
        (2...4).contains(count) ? IndexKind(rawValue: 10 + UInt64(count)) : nil
    }
}

/// Keys into the compiled lexicon's hash index. The build tool and the app must agree on these
/// exactly, which is why they live in one file compiled into both.
enum LexiconKey {
    static func sound(_ kind: IndexKind, _ phones: Pron) -> UInt64 {
        var hash = seed(kind.rawValue)
        for phone in phones { mix(&hash, phone.code) }
        return hash
    }

    /// Roman keys are per language; gloss terms are shared by all of them.
    static func text(_ kind: IndexKind, _ text: String, language: Language? = nil) -> UInt64 {
        var hash = seed(kind.rawValue + 100 * UInt64((language?.rawValue ?? 0xFE) &+ 1))
        for byte in text.utf8 { mix(&hash, byte) }
        return hash
    }

    // FNV-1a. Callers re-check what they find, so a collision costs a wasted comparison.
    private static func seed(_ salt: UInt64) -> UInt64 { 0xcbf2_9ce4_8422_2325 ^ (salt &* 0x9E37_79B9_7F4A_7C15) }

    private static func mix(_ hash: inout UInt64, _ byte: UInt8) {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
    }

    /// The searchable meanings in a gloss: "to burn; flame (of a lamp)" gives "burn" and "flame".
    static func glossTerms(_ gloss: String) -> [String] {
        gloss.split(separator: ";").compactMap { item in
            var term = item.lowercased()
            if let paren = term.firstIndex(of: "(") { term = String(term[..<paren]) }
            term = term.trimmingCharacters(in: .whitespaces)
            for article in ["to ", "a ", "an ", "the "] where term.hasPrefix(article) {
                term.removeFirst(article.count)
            }
            let words = term.split(separator: " ")
            return term.isEmpty || words.count > 3 ? nil : term
        }
    }
}

/// Layout of the compiled lexicon: 64-bit header fields, then 8-byte-aligned sections that the
/// app maps straight into memory. Nothing is parsed at launch.
enum LexiconFormat {
    static let magic: UInt64 = 0x3258_454C_5048_4943 // "CIPHLEX2", little-endian

    enum Field: Int, CaseIterable {
        case magic, entryCount, keyCount, postingCount
        // Byte offsets of each section.
        case languages, tiers, freqs, pronOffsets, phones, textOffsets, text, keys, starts, postings
        // First of eight fields: (start, end) entry index per language, in Language order.
        case ranges
    }

    static let headerBytes = (Field.ranges.rawValue + Language.allCases.count * 2) * 8
}
