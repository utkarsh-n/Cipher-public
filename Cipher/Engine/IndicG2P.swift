import Foundation

/// Pronunciation for Hindi and Gujarati: from their own scripts, and from the Roman letters
/// people type them in (yaar, zindagi, kem cho).
enum IndicG2P {
    // MARK: Native script

    private enum Seg {
        case consonant(Phone)
        case vowel(Phone, inherent: Bool)
        /// Anusvara or chandrabindu, until we know what follows it.
        case nasal

        var isVowel: Bool { if case .vowel = self { true } else { false } }
        var isConsonant: Bool { if case .consonant = self { true } else { false } }
        var isInherent: Bool { if case .vowel(_, inherent: true) = self { true } else { false } }
    }

    private static func phones(_ symbols: String...) -> [Phone] {
        symbols.map { Phone.vowelSymbols.contains($0) ? Phone.vowel($0) : Phone.consonant($0) }
    }

    /// Devanagari code points. Gujarati is laid out identically 0x180 higher, so it is shifted
    /// down and read through the same tables.
    private static let consonants: [UInt32: [Phone]] = [
        0x0915: phones("K"), 0x0916: phones("KX"), 0x0917: phones("G"), 0x0918: phones("GX"), 0x0919: phones("NG"),
        0x091A: phones("CH"), 0x091B: phones("CX"), 0x091C: phones("JH"), 0x091D: phones("JX"), 0x091E: phones("NY"),
        0x091F: phones("T"), 0x0920: phones("TX"), 0x0921: phones("D"), 0x0922: phones("DX"), 0x0923: phones("NR"),
        0x0924: phones("TD"), 0x0925: phones("TDH"), 0x0926: phones("DD"), 0x0927: phones("DDH"), 0x0928: phones("N"),
        0x0929: phones("N"), 0x092A: phones("P"), 0x092B: phones("PX"), 0x092C: phones("B"), 0x092D: phones("BX"),
        0x092E: phones("M"), 0x092F: phones("Y"), 0x0930: phones("R"), 0x0931: phones("R"), 0x0932: phones("L"),
        0x0933: phones("LR"), 0x0934: phones("LR"), 0x0935: phones("V"), 0x0936: phones("SH"), 0x0937: phones("SH"),
        0x0938: phones("S"), 0x0939: phones("HH"),
        // Precomposed nukta letters.
        0x0958: phones("K"), 0x0959: phones("HX"), 0x095A: phones("G"), 0x095B: phones("Z"),
        0x095C: phones("RD"), 0x095D: phones("RD"), 0x095E: phones("F"), 0x095F: phones("Y"),
    ]

    /// What a consonant becomes with a nukta dot under it.
    private static let dotted: [UInt32: [Phone]] = [
        0x0915: phones("K"), 0x0916: phones("HX"), 0x0917: phones("G"), 0x091C: phones("Z"),
        0x0921: phones("RD"), 0x0922: phones("RD"), 0x092B: phones("F"),
    ]

    private static let independentVowels: [UInt32: [Phone]] = [
        0x0905: phones("AH"), 0x0906: phones("AA"), 0x0907: phones("IH"), 0x0908: phones("IY"), 0x0909: phones("UH"),
        0x090A: phones("UW"), 0x090B: phones("R", "IH"), 0x090D: phones("AE"), 0x090E: phones("E"), 0x090F: phones("E"),
        0x0910: phones("AE"), 0x0911: phones("AO"), 0x0912: phones("O"), 0x0913: phones("O"), 0x0914: phones("AO"),
        0x0972: phones("AE"),
    ]

    private static let vowelSigns: [UInt32: [Phone]] = [
        0x093E: phones("AA"), 0x093F: phones("IH"), 0x0940: phones("IY"), 0x0941: phones("UH"), 0x0942: phones("UW"),
        0x0943: phones("R", "IH"), 0x0945: phones("AE"), 0x0946: phones("E"), 0x0947: phones("E"), 0x0948: phones("AE"),
        0x0949: phones("AO"), 0x094A: phones("O"), 0x094B: phones("O"), 0x094C: phones("AO"),
    ]

