import Foundation

/// Spanish spelling says how a word sounds, so pronunciation is rules rather than a dictionary.
/// Latin American sound values: c/z before e and i are "s", and ll is "y".
enum SpanishG2P {
    private enum Token {
        case consonants([Phone])
        case vowel(Character, accented: Bool)
    }

    private static let accents: [Character: Character] = ["á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u"]
    private static let plainVowels: Set<Character> = ["a", "e", "i", "o", "u"]

    /// Words whose x keeps its old "j" sound.
    private static let respelled: [String: String] = [
        "méxico": "méjico", "mexicano": "mejicano", "mexicana": "mejicana", "mexicanos": "mejicanos",
        "mexicanas": "mejicanas", "texas": "tejas", "oaxaca": "oajaca",
    ]

    static func pronounce(_ raw: String) -> Pron {
        let word = raw.lowercased().precomposedStringWithCanonicalMapping
        let letters = Array(respelled[word] ?? word)
        guard !letters.isEmpty else { return [] }

        func isVowelLetter(_ index: Int) -> Bool {
            guard letters.indices.contains(index) else { return false }
            let letter = letters[index]
            return plainVowels.contains(letter) || accents[letter] != nil || letter == "ü"
        }
        func isFront(_ index: Int) -> Bool {
            guard letters.indices.contains(index) else { return false }
            return "eiéí".contains(letters[index])
        }
        func c(_ symbols: String...) -> Token { .consonants(symbols.map(Phone.consonant)) }

        var tokens: [Token] = []
        var index = 0
        while index < letters.count {
            let letter = letters[index]
            let next: Character? = index + 1 < letters.count ? letters[index + 1] : nil
            var step = 1
            if let base = accents[letter] {
                tokens.append(.vowel(base, accented: true))
            } else if plainVowels.contains(letter) {
                tokens.append(.vowel(letter, accented: false))
            } else {
                switch letter {
                case "ü": tokens.append(.vowel("u", accented: false))
                case "b", "v": tokens.append(c("B"))
                case "c":
                    if next == "h" {
                        tokens.append(c("CH"))
                        step = 2
                    } else {
                        tokens.append(c(isFront(index + 1) ? "S" : "K"))
                    }
                case "d": tokens.append(c("DD"))
                case "f": tokens.append(c("F"))
                case "g":
                    if isFront(index + 1) {
                        tokens.append(c("HX"))
                    } else if next == "u", isFront(index + 2) {
                        tokens.append(c("G"))
                        step = 2 // the u only keeps the g hard
                    } else {
                        tokens.append(c("G"))
                    }
                case "h": break
                case "j": tokens.append(c("HX"))
                case "k": tokens.append(c("K"))
                case "l":
                    if next == "l" {
                        tokens.append(c("Y"))
                        step = 2
                    } else {
                        tokens.append(c("L"))
                    }
                case "m": tokens.append(c("M"))
                case "n": tokens.append(c("N"))
                case "ñ": tokens.append(c("NY"))
                case "p": tokens.append(c("P"))
                case "q":
                    tokens.append(c("K"))
                    if next == "u" { step = 2 }
                case "r":
                    let previous: Character? = index > 0 ? letters[index - 1] : nil
                    if next == "r" {
                        tokens.append(c("RR"))
                        step = 2
                    } else if index == 0 || previous == "n" || previous == "l" || previous == "s" {
                        tokens.append(c("RR"))
                    } else {
                        tokens.append(c("R"))
                    }
                case "s": tokens.append(c("S"))
                case "t": tokens.append(c("TD"))
                case "w": tokens.append(c("W"))
                case "x": tokens.append(index == 0 ? c("S") : c("K", "S"))
                case "y":
                    // A consonant before a vowel (yo, playa); otherwise the vowel i (y, hoy, muy).
                    tokens.append(isVowelLetter(index + 1) ? c("Y") : .vowel("i", accented: false))
                case "z": tokens.append(c("S"))
                default: break
                }
            }
            index += step
        }

        // Turn runs of vowel letters into syllable nuclei. An unaccented i or u next to another
        // vowel is only a glide; an accented one stands as its own syllable (dí-a).
        var phones: Pron = []
        var nuclei: [(position: Int, accented: Bool)] = []
        var cursor = 0
        func weak(_ token: Token) -> Bool {
            if case .vowel(let letter, accented: false) = token { return letter == "i" || letter == "u" }
            return false
        }
        func vowelAt(_ position: Int) -> (letter: Character, accented: Bool)? {
            guard tokens.indices.contains(position), case .vowel(let letter, let accented) = tokens[position] else { return nil }
            return (letter, accented)
        }
        while cursor < tokens.count {
            switch tokens[cursor] {
            case .consonants(let sounds):
                phones += sounds
                cursor += 1
            case .vowel(let letter, let accented):
                if weak(tokens[cursor]), vowelAt(cursor + 1) != nil {
                    phones.append(.consonant(letter == "i" ? "Y" : "W"))
                    cursor += 1
                    continue
                }
                var symbols: [String]
                var consumed = 1
                let offglide: Character? = {
                    guard let following = vowelAt(cursor + 1), weak(tokens[cursor + 1]), vowelAt(cursor + 2) == nil else { return nil }
                    return following.letter
                }()
                switch (letter, offglide) {
                case ("a", "i"): symbols = ["AY"]; consumed = 2
                case ("a", "u"): symbols = ["AW"]; consumed = 2
                case ("o", "i"): symbols = ["OY"]; consumed = 2
                case ("e", "i"): symbols = ["E", "Y"]; consumed = 2
                case ("e", "u"): symbols = ["E", "W"]; consumed = 2
                case ("o", "u"): symbols = ["O", "W"]; consumed = 2
                case ("a", _): symbols = ["AA"]
                case ("e", _): symbols = ["E"]
                case ("o", _): symbols = ["O"]
                case ("i", _): symbols = ["IY"]
                default: symbols = ["UW"]
                }
                nuclei.append((phones.count, accented))
                phones.append(.vowel(symbols[0]))
                if symbols.count > 1 { phones.append(.consonant(symbols[1])) }
                cursor += consumed
            }
        }

        // Stress: a written accent wins; otherwise words ending in a vowel, n or s stress the
        // second-to-last syllable and everything else the last.
        guard !nuclei.isEmpty else { return phones }
        let stressed: Int
        if let marked = nuclei.lastIndex(where: \.accented) {
            stressed = marked
        } else if nuclei.count >= 2, let last = letters.last, plainVowels.contains(last) || last == "n" || last == "s" {
            stressed = nuclei.count - 2
        } else {
            stressed = nuclei.count - 1
        }
        let position = nuclei[stressed].position
        phones[position] = phones[position].withStress(1)
        return phones
    }
}
