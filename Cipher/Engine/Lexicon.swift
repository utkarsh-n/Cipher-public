import Foundation

/// How a word is said: its pronunciations, whether they came from a dictionary, and which entry.
struct Pronunciation: Sendable {
    var prons: [Pron] = []
    /// False when the sound was guessed from spelling.
    var known = false
    var entry: Int32?
}

/// The compiled four-language pronouncing dictionary (built by Tools/lexgen): every word's
/// sounds, romanization and meaning, plus a hash index of everything worth looking up by sound
/// or by sense. The file is mapped into memory and read in place, so opening it is instant.
final class Lexicon: @unchecked Sendable {
    private let data: NSData
    let count: Int
    private let keyCount: Int
    private let languages: UnsafePointer<UInt8>
    private let tiers: UnsafePointer<UInt8>
    private let freqs: UnsafePointer<UInt8>
    private let pronOffsets: UnsafePointer<UInt32>
    private let phones: UnsafePointer<UInt8>
    private let textOffsets: UnsafePointer<UInt32>
    private let text: UnsafePointer<UInt8>
    private let keys: UnsafePointer<UInt64>
    private let starts: UnsafePointer<UInt32>
    private let postings: UnsafePointer<Int32>
    private let ranges: [Range<Int>]

    init(contentsOf url: URL) throws {
        data = try NSData(contentsOf: url, options: .mappedIfSafe)
        let base = data.bytes
        let header = base.assumingMemoryBound(to: UInt64.self)
        guard data.length >= LexiconFormat.headerBytes, header[LexiconFormat.Field.magic.rawValue] == LexiconFormat.magic else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func field(_ field: LexiconFormat.Field) -> Int { Int(header[field.rawValue]) }
        func section<T>(_ field: LexiconFormat.Field, as type: T.Type) -> UnsafePointer<T> {
            (base + Int(header[field.rawValue])).assumingMemoryBound(to: type)
        }
        count = field(.entryCount)
        keyCount = field(.keyCount)
        languages = section(.languages, as: UInt8.self)
        tiers = section(.tiers, as: UInt8.self)
        freqs = section(.freqs, as: UInt8.self)
        pronOffsets = section(.pronOffsets, as: UInt32.self)
        phones = section(.phones, as: UInt8.self)
        textOffsets = section(.textOffsets, as: UInt32.self)
        text = section(.text, as: UInt8.self)
        keys = section(.keys, as: UInt64.self)
        starts = section(.starts, as: UInt32.self)
        postings = section(.postings, as: Int32.self)
        ranges = Language.allCases.indices.map { index in
            let first = LexiconFormat.Field.ranges.rawValue + index * 2
            return Int(header[first])..<Int(header[first + 1])
        }
    }

    // MARK: Entries

    func language(_ entry: Int32) -> Language { Language(rawValue: languages[Int(entry)]) ?? .english }

    /// 0 everyday, 1 known, 2 names and rare forms.
    func tier(_ entry: Int32) -> UInt8 { tiers[Int(entry)] }

    /// 0...200, higher is more common; 0 when the word was not seen in the frequency lists.
    func freq(_ entry: Int32) -> UInt8 { freqs[Int(entry)] }

    func pron(_ entry: Int32) -> Pron {
        (Int(pronOffsets[Int(entry)])..<Int(pronOffsets[Int(entry) + 1])).map { Phone(phones[$0]) }
    }

    /// The word as written in its own script.
    func word(_ entry: Int32) -> String { field(entry, 0) }

    /// Roman-letter form of a Hindi or Gujarati word; empty for English and Spanish.
    func roman(_ entry: Int32) -> String { field(entry, 1) }

    /// Short English meaning; empty when the dictionaries have none.
    func gloss(_ entry: Int32) -> String { field(entry, 2) }