    /// Spellings that don't say what they sound like.
    private static let irregular: [String: Pron] = [
        "यह": phones("Y", "E"), "वह": phones("V", "O"),
    ]

    private static let virama: UInt32 = 0x094D, nukta: UInt32 = 0x093C
    private static let anusvara: UInt32 = 0x0902, chandrabindu: UInt32 = 0x0901

    /// A word in Devanagari or Gujarati script to phones, with the rhyming vowel stressed.
    static func pronounce(_ word: String, language: Language, collapsingDoubles: Bool = true) -> Pron {
        if let known = irregular[word] { return finish(known, language: language) }
        var segments = read(word, gujarati: language == .gujarati)
        resolveNasals(&segments)
        deleteSchwas(&segments)
        let phones: Pron = segments.compactMap {
            switch $0 {
            case .consonant(let phone), .vowel(let phone, _): phone
            case .nasal: nil
            }
        }
        return finish(phones, language: language, collapsingDoubles: collapsingDoubles)
    }

    private static func read(_ word: String, gujarati: Bool) -> [Seg] {
        let scalars = word.unicodeScalars.map { scalar -> UInt32 in
            gujarati && (0x0A80...0x0AFF).contains(scalar.value) ? scalar.value - 0x180 : scalar.value
        }
        var segments: [Seg] = []
        var index = 0
        while index < scalars.count {
            let value = scalars[index]
            if var sounds = consonants[value] {
                index += 1
                if index < scalars.count, scalars[index] == nukta {
                    sounds = dotted[value] ?? sounds
                    index += 1
                }
                segments += sounds.map(Seg.consonant)
                if index < scalars.count, scalars[index] == virama {
                    index += 1
                } else if index < scalars.count, let sign = vowelSigns[scalars[index]] {
                    segments += vowelSegments(sign, code: scalars[index], gujarati: gujarati)
                    index += 1
                } else {
                    segments.append(.vowel(.vowel("AH"), inherent: true))
                }
            } else if let vowel = independentVowels[value] {
                segments += vowelSegments(vowel, code: value, gujarati: gujarati)
                index += 1
            } else {
                if value == anusvara || value == chandrabindu { segments.append(.nasal) }
                index += 1
            }
        }
        // ज्ञ is "gy" in speech, whatever the letters say.
        var cursor = 0
        while cursor + 1 < segments.count {
            if case .consonant(let first) = segments[cursor], case .consonant(let second) = segments[cursor + 1],
               first == .consonant("JH"), second == .consonant("NY") {
                segments[cursor] = .consonant(.consonant("G"))
                segments[cursor + 1] = .consonant(.consonant("Y"))
            }
            cursor += 1
        }
        return segments
    }

    private static func vowelSegments(_ sounds: [Phone], code: UInt32, gujarati: Bool) -> [Seg] {
        // Gujarati ઐ and ઔ are glides ("pai-sa", "kau-shal") where Hindi has plain open vowels,
        // and its vocalic r is "ru" (amrut, sanskruti) where Hindi says "ri".
        if gujarati, code == 0x0910 || code == 0x0948 { return [.vowel(.vowel("AY"), inherent: false)] }
        if gujarati, code == 0x0914 || code == 0x094C { return [.vowel(.vowel("AW"), inherent: false)] }
        if gujarati, code == 0x090B || code == 0x0943 { return [.consonant(.consonant("R")), .vowel(.vowel("UH"), inherent: false)] }
        return sounds.map { $0.isVowel ? .vowel($0, inherent: false) : .consonant($0) }
    }

    /// A nasal mark before a consonant is a real nasal made in the same place (rang, hindi,
    /// ambar); at the end of a word or before a vowel it only colours the vowel, which rhyme ignores.
    private static func resolveNasals(_ segments: inout [Seg]) {
        var resolved: [Seg] = []
        for (index, segment) in segments.enumerated() {
            guard case .nasal = segment else {
                resolved.append(segment)
                continue
            }
            guard index + 1 < segments.count, case .consonant(let next) = segments[index + 1] else { continue }
            resolved.append(.consonant(nasal(before: next)))
        }
        segments = resolved
    }

