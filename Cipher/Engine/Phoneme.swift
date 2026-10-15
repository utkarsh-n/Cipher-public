import Foundation

/// One speech sound in a byte. A single inventory covers English, Hindi, Gujarati, Spanish and French,
/// so words that sound alike come out as the same bytes whatever language or script they were
/// written in. Consonants are 0..<Phone.consonantCount; vowels follow as base * 3 + stress.
///
/// The lexicon files are generated from this same table (Tools/lexgen), so reordering it means
/// regenerating them.
struct Phone: Hashable, Sendable {
    let code: UInt8

    init(_ code: UInt8) { self.code = code }

    enum Manner { case stop, affricate, fricative, nasal, rhotic, lateral, glide }
    enum Place { case labial, dental, alveolar, retroflex, postalveolar, palatal, velar, glottal }

    struct Consonant {
        let symbol: String
        let ipa: String
        let manner: Manner
        let place: Place
        let voiced: Bool
        /// Aspirated, or trilled for a rhotic: the same sound with something extra on it.
        let marked: Bool
    }

    private static func c(_ symbol: String, _ ipa: String, _ manner: Manner, _ place: Place, voiced: Bool, marked: Bool = false) -> Consonant {
        Consonant(symbol: symbol, ipa: ipa, manner: manner, place: place, voiced: voiced, marked: marked)
    }

    static let consonants: [Consonant] = [
        // English (ARPAbet names). Hindi's retroflex ट ड land on T and D: that is where Hindi
        // itself puts English t and d (टाइम, डॉक्टर).
        c("B", "b", .stop, .labial, voiced: true),
        c("CH", "tʃ", .affricate, .postalveolar, voiced: false),
        c("D", "d", .stop, .alveolar, voiced: true),
        c("DH", "ð", .fricative, .dental, voiced: true),
        c("F", "f", .fricative, .labial, voiced: false),
        c("G", "ɡ", .stop, .velar, voiced: true),
        c("HH", "h", .fricative, .glottal, voiced: false),
        c("JH", "dʒ", .affricate, .postalveolar, voiced: true),
        c("K", "k", .stop, .velar, voiced: false),
        c("L", "l", .lateral, .alveolar, voiced: true),
        c("M", "m", .nasal, .labial, voiced: true),
        c("N", "n", .nasal, .alveolar, voiced: true),
        c("NG", "ŋ", .nasal, .velar, voiced: true),
        c("P", "p", .stop, .labial, voiced: false),
        c("R", "r", .rhotic, .alveolar, voiced: true),
        c("S", "s", .fricative, .alveolar, voiced: false),
        c("SH", "ʃ", .fricative, .postalveolar, voiced: false),
        c("T", "t", .stop, .alveolar, voiced: false),
        c("TH", "θ", .fricative, .dental, voiced: false),
        c("V", "v", .fricative, .labial, voiced: true),
        c("W", "w", .glide, .labial, voiced: true),
        c("Y", "j", .glide, .palatal, voiced: true),
        c("Z", "z", .fricative, .alveolar, voiced: true),
        c("ZH", "ʒ", .fricative, .postalveolar, voiced: true),
        // Dental stops: Hindi and Gujarati त थ द ध, and Spanish t d.
        c("TD", "t̪", .stop, .dental, voiced: false),
        c("TDH", "t̪ʰ", .stop, .dental, voiced: false, marked: true),
        c("DD", "d̪", .stop, .dental, voiced: true),
        c("DDH", "d̪ʱ", .stop, .dental, voiced: true, marked: true),
        // Aspirates: ख घ छ झ ठ ढ फ भ.
        c("KX", "kʰ", .stop, .velar, voiced: false, marked: true),
        c("GX", "ɡʱ", .stop, .velar, voiced: true, marked: true),
        c("CX", "tʃʰ", .affricate, .postalveolar, voiced: false, marked: true),
        c("JX", "dʒʱ", .affricate, .postalveolar, voiced: true, marked: true),
        c("TX", "tʰ", .stop, .alveolar, voiced: false, marked: true),
        c("DX", "dʱ", .stop, .alveolar, voiced: true, marked: true),
        c("PX", "pʰ", .stop, .labial, voiced: false, marked: true),
        c("BX", "bʱ", .stop, .labial, voiced: true, marked: true),
        c("NY", "ɲ", .nasal, .palatal, voiced: true),          // ñ, ञ
        c("HX", "x", .fricative, .velar, voiced: false),       // Spanish j, ख़
        c("RD", "ɽ", .rhotic, .retroflex, voiced: true),       // ड़ ढ़
        c("RR", "rr", .rhotic, .alveolar, voiced: true, marked: true), // Spanish rr
        c("NR", "ɳ", .nasal, .retroflex, voiced: true),        // ण
        c("LR", "ɭ", .lateral, .retroflex, voiced: true),      // ળ
    ]