    /// Each entry's text is "word<TAB>roman<TAB>gloss".
    private func field(_ entry: Int32, _ number: Int) -> String {
        let end = Int(textOffsets[Int(entry) + 1])
        var start = Int(textOffsets[Int(entry)])
        var remaining = number
        var cursor = start
        while cursor < end {
            if text[cursor] == 9 {
                if remaining == 0 { break }
                remaining -= 1
                start = cursor + 1
            }
            cursor += 1
        }
        guard remaining == 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: text + start, count: cursor - start), as: UTF8.self)
    }

    // MARK: Lookup

    func entries(_ kind: IndexKind, _ phones: Pron) -> UnsafeBufferPointer<Int32> {
        entries(key: LexiconKey.sound(kind, phones))
    }

    func entries(key: UInt64) -> UnsafeBufferPointer<Int32> {
        var low = 0, high = keyCount
        while low < high {
            let mid = (low + high) / 2
            if keys[mid] < key { low = mid + 1 } else { high = mid }
        }
        guard low < keyCount, keys[low] == key else { return UnsafeBufferPointer(start: nil, count: 0) }
        return UnsafeBufferPointer(start: postings + Int(starts[low]), count: Int(starts[low + 1] - starts[low]))
    }

    /// Other-language words whose meaning includes this English term.
    func entries(meaning term: String) -> UnsafeBufferPointer<Int32> {
        entries(key: LexiconKey.text(.glossTerm, term))
    }

    /// Entries spelled exactly this way (already cleaned) in one language. Words are stored
    /// sorted by their UTF-8 bytes within each language.
    func entries(forWord word: String, in language: Language) -> Range<Int32> {
        let query = Array(word.utf8)
        let range = ranges[Int(language.rawValue)]
        var low = range.lowerBound, high = range.upperBound
        while low < high {
            let mid = (low + high) / 2
            if compare(mid, query) < 0 { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < range.upperBound, compare(end, query) == 0 { end += 1 }
        return Int32(low)..<Int32(end)
    }

    /// Entries whose spelling starts with `prefix`, in one language, in dictionary order.
    func entries(withPrefix prefix: String, in language: Language, limit: Int = 300) -> [Int32] {
        let query = Array(prefix.utf8)
        guard !query.isEmpty else { return [] }
        let range = ranges[Int(language.rawValue)]
        var low = range.lowerBound, high = range.upperBound
        while low < high {
            let mid = (low + high) / 2
            if compare(mid, query) < 0 { low = mid + 1 } else { high = mid }
        }
        var found: [Int32] = []
        var cursor = low
        while cursor < range.upperBound, found.count < limit, hasPrefix(cursor, query) {
            found.append(Int32(cursor))
            cursor += 1
        }
        return found
    }

    private func hasPrefix(_ entry: Int, _ query: [UInt8]) -> Bool {
        var cursor = Int(textOffsets[entry])
        let end = Int(textOffsets[entry + 1])
        for byte in query {
            if cursor >= end || text[cursor] != byte { return false }
            cursor += 1
        }
        return true
    }

    private func compare(_ entry: Int, _ query: [UInt8]) -> Int {
        var cursor = Int(textOffsets[entry])
        let end = Int(textOffsets[entry + 1])
        for byte in query {
            if cursor >= end || text[cursor] == 9 { return -1 }
            if text[cursor] != byte { return text[cursor] < byte ? -1 : 1 }
            cursor += 1
        }
        return cursor >= end || text[cursor] == 9 ? 0 : 1
    }

    /// The most common entry among several.
    private func best(_ candidates: some Sequence<Int32>) -> Int32? {
        candidates.max { (Int(freq($0)), -Int(tier($0))) < (Int(freq($1)), -Int(tier($1))) }
    }

    func bestEntry(forWord word: String, in language: Language) -> Int32? {
        best(entries(forWord: word, in: language))
    }

    /// The Hindi or Gujarati word someone most likely meant by a Roman spelling. `loose` also
    /// accepts spellings that only roughly agree (muje for mujhe, zindgi for zindagi).
    func romanMatch(_ roman: String, in language: Language, loose: Bool = true) -> Int32? {
        let tight = IndicG2P.tightKey(roman)
        guard !tight.isEmpty else { return nil }
        var exact = Array(entries(key: LexiconKey.text(.romanTight, tight, language: language)))
        // nahin, main, hoon: a final n that only marks a nasal vowel. Weighed alongside the
        // literal reading, so "main" is मैं rather than some rarer word spelled m-a-i-n.
        if tight.count > 2, tight.hasSuffix("n") {
            exact += entries(key: LexiconKey.text(.romanTight, String(tight.dropLast()), language: language))
        }
        if let hit = best(exact) { return hit }
        // The unwritten "a" is often typed as a "u": hum, sub, kub.
        if tight.contains("u"),
           let hit = best(entries(key: LexiconKey.text(.romanTight, tight.replacingOccurrences(of: "u", with: "a"), language: language))) {
            return hit
        }
        guard loose else { return nil }
        let candidates = entries(key: LexiconKey.text(.romanLoose, IndicG2P.looseKey(roman), language: language))
        let allowance = max(1, tight.count / 3)
        var chosen: (entry: Int32, distance: Int)?
        for candidate in candidates {
            let distance = Lexicon.editDistance(tight, IndicG2P.tightKey(self.roman(candidate)))
            guard distance <= allowance else { continue }
            if let current = chosen {
                if (distance, -Int(freq(candidate))) < (current.distance, -Int(freq(current.entry))) {
                    chosen = (candidate, distance)
                }
            } else {
                chosen = (candidate, distance)
            }
        }
        return chosen?.entry
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a.utf8), y = Array(b.utf8)
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count]
    }

    // MARK: Pronouncing arbitrary text

    /// How a word is said in a given language, as typed. Hindi and Gujarati are accepted in
    /// their own scripts or in Roman letters; a word written in an Indic script is always read
    /// as that script's language.
    func pronounce(_ raw: String, as requested: Language) -> Pronunciation {
        let word = Tokenizer.clean(raw)
        guard !word.isEmpty else { return Pronunciation() }
        let script = Script.of(word)
        let language: Language = switch script {
        case .devanagari: .hindi
        case .gujarati: .gujarati
        default: requested
        }
        switch language {
        case .english:
            return pronounceEnglish(word)
        case .spanish:
            let exact = entries(forWord: word, in: .spanish)
            if let first = exact.first { return Pronunciation(prons: [pron(first)], known: true, entry: bestEntry(forWord: word, in: .spanish)) }
            let rules = SpanishG2P.pronounce(word)
            return Pronunciation(prons: rules.isEmpty ? [] : [rules], known: true, entry: nil)
        case .french:
            // The dictionary spells cœur without its ligature.
            let plain = word.replacingOccurrences(of: "œ", with: "oe").replacingOccurrences(of: "æ", with: "ae")
            if let entry = bestEntry(forWord: plain, in: .french) {
                // The commonest reading leads: "est" is the verb before it is the compass point.
                let all = entries(forWord: plain, in: .french).sorted { freq($0) > freq($1) }
                return Pronunciation(prons: all.map { pron($0) }, known: true, entry: entry)
            }
            // l'amour, j'ai, qu'il: a clitic fused onto the word that follows.
            if let apostrophe = word.firstIndex(of: "'"), let lead = FrenchG2P.clitics[String(word[..<apostrophe])] {
                let rest = pronounce(String(word[word.index(after: apostrophe)...]), as: .french)
                if let main = rest.prons.first {
                    let onset = lead.map { Phone.vowelSymbols.contains($0) ? Phone.vowel($0) : Phone.consonant($0) }
                    return Pronunciation(prons: [onset + main], known: rest.known, entry: rest.entry)
                }
            }
            let rules = FrenchG2P.pronounce(word)
            return Pronunciation(prons: rules.isEmpty ? [] : [rules], known: false, entry: nil)
        case .hindi, .gujarati:
            if script == .latin {
                if let entry = romanMatch(word, in: language) {
                    return Pronunciation(prons: [pron(entry)], known: true, entry: entry)
                }
                let guess = IndicG2P.guessRoman(word, language: language)
                return Pronunciation(prons: guess.isEmpty ? [] : [guess], known: false, entry: nil)
            }
            if let entry = bestEntry(forWord: word, in: language) {
                return Pronunciation(prons: [pron(entry)], known: true, entry: entry)
            }
            let rules = IndicG2P.pronounce(word, language: language)
            return Pronunciation(prons: rules.isEmpty ? [] : [rules], known: true, entry: nil)
        }
    }

    private func englishProns(_ word: String) -> [Pron] {
        entries(forWord: word, in: .english).map { pron($0) }
    }

    /// English falls back to stripping slang spellings and common suffixes, and finally to
    /// guessing from the spelling.
    private func pronounceEnglish(_ word: String) -> Pronunciation {
        let exact = englishProns(word)
        if !exact.isEmpty { return Pronunciation(prons: exact, known: true, entry: bestEntry(forWord: word, in: .english)) }
        let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        if bare != word {
            let trimmed = englishProns(bare)
            if !trimmed.isEmpty { return Pronunciation(prons: trimmed, known: true, entry: bestEntry(forWord: bare, in: .english)) }
        }
        if let derived = derive(bare) { return Pronunciation(prons: [derived], known: true, entry: nil) }
        let guess = Guesser.guess(bare)
        return Pronunciation(prons: guess.isEmpty ? [] : [guess], known: false, entry: nil)
    }

    private func derive(_ word: String) -> Pron? {
        func base(_ text: String) -> Pron? { englishProns(text).first }
        let voiceless: Set<String> = ["P", "T", "K", "F", "TH"]
        let sibilant: Set<String> = ["S", "Z", "SH", "ZH", "CH", "JH"]

        // runnin, runnin' -> running, with the g dropped.
        if word.hasSuffix("in"), var pron = base(word + "g"), pron.last == .consonant("NG") {
            pron[pron.count - 1] = .consonant("N")
            return pron
        }
        // gangsta, killa -> gangster, killer.
        if word.hasSuffix("a"), var pron = base(String(word.dropLast()) + "er"), let last = pron.last,
           last.isVowel, Phone.vowelSymbols[last.vowelBase] == "ER" {
            pron[pron.count - 1] = .vowel("AH")
            return pron
        }
        if word.hasSuffix("'s") || word.hasSuffix("s") {
            let stem = String(word.dropLast(word.hasSuffix("'s") ? 2 : 1))
            if stem.count > 1, let pron = base(stem), let last = pron.last {
                if sibilant.contains(last.symbol) { return pron + [.vowel("IX"), .consonant("Z")] }
                return pron + [.consonant(voiceless.contains(last.symbol) ? "S" : "Z")]
            }
        }
        if word.hasSuffix("ed") {
            for stem in [String(word.dropLast(2)), String(word.dropLast(1))] {
                if stem.count > 1, let pron = base(stem), let last = pron.last {
                    if last.symbol == "T" || last.symbol == "D" { return pron + [.vowel("IX"), .consonant("D")] }
                    return pron + [.consonant(voiceless.union(["S", "SH", "CH"]).contains(last.symbol) ? "T" : "D")]
                }
            }
        }
        if word.hasSuffix("ing") {
            for stem in [String(word.dropLast(3)), String(word.dropLast(3)) + "e", String(word.dropLast(4))] {
                if stem.count > 1, let pron = base(stem) { return pron + [.vowel("IX"), .consonant("NG")] }
            }
        }
        if word.hasSuffix("ly"), let pron = base(String(word.dropLast(2))) {
            return pron + [.consonant("L"), .vowel("IY")]
        }
        if word.hasSuffix("er"), let pron = base(String(word.dropLast(2))) ?? base(String(word.dropLast(1))) {
            return pron + [.vowel("ER")]
        }
        if word.hasSuffix("y"), let pron = base(String(word.dropLast(1))) {
            return pron + [.vowel("IY")]
        }
        return nil
    }
}