    static func nasal(before next: Phone) -> Phone {
        switch next.symbol {
        case "P", "PX", "B", "BX", "M", "V", "F": .consonant("M")
        case "K", "KX", "G", "GX", "HH", "HX": .consonant("NG")
        default: .consonant("N")
        }
    }

    /// The unwritten "a" after a consonant is silent at the end of a word, and in the middle of
    /// one when the syllables on both sides can absorb its consonants (sap-na, not sa-pa-na).
    /// Worked right to left so that dropping one protects its neighbour.
    private static func deleteSchwas(_ segments: inout [Seg]) {
        if let last = segments.last, last.isInherent, segments.dropLast().contains(where: \.isVowel), !keepsFinalSchwa(segments) {
            segments.removeLast()
        }
        var index = segments.count - 3
        while index >= 2 {
            // The "a" before an h is always spoken (pahar, mahal).
            if segments[index].isInherent, case .consonant(let next) = segments[index + 1], next != .consonant("HH"),
               segments[index + 2].isVowel, segments[index - 1].isConsonant, segments[index - 2].isVowel {
                segments.remove(at: index)
            }
            index -= 1
        }
    }

    /// A final "a" survives when the consonants before it could not end a word on their own:
    /// mitra, satya, ratna (but dharm, karm, janm), and the -iya of bharatiya.
    private static func keepsFinalSchwa(_ segments: [Seg]) -> Bool {
        let count = segments.count
        guard count >= 3, case .consonant(let last) = segments[count - 2] else { return false }
        if case .vowel(let before, _) = segments[count - 3] {
            return last == .consonant("Y") && before == .vowel("IY")
        }
        guard case .consonant(let previous) = segments[count - 3] else { return false }
        let hard: Set<Phone.Manner> = [.stop, .affricate]
        let previousIsHard = hard.contains(Phone.consonants[Int(previous.code)].manner) || previous == .consonant("HH")
        switch last.symbol {
        case "Y", "R", "L": return previous != last
        case "N", "M", "NR": return previousIsHard
        default: return false
        }
    }

    // MARK: Shared finishing

    private static let aspirateOf: [String: String] = [
        "K": "KX", "G": "GX", "CH": "CX", "JH": "JX", "T": "TX", "D": "DX",
        "TD": "TDH", "DD": "DDH", "P": "PX", "B": "BX",
    ]

    /// The steps every Hindi or Gujarati pronunciation goes through, whether it was read from
    /// the script, from a dictionary's transliteration or from Roman letters.
    static func finish(_ input: Pron, language: Language, collapsingDoubles: Bool = true) -> Pron {
        var phones = input.map { $0.withStress(0) }

        if collapsingDoubles {
            // A doubled consonant (pakka, accha) rhymes as a single one.
            var collapsed: Pron = []
            for phone in phones {
                if let previous = collapsed.last, !phone.isVowel {
                    if previous == phone { continue }
                    if aspirateOf[previous.symbol] == phone.symbol {
                        collapsed[collapsed.count - 1] = phone
                        continue
                    }
                }
                collapsed.append(phone)
            }
            phones = collapsed
        }

        if language == .hindi {
            // "a" before h is said "e": kehna, pehla, sheher.
            let schwa = Phone.vowel("AH"), h = Phone.consonant("HH"), open = Phone.vowel("EH")
            for index in phones.indices where phones[index] == schwa && index + 1 < phones.count && phones[index + 1] == h {
                let after = index + 2 < phones.count ? phones[index + 2] : nil
                if after == nil || !after!.isVowel {
                    phones[index] = open
                } else if after == schwa, index + 4 == phones.count, !phones[index + 3].isVowel {
                    phones[index] = open
                    phones[index + 2] = open
                }
            }
        }

        if language == .gujarati {
            // Gujarati ડ after a vowel is the flap of Hindi ड़ (gaadi, jhaad).
            for index in phones.indices where phones[index] == .consonant("D") && index > 0 && phones[index - 1].isVowel {
                if index + 1 == phones.count || phones[index + 1] != .consonant("D") { phones[index] = .consonant("RD") }
            }
        }

        // A short i or u that ends a word is said long (kavi, guru).
        if let last = phones.last, last.isVowel {
            if last == .vowel("IH") { phones[phones.count - 1] = .vowel("IY") }
            if last == .vowel("UH") { phones[phones.count - 1] = .vowel("UW") }
        }

        // Two vowels with nothing between them run together when sung: bhai, koi, gayi.
        var merged: Pron = []
        for phone in phones {
            if let previous = merged.last, previous.isVowel, phone.isVowel {
                let first = Phone.vowelSymbols[previous.vowelBase], second = Phone.vowelSymbols[phone.vowelBase]
                let glide: String? = switch (first, second) {
                case ("AA", "IY"), ("AA", "IH"), ("AH", "IY"), ("AH", "IH"): "AY"
                case ("AA", "UW"), ("AA", "UH"), ("AH", "UW"), ("AH", "UH"): "AW"
                case ("O", "IY"), ("O", "IH"): "OY"
                default: nil
                }
                if let glide {
                    merged[merged.count - 1] = .vowel(glide)
                    continue
                }
            }
            merged.append(phone)
        }
        return anchored(merged)
    }

