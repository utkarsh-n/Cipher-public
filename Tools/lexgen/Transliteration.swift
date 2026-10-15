import Foundation

/// Wiktionary's scholarly transliteration of Hindi (zindagī, pyār, acchā) to phones. Its
/// editors have already decided where the silent "a"s fall, word by word, which beats any rule.
enum IAST {
    static func phones(_ roman: String) -> Pron? {
        struct Letter {
            let base: Character
            var marks: Set<UInt32> = []
        }
        var letters: [Letter] = []
        for scalar in roman.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.properties.generalCategory == .nonspacingMark {
                guard !letters.isEmpty else { return nil }
                letters[letters.count - 1].marks.insert(scalar.value)
            } else if scalar == "." || scalar == "'" {
                continue
            } else if (97...122).contains(scalar.value) {
                letters.append(Letter(base: Character(scalar)))
            } else {
                return nil // spaces, hyphens, digits: not a single word
            }
        }
        let macron: UInt32 = 0x0304, tilde: UInt32 = 0x0303, wideTilde: UInt32 = 0x0360, dotBelow: UInt32 = 0x0323
        let dotAbove: UInt32 = 0x0307, acute: UInt32 = 0x0301, breve: UInt32 = 0x0306, caron: UInt32 = 0x030C

        var out: Pron = []
        var nasalPending = false
        func c(_ symbol: String) {
            let phone = Phone.consonant(symbol)
            if nasalPending {
                out.append(IndicG2P.nasal(before: phone))
                nasalPending = false
            }
            out.append(phone)
        }
        func v(_ symbol: String) {
            nasalPending = false // a nasal vowel before another vowel only colours it
            out.append(.vowel(symbol))
        }

        var index = 0
        while index < letters.count {
            let letter = letters[index]
            let next = index + 1 < letters.count ? letters[index + 1] : nil
            let nasal = letter.marks.contains(tilde) || letter.marks.contains(wideTilde)
            var step = 1
            // An h straight after a stop is aspiration, not its own sound.
            func aspirated(_ plain: String, _ breathy: String) {
                if let next, next.base == "h", next.marks.isEmpty {
                    c(breathy)
                    step = 2
                } else {
                    c(plain)
                }
            }
            switch letter.base {
            case "a":
                if letter.marks.contains(macron) {
                    v("AA")
                } else if let next, next.base == "i", !next.marks.contains(macron) {
                    v("AE")
                    step = 2
                } else if let next, next.base == "u", !next.marks.contains(macron) {
                    v("AO")
                    step = 2
                } else {
                    v("AH")
                }
                let glideNasal = step == 2 && (next?.marks.contains(tilde) == true)
                if nasal || glideNasal { nasalPending = true }
            case "i":
                v(letter.marks.contains(macron) ? "IY" : "IH")
                if nasal { nasalPending = true }
            case "u":
                v(letter.marks.contains(macron) ? "UW" : "UH")
                if nasal { nasalPending = true }
            case "e":
                v(letter.marks.contains(breve) ? "AE" : "E")
                if nasal { nasalPending = true }
            case "o":
                v(letter.marks.contains(breve) ? "AO" : "O")
                if nasal { nasalPending = true }
            case "k": aspirated("K", "KX")
            case "g": aspirated("G", "GX")
            case "c": aspirated("CH", "CX")
            case "j":
                // jñ is said "gy" (gyaan).
                if let next, next.base == "n", next.marks.contains(tilde) {
                    c("G")
                    c("Y")
                    step = 2
                } else {
                    aspirated("JH", "JX")
                }
            case "t": letter.marks.contains(dotBelow) ? aspirated("T", "TX") : aspirated("TD", "TDH")
            case "d": letter.marks.contains(dotBelow) ? aspirated("D", "DX") : aspirated("DD", "DDH")
            case "p": aspirated("P", "PX")
            case "b": aspirated("B", "BX")
            case "n":
                // Before another consonant ñ and ṇ are only the nasal taking its neighbour's place.
                let beforeConsonant = next.map { !"aeiou".contains($0.base) } ?? false
                if letter.marks.contains(dotAbove) { c("NG") }
                else if letter.marks.contains(tilde) { c(beforeConsonant ? "N" : "NY") }
                else if letter.marks.contains(dotBelow) { c(beforeConsonant ? "N" : "NR") }
                else { c("N") }
            case "r":
                if letter.marks.contains(acute) {
                    c("R")
                    v("IH")
                } else if letter.marks.contains(dotBelow) {
                    aspirated("RD", "RD")
                } else {
                    c("R")
                }
            case "s": c(letter.marks.contains(acute) || letter.marks.contains(dotBelow) ? "SH" : "S")
            case "l": c(letter.marks.contains(dotBelow) ? "LR" : "L")
            case "z": c(letter.marks.contains(caron) ? "ZH" : "Z")
            case "m": c("M")
            case "y": c("Y")
            case "v", "w": c("V")
            case "h": c("HH")
            case "q": c("K")
            case "x": c("HX")
            case "f": c("F")
            default: return nil
            }
            index += step
        }
        return out.isEmpty ? nil : out
    }

    /// The same transliteration with its diacritics filed off, the way it might be typed:
    /// zindagī -> zindagi, acchā -> achchha, laṛkā -> larka.
    static func casual(_ roman: String) -> String {
        var text = roman.lowercased().precomposedStringWithCanonicalMapping
        for (from, to) in [("ś", "sh"), ("ṣ", "sh"), ("ŕ", "ri"), ("x", "kh")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        let plain = String(text.decomposedStringWithCanonicalMapping.unicodeScalars.filter { (97...122).contains($0.value) })
        return plain.replacingOccurrences(of: "ch", with: "\u{1}").replacingOccurrences(of: "c", with: "ch").replacingOccurrences(of: "\u{1}", with: "chh")
    }
}

