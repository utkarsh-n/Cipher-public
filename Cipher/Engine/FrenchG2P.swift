import Foundation

/// Rough French spelling-to-sound for words the dictionary lacks (slang, verlan, names).
/// The lexicon covers ordinary French; this only has to land the vowels and the ending.
enum FrenchG2P {
    /// Elided words fused onto the next one: l'amour, j'ai, qu'il.
    static let clitics: [String: [String]] = [
        "l": ["L"], "j": ["ZH"], "d": ["DD"], "n": ["N"], "s": ["S"], "t": ["TD"], "m": ["M"], "c": ["S"],
        "qu": ["K"], "jusqu": ["ZH", "UE", "S", "K"], "lorsqu": ["L", "AO", "R", "S", "K"], "puisqu": ["P", "W", "IY", "S", "K"],
    ]

    static func pronounce(_ raw: String) -> Pron {
        let word = raw.lowercased().precomposedStringWithCanonicalMapping
        var letters = Array(word.filter { $0.isLetter })
        guard !letters.isEmpty else { return [] }

        let vowelLetters: Set<Character> = ["a", "e", "i", "o", "u", "y", "é", "è", "ê", "ë", "à", "â", "î", "ï", "ô", "ù", "û", "ü", "œ"]
        // Final consonants are mostly silent; final e is mute and leaves the consonant before it sounding.
        var keepFinal = false
        if letters.count > 2, letters.last == "s" || letters.last == "x" { letters.removeLast() }
        if letters.count > 2, letters.last == "e", !vowelLetters.contains(letters[letters.count - 2]) {
            letters.removeLast()
            keepFinal = true
        } else if letters.count > 3, letters.suffix(3) == ["e", "n", "t"] {
            letters.removeLast(3) // -ent of verbs
            keepFinal = true
        }

        var out: Pron = []
        var index = 0
        func at(_ offset: Int) -> Character? {
            let target = index + offset
            return letters.indices.contains(target) ? letters[target] : nil
        }
        func matches(_ text: String) -> Bool {
            let chars = Array(text)
            return index + chars.count <= letters.count && Array(letters[index..<(index + chars.count)]) == chars
        }
        func isVowel(_ character: Character?) -> Bool { character.map(vowelLetters.contains) ?? false }
        func emit(_ symbols: String...) {
            out += symbols.map { Phone.vowelSymbols.contains($0) ? Phone.vowel($0) : Phone.consonant($0) }
        }
        /// A vowel + n/m is a nasal vowel unless another vowel (or a doubled n/m) follows.
        func nasal(after length: Int) -> Bool {
            guard let next = at(length), next == "n" || next == "m" else { return false }
            let following = at(length + 1)
            return !isVowel(following) && following != "n" && following != "m"
        }

        while index < letters.count {
            let isLast = index == letters.count - 1
            var step = 1
            if matches("eau") { emit("O"); step = 3 }
            else if matches("ain") && nasal(after: 2) || matches("ein") && nasal(after: 2) { emit("IN"); step = 3 }
            else if matches("oin") && nasal(after: 2) { emit("W", "IN"); step = 3 }
            else if matches("ien") && nasal(after: 2) { emit("Y", "IN"); step = 3 }
            else if matches("ou") || matches("où") || matches("oû") { emit("UW"); step = 2 }
            else if matches("oi") { emit("W", "AA"); step = 2 }
            else if matches("au") { emit("O"); step = 2 }
            else if matches("ai") || matches("ei") { emit("EH"); step = 2 }
            else if matches("eu") || matches("œu") { emit("EU"); step = 2 }
            else if matches("an") && nasal(after: 1) || matches("am") && nasal(after: 1) || matches("en") && nasal(after: 1) || matches("em") && nasal(after: 1) { emit("AN"); step = 2 }
            else if matches("on") && nasal(after: 1) || matches("om") && nasal(after: 1) { emit("ON"); step = 2 }
            else if matches("in") && nasal(after: 1) || matches("im") && nasal(after: 1) || matches("un") && nasal(after: 1) || matches("yn") && nasal(after: 1) { emit("IN"); step = 2 }
            else if matches("ch") { emit("SH"); step = 2 }
            else if matches("gn") { emit("NY"); step = 2 }
            else if matches("ph") { emit("F"); step = 2 }
            else if matches("qu") { emit("K"); step = 2 }
            else if matches("ill") && index > 0 { emit(isVowel(at(-1)) ? "Y" : "IY"); if !isVowel(at(-1)) { emit("Y") }; step = 3 }
            else if matches("er") && index == letters.count - 2 && !keepFinal && letters.count > 3 { emit("E"); step = 2 }
            else if matches("ez") && index == letters.count - 2 { emit("E"); step = 2 }
            else {
                let letter = letters[index]
                switch letter {
                case "a", "à", "â": emit("AA")
                case "é": emit("E")
                case "è", "ê", "ë": emit("EH")
                case "e": emit(isLast ? "AH" : (isVowel(at(1)) || at(2) == nil || !isVowel(at(2)) ? "EH" : "AH"))
                case "i", "î", "ï", "y": emit(isVowel(at(1)) && index > 0 ? "Y" : "IY")
                case "o", "ô": emit(isLast || at(1) == "s" ? "O" : "AO")
                case "u", "ù", "û", "ü": emit("UE")
                case "œ": emit("EU")
                case "b": emit("B")
                case "c": emit(at(1).map { "eiyéèê".contains($0) } == true ? "S" : "K")
                case "ç": emit("S")
                case "d": if !isLast || keepFinal { emit("DD") }
                case "f": emit("F")
                case "g": if at(1).map({ "eiyéèê".contains($0) }) == true { emit("ZH") } else if !isLast || keepFinal { emit("G") }
                case "h": break
                case "j": emit("ZH")
                case "k": emit("K")
                case "l": emit("L")
                case "m": emit("M")
                case "n": emit("N")
                case "p": if !isLast || keepFinal { emit("P") }
                case "q": emit("K")
                case "r": emit("R")
                case "s": emit(isVowel(at(-1)) && isVowel(at(1)) ? "Z" : "S")
                case "t": if !isLast || keepFinal { emit("TD") }
                case "v": emit("V")
                case "w": emit("W")
                case "x": emit("K", "S")
                case "z": if !isLast || keepFinal { emit("Z") }
                default: break
                }
                // Doubled consonants sound once.
                if !vowelLetters.contains(letter), at(1) == letter { step = 2 }
            }
            index += step
        }
        return stressed(out)
    }

    /// French stress, and so its rhyme, sits on the last full vowel.
    static func stressed(_ phones: Pron) -> Pron {
        var result = phones.map { $0.withStress(0) }
        let vowels = result.indices.filter { result[$0].isVowel }
        guard var anchor = vowels.last else { return result }
        if vowels.count > 1, anchor == result.count - 1, result[anchor] == .vowel("AH") {
            anchor = vowels[vowels.count - 2]
        }
        result[anchor] = result[anchor].withStress(1)
        return result
    }
}