    /// Neither language has stress the way English does, so mark where a rhyme starts instead:
    /// a word ending in a consonant or a glide rhymes from its last vowel (pyaar, dil, bhai),
    /// and one ending in a plain vowel from the vowel before it (kah-AA-ni, m-E-ra).
    static func anchored(_ phones: Pron) -> Pron {
        var result = phones
        let vowelPositions = result.indices.filter { result[$0].isVowel }
        guard let lastVowel = vowelPositions.last else { return result }
        let glides: Set<String> = ["AY", "AW", "OY"]
        let endsOpen = lastVowel == result.count - 1 && !glides.contains(Phone.vowelSymbols[result[lastVowel].vowelBase])
        let anchor = endsOpen && vowelPositions.count >= 2 ? vowelPositions[vowelPositions.count - 2] : lastVowel
        result[anchor] = result[anchor].withStress(1)
        return result
    }

    // MARK: Roman letters

    private static let romanConsonants: [String: String] = [
        "K": "k", "KX": "kh", "G": "g", "GX": "gh", "NG": "ng", "CH": "ch", "CX": "chh", "JH": "j", "JX": "jh",
        "NY": "ny", "T": "t", "TX": "th", "D": "d", "DX": "dh", "NR": "n", "TD": "t", "TDH": "th", "DD": "d",
        "DDH": "dh", "N": "n", "P": "p", "PX": "ph", "F": "f", "B": "b", "BX": "bh", "M": "m", "Y": "y", "R": "r",
        "L": "l", "V": "v", "W": "w", "SH": "sh", "S": "s", "HH": "h", "Z": "z", "ZH": "zh", "RD": "d", "LR": "l",
        "HX": "kh", "RR": "r", "TH": "th", "DH": "d",
    ]

    /// Phones to the casual romanization people actually type: pyaar, zindagi, mera.
    static func romanize(_ pron: Pron) -> String {
        var out = ""
        for (index, phone) in pron.enumerated() {
            let isLast = index == pron.count - 1
            let next = isLast ? nil : pron[index + 1]
            guard phone.isVowel else {
                if phone.symbol == "NG", let next, ["G", "GX", "K", "KX"].contains(next.symbol) {
                    out += "n"
                } else {
                    out += romanConsonants[phone.symbol] ?? phone.symbol.lowercased()
                }
                continue
            }
            switch Phone.vowelSymbols[phone.vowelBase] {
            case "AA": out += isLast || next?.isVowel == true ? "a" : "aa"
            case "IH": out += "i"
            case "IY": out += isLast ? "i" : "ee"
            case "UH": out += "u"
            case "UW": out += isLast ? "u" : "oo"
            case "E", "EY", "EH": out += "e"
            case "AE", "AY": out += "ai"
            case "O", "OW": out += "o"
            case "AO", "AW": out += "au"
            case "OY": out += "oi"
            default: out += "a"
            }
        }
        return out
    }

