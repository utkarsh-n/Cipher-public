import Foundation

/// The languages Cipher writes in. The raw values are stored in the compiled lexicon.
enum Language: UInt8, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case english, hindi, gujarati, spanish, french

    var id: UInt8 { rawValue }

    var code: String {
        switch self {
        case .english: "en"
        case .hindi: "hi"
        case .gujarati: "gu"
        case .spanish: "es"
        case .french: "fr"
        }
    }

    var name: String {
        switch self {
        case .english: "English"
        case .hindi: "Hindi"
        case .gujarati: "Gujarati"
        case .spanish: "Spanish"
        case .french: "French"
        }
    }

    var nativeName: String {
        switch self {
        case .english: "English"
        case .hindi: "हिन्दी"
        case .gujarati: "ગુજરાતી"
        case .spanish: "Español"
        case .french: "Français"
        }
    }

    /// Written in its own script, and also typed in Roman letters (yaar, kem cho).
    var isIndic: Bool { self == .hindi || self == .gujarati }

    init?(code: String) {
        guard let match = Language.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }
}

enum Script: Sendable {
    case latin, devanagari, gujarati, other

    /// The script of the first letter in the text.
    static func of(_ text: String) -> Script {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0900...0x097F: return .devanagari
            case 0x0A80...0x0AFF: return .gujarati
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: return .latin
            default: continue
            }
        }
        return .other
    }
}

enum Tokenizer {
    /// A word in any of the four languages: letters with their combining marks (the vowel signs
    /// of Devanagari and Gujarati are marks, not letters), with apostrophes allowed inside and
    /// at the edges ('bout, runnin').
    static let pattern = try! NSRegularExpression(pattern: "'?[\\p{L}\\p{M}]+(?:['\u{2019}][\\p{L}\\p{M}]+)*'?")

    static func words(in text: String) -> [String] { phrases(in: text).words }

    /// The words of a line, and where punctuation falls between them: `breaks` holds the index
    /// of every word that is followed by a comma, dash or stop before the next word.
    static func phrases(in text: String) -> (words: [String], breaks: Set<Int>) {
        let source = text as NSString
        var words: [String] = []
        var breaks = Set<Int>()
        var previousEnd = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let word = clean(source.substring(with: match.range))
            guard !word.isEmpty else { continue }
            if !words.isEmpty {
                let between = source.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd))
                if between.contains(where: { $0.isPunctuation }) { breaks.insert(words.count - 1) }
            }
            words.append(word)
            previousEnd = NSMaxRange(match.range)
        }
        return (words, breaks)
    }

    /// Lowercased and composed, curly apostrophes straightened, everything that is not part of
    /// a word removed. This is the form the lexicon stores.
    static func clean(_ raw: String) -> String {
        let lowered = raw.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").precomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        for scalar in lowered.unicodeScalars {
            let properties = scalar.properties
            if properties.isAlphabetic || scalar == "'" || properties.generalCategory == .nonspacingMark || properties.generalCategory == .spacingMark {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