/// A coarse consonant-and-vowel skeleton, for checking the script reader against a dictionary's
/// IPA without caring about details the two write differently (vowel length, exact rhotic).
enum Skeleton {
    static func of(ipa: String) -> String? {
        var text = ipa.decomposedStringWithCanonicalMapping
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("~") else { return nil }
        // Optional sounds are written in brackets or superscript; treat them as silent.
        text = text.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        let map: [Character: String] = [
            "ə": "a", "ɐ": "a", "ɑ": "A", "a": "A", "ɪ": "i", "i": "i", "ʊ": "u", "u": "u", "e": "e", "ɛ": "e",
            "æ": "e", "o": "o", "ɔ": "o", "ɒ": "o",
            "k": "k", "ɡ": "g", "g": "g", "ŋ": "N", "ʃ": "S", "ʂ": "S", "ʒ": "j", "ɲ": "n", "ʈ": "t", "ɖ": "d",
            "ɳ": "n", "t": "t", "d": "d", "n": "n", "p": "p", "b": "b", "m": "m", "j": "y", "ɾ": "r", "r": "r",
            "l": "l", "ɭ": "l", "ʋ": "v", "w": "v", "v": "v", "s": "s", "ɦ": "h", "h": "h", "z": "z", "f": "f",
            "x": "x", "q": "k", "ɣ": "g", "ɽ": "R", "ʰ": "h", "ʱ": "h",
        ]
        var out = ""
        for scalar in text.unicodeScalars {
            let character = Character(scalar)
            if let mapped = map[character] { out += mapped }
        }
        // The dictionary writes "ch" and "j" as t+ʃ and d+ʒ. Nasals are dropped from both sides:
        // it writes them as nasal vowels where the reader writes a consonant.
        return strippingNasals(out.replacingOccurrences(of: "tS", with: "c").replacingOccurrences(of: "dj", with: "j"))
    }

    static func strippingNasals(_ skeleton: String) -> String {
        String(skeleton.filter { !"nNm".contains($0) })
    }

    static func of(_ pron: Pron) -> String {
        let consonants: [String: String] = [
            "K": "k", "KX": "kh", "G": "g", "GX": "gh", "NG": "N", "CH": "c", "CX": "ch", "JH": "j", "JX": "jh",
            "NY": "n", "T": "t", "TX": "th", "D": "d", "DX": "dh", "NR": "n", "TD": "t", "TDH": "th", "DD": "d",
            "DDH": "dh", "N": "n", "P": "p", "PX": "ph", "F": "f", "B": "b", "BX": "bh", "M": "m", "Y": "y",
            "R": "r", "L": "l", "LR": "l", "V": "v", "SH": "S", "S": "s", "HH": "h", "Z": "z", "RD": "R", "HX": "x",
        ]
        let vowels: [String: String] = [
            "AH": "a", "AA": "A", "IH": "i", "IY": "i", "UH": "u", "UW": "u", "E": "e", "EH": "e", "AE": "e",
            "O": "o", "AO": "o", "AY": "ai", "AW": "au", "OY": "oi",
        ]
        return strippingNasals(pron.map { phone in
            phone.isVowel ? vowels[Phone.vowelSymbols[phone.vowelBase]] ?? "?" : consonants[phone.symbol] ?? "?"
        }.joined())
    }
}