    /// Spelling differences that don't change the word: pyar / pyaar, wo / vo, kya / kia.
    static func tightKey(_ roman: String) -> String {
        var text = String(roman.lowercased().unicodeScalars.filter { (97...122).contains($0.value) })
        for (from, to) in [("aa", "a"), ("ee", "i"), ("oo", "u"), ("w", "v"), ("ph", "f"), ("q", "k"), ("ck", "k"), ("x", "ks"), ("y", "i")] {
            while text.contains(from) { text = text.replacingOccurrences(of: from, with: to) }
        }
        var collapsed = ""
        for character in text where collapsed.last != character { collapsed.append(character) }
        return collapsed
    }

    /// A much blunter key for when the tight one finds nothing: drops every "a", aspiration,
    /// a nasal ending and the ai/e and au/o distinctions (zindgi / zindagi, mujhe / muje, hain / hai).
    static func looseKey(_ roman: String) -> String {
        var text = tightKey(roman)
        if text.count > 2, text.hasSuffix("n"), "aeiou".contains(text[text.index(text.endIndex, offsetBy: -2)]) {
            text.removeLast()
        }
        for (from, to) in [("z", "j"), ("ai", "e"), ("ei", "e"), ("ae", "e"), ("au", "o"), ("ou", "o")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        let letters = Array(text)
        var out = ""
        for (index, character) in letters.enumerated() {
            if character == "h", index > 0, "kgcjtdpbs".contains(letters[index - 1]) { continue }
            if character == "a" { continue }
            out.append(character)
        }
        if out.count > 1, out.hasSuffix("h") { out.removeLast() }
        return out
    }

    /// A romanized word nobody has in a dictionary, read by the usual conventions.
    static func guessRoman(_ word: String, language: Language) -> Pron {
        let letters = Array(word.lowercased().unicodeScalars.filter { (97...122).contains($0.value) }.map(Character.init))
        var out: Pron = []
        var index = 0

        func matches(_ text: String) -> Bool {
            let chars = Array(text)
            return index + chars.count <= letters.count && Array(letters[index..<(index + chars.count)]) == chars
        }
        func emit(_ symbols: String...) {
            out += symbols.map { Phone.vowelSymbols.contains($0) ? Phone.vowel($0) : Phone.consonant($0) }
        }

        let clusters: [(String, [String])] = [
            ("chh", ["CX"]), ("ksh", ["K", "SH"]), ("kh", ["KX"]), ("gh", ["GX"]), ("ch", ["CH"]), ("jh", ["JX"]),
            ("th", ["TDH"]), ("dh", ["DDH"]), ("ph", ["PX"]), ("bh", ["BX"]), ("sh", ["SH"]), ("zh", ["ZH"]),
            ("nk", ["NG", "K"]), ("ng", ["NG", "G"]),
            ("aa", ["AA"]), ("ai", ["AE"]), ("au", ["AO"]), ("ee", ["IY"]), ("ii", ["IY"]), ("oo", ["UW"]),
            ("uu", ["UW"]), ("ou", ["AO"]), ("ei", ["E"]),
        ]
        let singles: [Character: String] = [
            "b": "B", "c": "K", "d": "DD", "f": "F", "g": "G", "h": "HH", "j": "JH", "k": "K", "l": "L", "m": "M",
            "n": "N", "p": "P", "q": "K", "r": "R", "s": "S", "t": "TD", "v": "V", "w": "V", "y": "Y", "z": "Z",
        ]

        outer: while index < letters.count {
            for (text, symbols) in clusters where matches(text) {
                out += symbols.map { Phone.vowelSymbols.contains($0) ? Phone.vowel($0) : Phone.consonant($0) }
                index += text.count
                continue outer
            }
            let letter = letters[index]
            let isLast = index == letters.count - 1
            switch letter {
            case "a": emit(isLast ? "AA" : "AH")
            case "i": emit("IH")
            case "u": emit("UH")
            case "e": emit("E")
            case "o": emit("O")
            case "x": emit("K", "S")
            default:
                if let symbol = singles[letter] { emit(symbol) }
            }
            index += 1
        }
        return finish(out, language: language)
    }
}
