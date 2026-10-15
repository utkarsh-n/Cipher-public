import Foundation

/// Spelling-to-sound fallback for words the dictionary doesn't know (new slang, names, typos).
/// It only needs to be good enough to count syllables and land the final vowel.
enum Guesser {
    static func guess(_ word: String) -> Pron {
        let letters = Array(word.lowercased().filter { $0.isLetter && $0.isASCII })
        guard !letters.isEmpty else { return [] }
        var phones: Pron = []
        var index = 0
        let vowelLetters: Set<Character> = ["a", "e", "i", "o", "u"]

        func peek(_ offset: Int) -> Character? {
            let target = index + offset
            return target >= 0 && target < letters.count ? letters[target] : nil
        }
        func matches(_ text: String) -> Bool {
            let chars = Array(text)
            guard index + chars.count <= letters.count else { return false }
            return Array(letters[index..<(index + chars.count)]) == chars
        }
        func c(_ symbol: String) { phones.append(.consonant(symbol)) }
        func v(_ symbol: String) { phones.append(.vowel(symbol)) }

        // "make", "time": a single consonant then a final silent e lengthens the vowel.
        func magicE() -> Bool {
            guard index + 2 == letters.count - 1, letters[index + 2] == "e",
                  let next = peek(1), !vowelLetters.contains(next) else { return false }
            return true
        }

        let multigraphs: [(String, () -> Void)] = [
            ("tch", { c("CH") }), ("igh", { v("AY") }), ("ch", { c("CH") }), ("sh", { c("SH") }),
            ("th", { c("TH") }), ("ph", { c("F") }), ("ck", { c("K") }), ("qu", { c("K"); c("W") }),
            ("wh", { c("W") }), ("dg", { c("JH") }), ("ee", { v("IY") }), ("ea", { v("IY") }),
            ("oo", { v("UW") }), ("ou", { v("AW") }), ("oi", { v("OY") }), ("oy", { v("OY") }),
            ("ai", { v("EY") }), ("ay", { v("EY") }), ("au", { v("AO") }), ("aw", { v("AO") }),
            ("oa", { v("OW") }), ("ey", { v("IY") }), ("ue", { v("UW") }), ("ew", { v("UW") }),
            ("ar", { v("AA"); c("R") }), ("or", { v("AO"); c("R") }), ("er", { v("ER") }),
            ("ir", { v("ER") }), ("ur", { v("ER") }),
        ]

        outer: while index < letters.count {
            let letter = letters[index]
            if index == 0 && (matches("kn") || matches("wr") || matches("gn")) {
                index += 1
                continue
            }
            if matches("ng") && (index + 2 == letters.count || !vowelLetters.contains(letters[index + 2])) {
                c("NG")
                index += 2
                continue
            }
            if matches("gh") {
                if index == 0 { c("G") }
                index += 2
                continue
            }
            if matches("ow") {
                v(index + 2 == letters.count ? "OW" : "AW")
                index += 2
                continue
            }
            if matches("ie") {
                v(index + 2 == letters.count && letters.count <= 4 ? "AY" : "IY")
                index += 2
                continue
            }
            for (text, emit) in multigraphs where matches(text) {
                emit()
                index += text.count
                continue outer
            }
            // Doubled consonants sound once.
            if !vowelLetters.contains(letter), peek(1) == letter {
                index += 1
                continue
            }
            switch letter {
            case "a":
                if magicE() { v("EY") } else if index == letters.count - 1 && index > 0 { v("AH") } else { v("AE") }
            case "e":
                if index == letters.count - 1 && phones.contains(where: \.isVowel) {
                    break // silent final e
                } else if magicE() || index == letters.count - 1 {
                    v("IY")
                } else {
                    v("EH")
                }
            case "i": v(magicE() ? "AY" : "IH")
            case "o":
                if magicE() || index == letters.count - 1 { v("OW") } else { v("AA") }
            case "u": v(magicE() ? "UW" : "AH")
            case "y":
                if index == 0 {
                    c("Y")
                } else if index == letters.count - 1 {
                    v(phones.contains(where: \.isVowel) ? "IY" : "AY")
                } else {
                    v("IH")
                }
            case "c": c(peek(1).map { "eiy".contains($0) } == true ? "S" : "K")
            case "g": c(index == letters.count - 2 && peek(1) == "e" ? "JH" : "G")
            case "j": c("JH")
            case "q": c("K")
            case "x": c("K"); c("S")
            case "h": c("HH")
            case "b": c("B")
            case "d": c("D")
            case "f": c("F")
            case "k": c("K")
            case "l": c("L")
            case "m": c("M")
            case "n": c("N")
            case "p": c("P")
            case "r": c("R")
            case "s": c("S")
            case "t": c("T")
            case "v": c("V")
            case "w": c("W")
            case "z": c("Z")
            default: break
            }
            index += 1
        }

        // Stress the first vowel; everything after stays unstressed.
        if let first = phones.firstIndex(where: \.isVowel) {
            phones[first] = Phone(phones[first].code + 1)
        }
        return phones
    }
}