    /// E and O are the pure mid vowels of Spanish, French, Hindi and Gujarati (as against the
    /// English glides EY and OW). IX is English's reduced "ih" (roses, running), which rhymes as
    /// a schwa. The last five are French: u as in "tu", eu as in "feu", and the nasals of
    /// "dans", "vin" and "bon".
    static let vowelSymbols = [
        "AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW",
        "E", "O", "IX", "UE", "EU", "AN", "IN", "ON",
    ]
    private static let vowelIPA = [
        "ɑ", "æ", "ʌ", "ɔ", "aʊ", "aɪ", "ɛ", "ɝ", "eɪ", "ɪ", "i", "oʊ", "ɔɪ", "ʊ", "u",
        "e", "o", "ɪ", "y", "ø", "ɑ̃", "ɛ̃", "ɔ̃",
    ]

    static let consonantCount = UInt8(consonants.count)

    private static let consonantCodes: [String: UInt8] = Dictionary(
        uniqueKeysWithValues: consonants.enumerated().map { ($1.symbol, UInt8($0)) }
    )
    private static let vowelBases: [String: UInt8] = Dictionary(
        uniqueKeysWithValues: vowelSymbols.enumerated().map { ($1, UInt8($0)) }
    )

    /// "AY1", "K", "TD": the symbol names used in the tables above, vowels with a stress digit.
    init?(symbol: String) {
        if let code = Phone.consonantCodes[symbol] {
            self.code = code
        } else if let last = symbol.last, let stress = UInt8(String(last)), stress < 3,
                  let base = Phone.vowelBases[String(symbol.dropLast())] {
            self.code = Phone.consonantCount + base * 3 + stress
        } else {
            return nil
        }
    }

    static func vowel(_ symbol: String, stress: UInt8 = 0) -> Phone {
        Phone(consonantCount + vowelBases[symbol]! * 3 + stress)
    }

    static func consonant(_ symbol: String) -> Phone {
        Phone(consonantCodes[symbol]!)
    }

    var isVowel: Bool { code >= Phone.consonantCount }
    var vowelBase: Int { Int(code - Phone.consonantCount) / 3 }
    var stress: UInt8 { (code - Phone.consonantCount) % 3 }
    var isStressedVowel: Bool { isVowel && stress > 0 }

    func withStress(_ stress: UInt8) -> Phone {
        isVowel ? Phone(Phone.consonantCount + UInt8(vowelBase) * 3 + stress) : self
    }

    private static let schwa = Phone.vowel("AH")
    private static let reducedBase = vowelBases["IX"]!

    /// Stress removed, and English's reduced "ih" folded into schwa, so that pronunciations
    /// which differ only in emphasis compare equal.
    var normalized: Phone {
        guard isVowel else { return self }
        return vowelBase == Int(Phone.reducedBase) ? Phone.schwa : withStress(0)
    }

    /// Stress removed, nothing folded: the reduced "ih" stays an "ih".
    var unstressed: Phone {
        guard isVowel else { return self }
        return vowelBase == Int(Phone.reducedBase) ? Phone.vowel("IH") : withStress(0)
    }

    /// The vowel family used to find rhyme candidates across languages: Spanish "qué" and
    /// English "day" are looked up together, then scored on how close they really are.
    var vowelKey: Phone {
        let plain = normalized
        guard plain.isVowel else { return plain }
        switch Phone.vowelSymbols[plain.vowelBase] {
        case "E": return Phone.vowel("EY")
        case "O", "ON": return Phone.vowel("OW")
        case "AN": return Phone.vowel("AA")
        case "IN": return Phone.vowel("AE")
        default: return plain
        }
    }

    var symbol: String {
        isVowel ? "\(Phone.vowelSymbols[vowelBase])\(stress)" : Phone.consonants[Int(code)].symbol
    }

    var ipa: String {
        guard isVowel else { return Phone.consonants[Int(code)].ipa }
        let mark = stress == 1 ? "ˈ" : stress == 2 ? "ˌ" : ""
        switch (Phone.vowelSymbols[vowelBase], stress) {
        case ("AH", 0): return "ə"
        case ("ER", 0): return "ɚ"
        default: return mark + Phone.vowelIPA[vowelBase]
        }
    }
}

typealias Pron = [Phone]

extension Array where Element == Phone {
    var normalized: Pron { map(\.normalized) }

    var syllableCount: Int { reduce(0) { $0 + ($1.isVowel ? 1 : 0) } }

    /// Index of the vowel a rhyme hangs on: the last stressed vowel, or failing that the last vowel.
    var rhymeStart: Int? {
        lastIndex(where: \.isStressedVowel) ?? lastIndex(where: \.isVowel)
    }

    /// Everything from the rhyming vowel to the end of the word, normalized.
    var rhymeTail: Pron {
        guard let start = rhymeStart else { return [] }
        return self[start...].map(\.normalized)
    }

    var vowels: Pron { filter(\.isVowel).map(\.normalized) }

    /// The word's vowels as cross-language families, for index lookups.
    var vowelKeys: Pron { filter(\.isVowel).map(\.vowelKey) }

    var consonants: Pron { filter { !$0.isVowel } }

    /// Normalized phones from the n-th vowel counting back from the end.
    func tail(fromLastVowels n: Int) -> Pron {
        var seen = 0
        for index in indices.reversed() where self[index].isVowel {
            seen += 1
            if seen == n { return self[index...].map(\.normalized) }
        }
        return []
    }

    /// IPA, for showing a pronunciation to the writer.
    var display: String { map(\.ipa).joined(separator: " ") }
}

/// How alike two sounds are, 0...1. Consonants are compared on how and where they are made;
/// vowels on a table of near pairs. The numbers are judgment calls tuned by ear: voicing pairs
/// (t/d) and aspirates (k/kh) are near-identical, nasals and liquids swap freely, and so on.
enum Similarity {
    private static func mannerDistance(_ a: Phone.Manner, _ b: Phone.Manner) -> Double {
        if a == b { return 0 }
        switch (a, b) {
        case (.stop, .affricate), (.affricate, .stop), (.affricate, .fricative), (.fricative, .affricate): return 0.5
        case (.rhotic, .lateral), (.lateral, .rhotic): return 0.5
        case (.stop, .fricative), (.fricative, .stop): return 0.7
        default: return 1
        }
    }

    private static func placeDistance(_ a: Phone.Place, _ b: Phone.Place) -> Double {
        if a == b { return 0 }
        func group(_ place: Phone.Place) -> Int {
            switch place {
            case .labial: 0
            case .dental, .alveolar, .retroflex: 1
            case .postalveolar, .palatal: 2
            case .velar: 3
            case .glottal: 4
            }
        }
        let (x, y) = (min(group(a), group(b)), max(group(a), group(b)))
        if x == y { return 0.25 }
        if (x, y) == (1, 2) { return 0.6 }
        if (x, y) == (3, 4) { return 0.7 }
        return 1
    }

    /// Pairs the feature arithmetic gets wrong: sounds that different languages, or different
    /// speakers of one language, treat as the same thing.
    private static let consonantOverrides: [(String, String, Double)] = [
        ("W", "V", 0.8),      // Hindi व is both
        ("HX", "HH", 0.8),    // Spanish j ~ English h
        ("HX", "KX", 0.8),    // ख़ ~ ख
        ("F", "PX", 0.85),    // फ़ ~ फ
        ("Z", "JH", 0.7),     // zindagi / jindagi
        ("RD", "D", 0.6),     // ड़ ~ ड
        ("TDH", "TH", 0.9),   // थ is how Indian English says "th"
        ("DD", "DH", 0.9),    // and द is "the"
        ("TD", "TH", 0.7),
        ("DDH", "DH", 0.8),
        ("NG", "N", 0.7),     // runnin' / running
    ]

    static let consonantTable: [[Double]] = {
        let all = Phone.consonants
        var table = [[Double]](repeating: [Double](repeating: 0, count: all.count), count: all.count)
        for (i, a) in all.enumerated() {
            for (j, b) in all.enumerated() {
                if i == j {
                    table[i][j] = 1
                    continue
                }
                let distance = 0.6 * mannerDistance(a.manner, b.manner) + 0.4 * placeDistance(a.place, b.place)
                    + (a.voiced == b.voiced ? 0 : 0.15) + (a.marked == b.marked ? 0 : 0.1)
                table[i][j] = max(0.05, 1 - distance)
            }
        }
        for (a, b, score) in consonantOverrides {
            let i = Int(Phone.consonant(a).code), j = Int(Phone.consonant(b).code)
            table[i][j] = score
            table[j][i] = score
        }
        return table
    }()

    private static let nearVowels: [(String, String, Double)] = [
        ("AA", "AO", 0.85), ("AA", "AH", 0.6), ("AH", "ER", 0.7), ("AE", "EH", 0.6),
        ("EH", "IH", 0.65), ("IH", "IY", 0.6), ("EH", "EY", 0.55), ("UH", "UW", 0.65),
        ("AO", "OW", 0.6), ("AH", "UH", 0.6), ("AA", "AW", 0.4), ("AA", "AY", 0.4),
        ("AY", "OY", 0.5), ("AW", "OW", 0.45), ("ER", "UH", 0.4), ("IY", "EY", 0.45),
        // The pure mid vowels sit between their English neighbours.
        ("E", "EY", 0.85), ("E", "EH", 0.8), ("E", "AE", 0.5), ("E", "IH", 0.45), ("E", "IY", 0.4),
        ("O", "OW", 0.85), ("O", "AO", 0.8), ("O", "UH", 0.4), ("O", "UW", 0.35), ("O", "AA", 0.35),
        ("IX", "IH", 0.9), ("IX", "AH", 0.85), ("IX", "EH", 0.6), ("IX", "ER", 0.6),
        // French: the rounded front vowels have no English twin, and a nasal vowel is closest
        // to its oral partner.
        ("UE", "UW", 0.65), ("UE", "IY", 0.6), ("UE", "UH", 0.5),
        ("EU", "ER", 0.75), ("EU", "AH", 0.6), ("EU", "UH", 0.55), ("EU", "UE", 0.5),
        ("AN", "AA", 0.8), ("AN", "AO", 0.65), ("AN", "ON", 0.7), ("AN", "AH", 0.5),
        ("ON", "O", 0.8), ("ON", "AO", 0.75), ("ON", "OW", 0.7),
        ("IN", "AE", 0.8), ("IN", "EH", 0.75), ("IN", "AN", 0.6), ("IN", "E", 0.5),
    ]

    static let vowelTable: [[Double]] = {
        let count = Phone.vowelSymbols.count
        var table = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
        for i in 0..<count { table[i][i] = 1 }
        for (a, b, score) in nearVowels {
            let i = Phone.vowel(a).vowelBase, j = Phone.vowel(b).vowelBase
            table[i][j] = score
            table[j][i] = score
        }
        return table
    }()

    static func of(_ a: Phone, _ b: Phone) -> Double {
        switch (a.isVowel, b.isVowel) {
        case (true, true): return vowelTable[a.vowelBase][b.vowelBase]
        case (false, false): return consonantTable[Int(a.code)][Int(b.code)]
        default: return 0
        }
    }

    /// Vowel families close enough to `vowel` to stand in for it, as index keys.
    static func neighborKeys(of vowel: Phone, atLeast floor: Double) -> [Phone] {
        let own = vowel.vowelKey
        var keys: [Phone] = []
        for (base, score) in vowelTable[vowel.vowelBase].enumerated() where score >= floor {
            let key = Phone(Phone.consonantCount + UInt8(base) * 3).vowelKey
            if key != own && !keys.contains(key) { keys.append(key) }
        }
        return keys
    }

    /// How well two consonant clusters line up, 0...1.
    static func cluster(_ a: ArraySlice<Phone>, _ b: ArraySlice<Phone>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) == 1 ? 0.35 : 0.2 }
        let x = Array(a), y = Array(b)
        var best = [[Double]](repeating: [Double](repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 1...x.count {
            for j in 1...y.count {
                best[i][j] = max(best[i - 1][j], best[i][j - 1], best[i - 1][j - 1] + of(x[i - 1], y[j - 1]))
            }
        }
        return best[x.count][y.count] / Double(max(x.count, y.count))
    }

    /// How well two rhyme tails match, 0...1. Both must start on a vowel and have the same
    /// number of syllables. Vowels carry the rhyme; the consonants after them colour it.
    static func tails(_ a: Pron, _ b: Pron) -> Double {
        let unitsA = syllableUnits(a), unitsB = syllableUnits(b)
        guard !unitsA.isEmpty, unitsA.count == unitsB.count else { return 0 }
        var vowelScore = 0.0, vowelWeight = 0.0, clusterScore = 0.0, clusterWeight = 0.0
        for index in unitsA.indices {
            // The first vowel is the stressed one and the last cluster is what the ear lands on.
            let vWeight = index == 0 ? 2.0 : 1.0
            let cWeight = index == unitsA.count - 1 ? 2.0 : 1.0
            vowelScore += vWeight * of(unitsA[index].vowel, unitsB[index].vowel)
            vowelWeight += vWeight
            clusterScore += cWeight * cluster(unitsA[index].coda, unitsB[index].coda)
            clusterWeight += cWeight
        }
        return 0.55 * vowelScore / vowelWeight + 0.45 * clusterScore / clusterWeight
    }

    private static func syllableUnits(_ tail: Pron) -> [(vowel: Phone, coda: ArraySlice<Phone>)] {
        var units: [(Phone, ArraySlice<Phone>)] = []
        var index = 0
        while index < tail.count {
            guard tail[index].isVowel else { return [] }
            var end = index + 1
            while end < tail.count && !tail[end].isVowel { end += 1 }
            units.append((tail[index], tail[(index + 1)..<end]))
            index = end
        }
        return units
    }
}
