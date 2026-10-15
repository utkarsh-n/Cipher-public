// Compiles Cipher's lexicon: every word of every language with its sounds, romanization and
// meaning, plus the hash index the app looks things up in. Also extracts the ASL sign table.
//
//   lexgen build <data dir> <output dir>   writes lexicon.bin and signs.tsv
//   lexgen eval <data dir>                 scores the script readers against Wiktionary
//
// Build with Tools/build_lexicon.sh, which compiles this together with the app's own Engine
// sources so that both sides agree on phones, keys and pronunciation rules.

import AppKit
import Foundation
import NaturalLanguage

struct RawEntry {
    var word: String
    var language: Language
    var pron: Pron
    var tier: UInt8
    var freq: UInt8 = 0
    var roman = ""
    /// A second Roman spelling to recognise (the dictionary's own transliteration, simplified).
    var altRoman = ""
    var gloss = ""
}

// MARK: Helpers

func lines(_ url: URL) -> [Substring] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        FileHandle.standardError.write("missing \(url.lastPathComponent)\n".data(using: .utf8)!)
        return []
    }
    // By Character.isNewline, because "\r\n" is a single Character and would never equal "\n".
    return text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
}

/// 1...200 from a frequency rank (200 = the most common word); 0 means unseen.
func frequencyByte(rank: Int?) -> UInt8 {
    guard let rank, rank > 0 else { return 0 }
    return UInt8(max(1, min(200, 200 - Int(12 * log2(Double(rank))))))
}

func nfc(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }

func isWord(_ text: String, in range: ClosedRange<UInt32>, excluding digits: ClosedRange<UInt32>) -> Bool {
    !text.isEmpty && text.unicodeScalars.allSatisfy { range.contains($0.value) && !digits.contains($0.value) && $0.value != 0x0964 && $0.value != 0x0965 }
}

func isDevanagari(_ text: String) -> Bool { isWord(text, in: 0x0900...0x097F, excluding: 0x0966...0x096F) }
func isGujarati(_ text: String) -> Bool { isWord(text, in: 0x0A80...0x0AFF, excluding: 0x0AE6...0x0AEF) }

let latinLetters = CharacterSet.letters.subtracting(CharacterSet(charactersIn: "\u{0900}"..."\u{0AFF}"))
func isLatinWord(_ text: String, apostrophes: Bool = false) -> Bool {
    !text.isEmpty && text.unicodeScalars.allSatisfy { ($0.value < 0x250 && latinLetters.contains($0)) || (apostrophes && $0 == "'") }
        && text.unicodeScalars.first != "'"
}

/// Up to three short meanings joined with "; ", parentheticals removed.
func formatGloss(_ items: [String]) -> String {
    var kept: [String] = []
    for item in items {
        var text = item.replacingOccurrences(of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s*\\[[^\\]]*\\]", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".:")))
        guard !text.isEmpty, text.count <= 32, text.split(separator: " ").count <= 4, !text.contains("\t"),
              !text.contains("("), !text.contains(")"), !text.hasPrefix("e.g"), !text.hasPrefix("i.e"),
              !kept.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) else { continue }
        kept.append(text)
        if kept.count == 3 { break }
    }
    return kept.joined(separator: "; ")
}

/// A WikDict translation table. Entries that only exist capitalised (Amour the river, Seúl)
/// are proper nouns: they must not overwrite the ordinary word, and they are filed as names.
func loadTranslations(_ url: URL) -> (glosses: [String: String], proper: Set<String>) {
    var table: [String: String] = [:]
    var proper = Set<String>()
    let rows = lines(url).compactMap { line -> (String, String)? in
        let parts = line.split(separator: "\t", maxSplits: 1)
        return parts.count == 2 ? (nfc(String(parts[0])), String(parts[1])) : nil
    }
    for capitalised in [false, true] {
        for (source, translations) in rows where (source != source.lowercased()) == capitalised {
            let word = source.lowercased()
            guard table[word] == nil else { continue }
            let gloss = formatGloss(translations.components(separatedBy: " | "))
            guard !gloss.isEmpty else { continue }
            table[word] = gloss
            if capitalised { proper.insert(word) }
        }
    }
    return (table, proper)
}

// MARK: English

let slangSupplement = """
finna F IH1 N AH0|tryna T R AY1 N AH0|homie HH OW1 M IY0|homies HH OW1 M IY0 Z|bando B AE1 N D OW0
shawty SH AO1 T IY0|shorty SH AO1 R T IY0|thot TH AA1 T|hella HH EH1 L AH0|illest IH1 L AH0 S T|tha DH AH0
aint EY1 N T|skrrt S K ER1 T|lambo L AE1 M B OW0|henny HH EH1 N IY0|cuz K AH1 Z|dawg D AO1 G|dawgs D AO1 G Z
nigga N IH1 G AH0|niggas N IH1 G AH0 Z|gangsta G AE1 NG S T AH0|gangstas G AE1 NG S T AH0 Z|playa P L EY1 AH0
holla HH AA1 L AH0|killa K IH1 L AH0|brotha B R AH1 DH AH0|sista S IH1 S T AH0|wanna W AA1 N AH0|gotta G AA1 T AH0
gimme G IH1 M IY0|lemme L EH1 M IY0|kinda K AY1 N D AH0|outta AW1 T AH0|imma AY1 M AH0|ima AY1 M AH0
boutta B AW1 T AH0|yall Y AO1 L|y'all Y AO1 L|opps AA1 P S|bougie B UW1 ZH IY0|boujee B UW1 ZH IY0
drippin D R IH1 P IH0 N|flexin F L EH1 K S IH0 N|trappin T R AE1 P IH0 N|ballin B AO1 L IH0 N
grindin G R AY1 N D IH0 N|stuntin S T AH1 N T IH0 N|whippin W IH1 P IH0 N|vibin V AY1 B IH0 N|vibe V AY1 B
vibes V AY1 B Z|swag S W AE1 G|lit L IH1 T|bussin B AH1 S IH0 N|goat G OW1 T|rizz R IH1 Z|sus S AH1 S|cap K AE1 P
woke W OW1 K|simp S IH1 M P|yeet Y IY1 T|blunt B L AH1 N T|kush K UH1 SH|za Z AA1|lean L IY1 N|perc P ER1 K
percs P ER1 K S|xan Z AE1 N|xans Z AE1 N Z|glizzy G L IH1 Z IY0|draco D R EY1 K OW0|choppa CH AA1 P AH0
strap S T R AE1 P|plug P L AH1 G|guap G W AA1 P|cheddar CH EH1 D ER0|benjis B EH1 N JH IY0 Z|bih B IH1
mic M AY1 K|mics M AY1 K S|emcee EH2 M S IY1|emcees EH2 M S IY1 Z|cypher S AY1 F ER0|freestyle F R IY1 S T AY2 L
freestyles F R IY1 S T AY2 L Z|mixtape M IH1 K S T EY2 P|mixtapes M IH1 K S T EY2 P S|adlib AE1 D L IH1 B
adlibs AE1 D L IH1 B Z
""".split(whereSeparator: { $0 == "|" || $0 == "\n" }).map { $0.split(separator: " ").map(String.init) }

let contractions: Set<String> = ["it's", "that's", "what's", "he's", "she's", "there's", "here's", "let's", "who's", "where's", "how's"]

func buildEnglish(_ data: URL) -> [RawEntry] {
    struct Source {
        let word: String
        let phones: [String]
        let isName: Bool
    }
    var sources: [Source] = []
    var known = Set<String>()
    for raw in lines(data.appendingPathComponent("cmudict.dict")) {
        let pieces = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = pieces[0].split(separator: " ").map(String.init)
        guard parts.count >= 2 else { continue }
        let word = parts[0].replacingOccurrences(of: "\\(\\d+\\)$", with: "", options: .regularExpression)
        guard word.range(of: "^[a-z][a-z']*$", options: .regularExpression) != nil else { continue }
        sources.append(Source(word: word, phones: Array(parts.dropFirst()), isName: pieces.count > 1))
        known.insert(word)
    }
    let slang = Set(slangSupplement.map { $0[0] })
    for parts in slangSupplement where !known.contains(parts[0]) {
        sources.append(Source(word: parts[0], phones: Array(parts.dropFirst()), isName: false))
    }

    // Commonness, from three signals: Apple's embedding vocabulary (~57k everyday words),
    // Webster's 2nd (lowercase headwords are ordinary words, not names) and subtitle frequency.
    let embedding = NLEmbedding.wordEmbedding(for: .english)
    let webster = Set(lines(URL(fileURLWithPath: "/usr/share/dict/words")).filter { $0.first?.isLowercase == true }.map(String.init))
    var ranks: [String: Int] = [:]
    for (index, line) in lines(data.appendingPathComponent("en_50k.txt")).enumerated() {
        if let word = line.split(separator: " ").first { ranks[String(word)] = index + 1 }
    }

    func ordinary(_ word: String) -> Bool {
        if webster.contains(word) { return true }
        let bare = word.replacingOccurrences(of: "'", with: "")
        // runnin' -> running; only with the apostrophe, or surnames like "borin" slip through.
        if word.hasSuffix("in'"), webster.contains(bare + "g") || webster.contains(String(bare.dropLast(2)) + "e") { return true }
        for suffix in ["s", "es", "ed", "d", "ing", "er", "est", "ly"] where bare.hasSuffix(suffix) && bare.count > suffix.count + 1 {
            let stem = String(bare.dropLast(suffix.count))
            if webster.contains(stem) || webster.contains(stem + "e") { return true }
            if stem.count > 2, stem.last == stem.dropLast().last, webster.contains(String(stem.dropLast())) { return true }
            if ["es", "ed", "er", "est"].contains(suffix), stem.hasSuffix("i"), webster.contains(String(stem.dropLast()) + "y") { return true }
        }
        return false
    }

    func tier(_ word: String, isName: Bool) -> UInt8 {
        if slang.contains(word) { return 0 }
        if word.count == 1 { return word == "a" || word == "i" ? 0 : 2 }
        let inEmbedding = embedding?.contains(word) ?? false, inWebster = ordinary(word)
        // Possessives are noise in a rhyme list unless they are everyday contractions.
        if word.hasSuffix("'s"), !inEmbedding { return contractions.contains(word) ? 0 : 2 }
        var base: UInt8 = isName && !inWebster ? 2 : inEmbedding && inWebster ? 0 : inEmbedding || inWebster ? 1 : 2
        if let rank = ranks[word] { base = min(base, rank <= 25_000 ? 0 : 1) }
        return base
    }

    var tiers: [String: UInt8] = [:]
    var seen = Set<String>()
    var entries: [RawEntry] = []
    for source in sources {
        // An unstressed "ih" is the reduced vowel, which rhymes as a schwa.
        let phones = source.phones.compactMap { Phone(symbol: $0 == "IH0" ? "IX0" : $0) }
        guard phones.count == source.phones.count, seen.insert(source.word + "\t" + source.phones.joined(separator: " ")).inserted else { continue }
        let wordTier = tiers[source.word] ?? tier(source.word, isName: source.isName)
        tiers[source.word] = wordTier
        entries.append(RawEntry(word: source.word, language: .english, pron: phones, tier: wordTier, freq: frequencyByte(rank: ranks[source.word])))
    }
    return entries
}

// MARK: Hindi and Gujarati

struct WikiLemma {
    var roman = ""
    var glosses: [String] = []
    var isName = true
    var redirect: String?
}

struct Wiktionary {
    var lemmas: [String: WikiLemma] = [:]
    /// Inflected form -> (its transliteration, the lemma it belongs to).
    var forms: [String: (roman: String, lemma: String)] = [:]
    var ipa: [String: String] = [:]
}

func loadWiktionary(_ url: URL, isScript: (String) -> Bool) -> Wiktionary {
    var result = Wiktionary()
    let skippedPOS: Set<String> = ["character", "suffix", "prefix", "symbol", "punct", "phrase", "proverb", "infix", "interfix", "circumfix", "affix", "combining_form"]
    let skippedTags: Set<String> = ["romanization", "table-tags", "inflection-template", "class", "Urdu", "error-unrecognized-form"]
    for line in lines(url) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let rawWord = object["word"] as? String, let pos = object["pos"] as? String, !skippedPOS.contains(pos) else { continue }
        let word = nfc(rawWord)
        guard isScript(word) else { continue }
        let forms = object["forms"] as? [[String: Any]] ?? []
        var lemma = result.lemmas[word] ?? WikiLemma()

        if lemma.roman.isEmpty, let roman = forms.first(where: { ($0["tags"] as? [String])?.contains("romanization") == true })?["form"] as? String {
            lemma.roman = roman
        }
        if result.ipa[word] == nil, let sounds = object["sounds"] as? [[String: Any]],
           let ipa = sounds.compactMap({ $0["ipa"] as? String }).first(where: { $0.hasPrefix("/") }) {
            result.ipa[word] = ipa
        }
        if pos != "name" { lemma.isName = false }

        for sense in object["senses"] as? [[String: Any]] ?? [] {
            // "Alternative spelling of X": borrow X's meaning later.
            let target = ((sense["alt_of"] ?? sense["form_of"]) as? [[String: Any]])?.first?["word"] as? String
            if let target {
                if lemma.redirect == nil { lemma.redirect = nfc(target) }
                continue
            }
            guard pos != "name", let raw = (sense["glosses"] as? [String])?.last else { continue }
            // "nuqtaless form of ज़ोर", "synonym of मामा": point at the other word instead.
            if let match = raw.range(of: "^[A-Za-z -]*(form|spelling|misspelling|synonym|abbreviation) of ", options: .regularExpression) {
                let rest = raw[match.upperBound...].split(whereSeparator: { " ,;:(".contains($0) }).first.map(String.init) ?? ""
                if lemma.redirect == nil, isScript(nfc(rest)) { lemma.redirect = nfc(rest) }
                continue
            }
            // Brackets go first, or a comma inside them splits the gloss into fragments.
            let gloss = raw.replacingOccurrences(of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression)
            lemma.glosses += gloss.split(whereSeparator: { $0 == "," || $0 == ";" }).map(String.init)
        }
        result.lemmas[word] = lemma

        for form in forms {
            guard let text = form["form"] as? String, let roman = form["roman"] as? String else { continue }
            let tags = Set(form["tags"] as? [String] ?? [])
            let inflected = nfc(text)
            guard tags.isDisjoint(with: skippedTags), isScript(inflected), inflected != word, result.forms[inflected] == nil else { continue }
            result.forms[inflected] = (roman, word)
        }
    }
    return result
}

func buildIndic(_ language: Language, wiktionary: Wiktionary, ranks: [String: Int], useTransliteration: Bool) -> [RawEntry] {
    func gloss(of word: String, depth: Int = 0) -> String {
        guard let lemma = wiktionary.lemmas[word] else { return "" }
        let own = formatGloss(lemma.glosses)
        if !own.isEmpty || depth > 2 { return own }
        return lemma.redirect.map { gloss(of: $0, depth: depth + 1) } ?? ""
    }
    func sounds(_ word: String, roman: String) -> (pron: Pron, roman: String) {
        if useTransliteration, !roman.isEmpty, let parsed = IAST.phones(roman) {
            let display = IndicG2P.romanize(IndicG2P.finish(parsed, language: language, collapsingDoubles: false))
            return (IndicG2P.finish(parsed, language: language), display)
        }
        let display = IndicG2P.romanize(IndicG2P.pronounce(word, language: language, collapsingDoubles: false))
        return (IndicG2P.pronounce(word, language: language), display)
    }

    var entries: [RawEntry] = []
    for (word, lemma) in wiktionary.lemmas {
        let (pron, roman) = sounds(word, roman: lemma.roman)
        guard !pron.isEmpty else { continue }
        let rank = ranks[word]
        let tier: UInt8 = lemma.isName ? 2 : (rank ?? .max) <= 8000 ? 0 : 1
        entries.append(RawEntry(
            word: word, language: language, pron: pron, tier: tier, freq: frequencyByte(rank: rank),
            roman: roman, altRoman: useTransliteration ? IAST.casual(lemma.roman) : "", gloss: gloss(of: word)
        ))
    }
    for (word, form) in wiktionary.forms where wiktionary.lemmas[word] == nil {
        let (pron, roman) = sounds(word, roman: form.roman)
        guard !pron.isEmpty else { continue }
        let rank = ranks[word]
        // An inflection nobody was seen using is only worth showing for an everyday word.
        let lemmaCommon = (ranks[form.lemma] ?? .max) <= 3000
        let tier: UInt8 = rank != nil ? (rank! <= 8000 ? 0 : 1) : lemmaCommon ? 1 : 2
        entries.append(RawEntry(
            word: word, language: language, pron: pron, tier: tier, freq: frequencyByte(rank: rank),
            roman: roman, altRoman: useTransliteration ? IAST.casual(form.roman) : "", gloss: gloss(of: form.lemma)
        ))
    }
    for (word, rank) in ranks where wiktionary.lemmas[word] == nil && wiktionary.forms[word] == nil {
        let (pron, roman) = sounds(word, roman: "")
        guard !pron.isEmpty else { continue }
        entries.append(RawEntry(word: word, language: language, pron: pron, tier: rank <= 8000 ? 0 : 1, freq: frequencyByte(rank: rank), roman: roman))
    }
    return entries
}

func buildHindi(_ data: URL) -> [RawEntry] {
    var ranks: [String: Int] = [:]
    for line in lines(data.appendingPathComponent("hi_full.txt")) {
        let parts = line.split(separator: " ")
        guard parts.count == 2, let count = Int(parts[1]), count >= 2 else { continue }
        let word = nfc(String(parts[0]))
        if isDevanagari(word), ranks[word] == nil { ranks[word] = ranks.count + 1 }
    }
    let wiktionary = loadWiktionary(data.appendingPathComponent("kaikki-hindi.jsonl"), isScript: isDevanagari)
    return buildIndic(.hindi, wiktionary: wiktionary, ranks: ranks, useTransliteration: true)
}

func buildGujarati(_ data: URL) -> [RawEntry] {
    var counts: [(word: String, count: Int)] = []
    for line in lines(data.appendingPathComponent("gu_words.txt")) {
        let parts = line.split(separator: "\t")
        guard parts.count == 3, let count = Int(parts[2]), count >= 3 else { continue }
        let word = nfc(String(parts[1]))
        if isGujarati(word) { counts.append((word, count)) }
    }
    counts.sort { $0.count > $1.count }
    var ranks: [String: Int] = [:]
    for (word, _) in counts.prefix(60_000) where ranks[word] == nil { ranks[word] = ranks.count + 1 }
    let wiktionary = loadWiktionary(data.appendingPathComponent("kaikki-gujarati.jsonl"), isScript: isGujarati)
    // Wiktionary's Gujarati transliteration keeps every silent "a", so the script reader is the better guide.
    return buildIndic(.gujarati, wiktionary: wiktionary, ranks: ranks, useTransliteration: false)
}

// MARK: Corrections

/// Meanings for the small words the dictionaries get wrong or leave out. Wiktionary files
/// possessives under their pronoun, and the Spanish dictionary only has lemmas, so "es" comes
/// back as a noun instead of "is".
let glossCorrections: [Language: [String: String]] = [
    .hindi: [
        "मेरा": "my; mine", "मेरी": "my; mine", "मेरे": "my; mine", "तेरा": "your; yours", "तेरी": "your; yours", "तेरे": "your; yours",
        "तुम्हारा": "your; yours", "तुम्हारी": "your; yours", "तुम्हारे": "your; yours", "हमारा": "our; ours", "हमारी": "our; ours",
        "हमारे": "our; ours", "अपना": "own", "अपनी": "own", "अपने": "own", "है": "to be", "हैं": "to be", "हूँ": "to be", "हूं": "to be",
        "था": "to be", "थी": "to be", "थे": "to be", "हो": "to be", "मुझे": "me", "तुझे": "you", "नहीं": "not; no",
    ],
    .gujarati: [
        "મારું": "my; mine", "મારી": "my; mine", "મારા": "my; mine", "મારો": "my; mine", "તારું": "your; yours", "તારી": "your; yours",
        "તારા": "your; yours", "તારો": "your; yours", "અમારું": "our; ours", "આપણું": "our; ours", "છે": "to be", "છું": "to be",
        "છો": "to be", "છીએ": "to be", "હતું": "to be", "હતી": "to be", "હતો": "to be", "નથી": "not", "મને": "me", "તને": "you",
    ],
    .spanish: [
        "es": "to be", "son": "to be", "soy": "to be", "eres": "to be", "somos": "to be", "está": "to be", "están": "to be",
        "estoy": "to be", "estás": "to be", "era": "to be", "fue": "to be", "ser": "to be", "estar": "to be",
        "el": "the", "la": "the", "los": "the", "las": "the", "un": "a", "una": "a", "y": "and", "o": "or", "pero": "but",
        "que": "that", "de": "of", "del": "of", "al": "to", "a": "to", "en": "in", "con": "with", "sin": "without", "por": "for",
        "para": "for", "mi": "my", "mis": "my", "tu": "your", "tus": "your", "su": "his; her", "tú": "you", "yo": "I", "me": "me",
        "te": "you", "ti": "you", "se": "self", "lo": "it", "le": "him; her", "nos": "us", "no": "no; not", "sí": "yes", "si": "if",
        "más": "more", "muy": "very", "como": "like; as", "cuando": "when", "donde": "where", "qué": "what", "quién": "who",
        "porque": "because", "todo": "all; everything", "nada": "nothing", "siempre": "always", "nunca": "never", "ahora": "now",
        "aquí": "here", "bien": "well; good", "hay": "there is", "tengo": "have", "tiene": "have", "tienes": "have",
        "quiero": "want", "quiere": "want", "quieres": "want", "voy": "go", "va": "go", "vamos": "go", "puedo": "can",
        "puede": "can", "sé": "know", "sabes": "know", "amo": "love", "amas": "love", "ama": "love", "esto": "this", "esta": "this", "este": "this", "eso": "that", "ya": "already",
    ],
    .french: [
        "à": "to; at", "a": "have", "ai": "have", "as": "have", "es": "to be", "et": "and", "ou": "or", "où": "where",
        "y": "there", "en": "in", "ne": "not", "pas": "not", "que": "that", "qui": "who", "ça": "that", "ce": "this",
    ],
]

func applyCorrections(_ entries: inout [RawEntry], language: Language) {
    guard let table = glossCorrections[language] else { return }
    for index in entries.indices {
        if let gloss = table[entries[index].word] { entries[index].gloss = gloss }
    }
}

// MARK: Spanish and French

/// The subtitle word list is full of English names and loanwords, which the pronunciation
/// rules would cheerfully read as Spanish. A word stays if a dictionary defines it, or if
/// the system's Spanish spell checker accepts it and it is spelled like Spanish.
func looksSpanish(_ word: String) -> Bool {
    for foreign in ["th", "sh", "ck", "ph", "w", "ss", "tt", "ff", "pp", "mm", "gg", "bb", "dd", "zz", "oo"] where word.contains(foreign) {
        return false
    }
    guard let last = word.last else { return false }
    if !"aeiouáéíóúdlnrszyjx".contains(last) || word.hasSuffix("air") { return false }
    return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "es", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
}

func buildSpanish(_ data: URL) -> [RawEntry] {
    let (glosses, proper) = loadTranslations(data.appendingPathComponent("es_en.tsv"))
    var entries: [RawEntry] = []
    var seen = Set<String>()
    var rank = 0
    for line in lines(data.appendingPathComponent("es_50k.txt")) {
        guard let token = line.split(separator: " ").first else { continue }
        let word = nfc(token.lowercased())
        guard isLatinWord(word), seen.insert(word).inserted else { continue }
        rank += 1
        let defined = glosses[word] != nil && !proper.contains(word)
        guard defined || looksSpanish(word) else { continue }
        let pron = SpanishG2P.pronounce(word)
        guard pron.contains(where: \.isVowel) else { continue }
        entries.append(RawEntry(word: word, language: .spanish, pron: pron, tier: rank <= 12_000 ? 0 : 1, freq: frequencyByte(rank: rank), gloss: defined ? glosses[word]! : ""))
    }
    for (word, gloss) in glosses where isLatinWord(word) && seen.insert(word).inserted {
        let pron = SpanishG2P.pronounce(word)
        guard pron.contains(where: \.isVowel) else { continue }
        entries.append(RawEntry(word: word, language: .spanish, pron: pron, tier: proper.contains(word) ? 2 : 1, gloss: gloss))
    }
    return entries
}

/// Lexique's one-character-per-sound alphabet.
let lexiquePhones: [Character: [String]] = [
    "a": ["AA"], "i": ["IY"], "y": ["UE"], "u": ["UW"], "o": ["O"], "O": ["AO"], "e": ["E"], "E": ["EH"],
    "°": ["AH"], "3": ["AH"], "2": ["EU"], "9": ["EU"], "5": ["IN"], "1": ["IN"], "@": ["AN"], "§": ["ON"],
    "j": ["Y"], "8": ["W"], "w": ["W"], "p": ["P"], "b": ["B"], "t": ["TD"], "d": ["DD"], "k": ["K"], "g": ["G"],
    "f": ["F"], "v": ["V"], "s": ["S"], "z": ["Z"], "S": ["SH"], "Z": ["ZH"], "m": ["M"], "n": ["N"], "N": ["NY"],
    "G": ["NG"], "l": ["L"], "R": ["R"], "x": ["HX"],
]

func buildFrench(_ data: URL) -> [RawEntry] {
    let (glosses, proper) = loadTranslations(data.appendingPathComponent("fr_en.tsv"))
    /// Lexique spells cœur "coeur"; the dictionary uses the ligature.
    func gloss(_ word: String) -> String? {
        for spelling in [word, word.replacingOccurrences(of: "oe", with: "œ"), word.replacingOccurrences(of: "ae", with: "æ")] {
            if let found = glosses[spelling], !proper.contains(spelling) { return found }
        }
        return nil
    }
    struct Form {
        var pron: Pron
        var frequency = 0.0
        /// How often the form belongs to each lemma: "suis" is mostly être, sometimes suivre.
        var lemmas: [String: Double] = [:]
        var isLemma = false

        var lemma: String { lemmas.max { $0.value < $1.value }?.key ?? "" }
    }
    var forms: [String: Form] = [:]
    var order: [String] = []
    for line in lines(data.appendingPathComponent("Lexique383.tsv")).dropFirst() {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count > 13 else { continue }
        let word = nfc(columns[0].lowercased())
        guard isLatinWord(word, apostrophes: true) else { continue }
        var symbols: [String] = []
        for character in columns[1] {
            guard let mapped = lexiquePhones[character] else { symbols = []; break }
            symbols += mapped
        }
        guard !symbols.isEmpty else { continue }
        let pron = FrenchG2P.stressed(symbols.map { Phone.vowelSymbols.contains($0) ? Phone.vowel($0) : Phone.consonant($0) })
        let key = word + "\t" + String(columns[1])
        let rowFrequency = (Double(columns[8]) ?? 0) + (Double(columns[9]) ?? 0) * 0.3
        var form = forms[key] ?? Form(pron: pron)
        if forms[key] == nil { order.append(key) }
        form.frequency += rowFrequency
        form.lemmas[nfc(columns[2].lowercased()), default: 0] += rowFrequency
        if columns[13] == "1" { form.isLemma = true }
        forms[key] = form
    }
    let ranked = order.filter { forms[$0]!.frequency > 0 }.sorted { forms[$0]!.frequency > forms[$1]!.frequency }
    var ranks: [String: Int] = [:]
    for (index, key) in ranked.enumerated() { ranks[key] = index + 1 }

    return order.compactMap { key in
        let form = forms[key]!
        let word = String(key.split(separator: "\t")[0])
        guard form.pron.contains(where: \.isVowel) else { return nil }
        let rank = ranks[key]
        let tier: UInt8 = (rank ?? .max) <= 15_000 ? 0 : rank != nil || form.isLemma ? 1 : 2
        // An inflection means what its lemma means: "est" the verb is "be", not "east".
        let meaning = form.lemma != word ? gloss(form.lemma) ?? gloss(word) : gloss(word)
        return RawEntry(word: word, language: .french, pron: form.pron, tier: tier, freq: frequencyByte(rank: rank), gloss: meaning ?? "")
    }
}

// MARK: Signs

/// SignPuddle's ASL dictionary as "gloss<TAB>sign<TAB>sign...", signs in Formal SignWriting.
/// Manual-alphabet letters are keyed "#a"..."#z".
func buildSigns(_ data: URL) -> String {
    guard let text = try? String(contentsOf: data.appendingPathComponent("sgn4.spml"), encoding: .utf8) else { return "" }
    let entryPattern = try! NSRegularExpression(pattern: "<entry[^>]*>(.*?)</entry>", options: .dotMatchesLineSeparators)
    let termPattern = try! NSRegularExpression(pattern: "<term>(.*?)</term>", options: .dotMatchesLineSeparators)
    let signPattern = try! NSRegularExpression(pattern: "^(?:A(?:S[123][0-9a-f]{2}[0-5][0-9a-f])+)?([BLMR]\\d{3}x\\d{3}(?:S[123][0-9a-f]{2}[0-5][0-9a-f]\\d{3}x\\d{3})+)$")
    let source = text as NSString
    var table: [String: [String]] = [:]
    var order: [String] = []

    for entry in entryPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        let body = source.substring(with: entry.range(at: 1))
        var sign: String?
        var glosses: [String] = []
        for term in termPattern.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
            var value = (body as NSString).substring(with: term.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("<![CDATA["), value.hasSuffix("]]>") { value = String(value.dropFirst(9).dropLast(3)) }
            if let match = signPattern.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) {
                if sign == nil { sign = (value as NSString).substring(with: match.range(at: 1)) }
            } else {
                glosses.append(value)
            }
        }
        guard let sign else { continue }
        for gloss in glosses {
            for piece in gloss.lowercased().split(separator: ",") {
                var key = piece.replacingOccurrences(of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                if key.hasPrefix("letter "), key.count == 8 { key = "#" + key.suffix(1) }
                let plain = key.hasPrefix("#") ? String(key.dropFirst()) : key
                guard !plain.isEmpty, plain.split(separator: " ").count <= 3,
                      plain.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || " '-".unicodeScalars.contains($0) }) else { continue }
                if table[key] == nil { order.append(key) }
                if table[key, default: []].count < 3, !table[key, default: []].contains(sign) { table[key, default: []].append(sign) }
            }
        }
    }
    return order.sorted().map { ([$0] + table[$0]!).joined(separator: "\t") }.joined(separator: "\n") + "\n"
}

// MARK: Writing

func write(_ unsorted: [RawEntry], to url: URL) throws {
    // Within a language, words are sorted by their UTF-8 bytes so the app can binary-search them.
    let entries = unsorted.sorted { a, b in
        a.language.rawValue != b.language.rawValue ? a.language.rawValue < b.language.rawValue : Array(a.word.utf8).lexicographicallyPrecedes(Array(b.word.utf8))
    }

    var postings: [(key: UInt64, entry: Int32)] = []
    postings.reserveCapacity(entries.count * 9)
    var phones: [UInt8] = [], pronOffsets: [UInt32] = [0]
    var text: [UInt8] = [], textOffsets: [UInt32] = [0]
    var ranges = [Int](repeating: 0, count: Language.allCases.count * 2)

    for (index, entry) in entries.enumerated() {
        let id = Int32(index)
        let slot = Int(entry.language.rawValue) * 2
        if index == 0 || entries[index - 1].language != entry.language { ranges[slot] = index }
        ranges[slot + 1] = index + 1

        phones += entry.pron.map(\.code)
        pronOffsets.append(UInt32(phones.count))
        text += Array("\(entry.word)\t\(entry.roman)\t\(entry.gloss)".utf8)
        textOffsets.append(UInt32(text.count))

        func add(_ kind: IndexKind, _ sound: Pron) { postings.append((LexiconKey.sound(kind, sound), id)) }
        let pron = entry.pron
        let vowels = pron.vowelKeys
        if !vowels.isEmpty {
            add(.rhymeTail, pron.rhymeTail)
            add(.tailVowels, pron.rhymeTail.filter(\.isVowel).map(\.vowelKey))
            add(.wholePron, pron.normalized)
            for size in 2...4 where vowels.count >= size {
                add(IndexKind.vowelSuffix(size)!, Array(vowels.suffix(size)))
            }
            // The wordplay indexes only ever surface everyday words.
            if entry.tier < 2 {
                if vowels.count <= 4 { add(.wholeVowels, vowels) }
                if pron.consonants.count >= 2 { add(.consonants, pron.consonants) }
                if let firstVowel = pron.firstIndex(where: \.isVowel), firstVowel > 0 {
                    add(.head, pron[...firstVowel].map(\.normalized))
                }
            }
        }
        if entry.language.isIndic {
            var tight = Set([IndicG2P.tightKey(entry.roman)]), loose = Set([IndicG2P.looseKey(entry.roman)])
            if !entry.altRoman.isEmpty {
                tight.insert(IndicG2P.tightKey(entry.altRoman))
                loose.insert(IndicG2P.looseKey(entry.altRoman))
            }
            for key in tight where !key.isEmpty { postings.append((LexiconKey.text(.romanTight, key, language: entry.language), id)) }
            for key in loose where !key.isEmpty { postings.append((LexiconKey.text(.romanLoose, key, language: entry.language), id)) }
        }
        if entry.language != .english, entry.tier < 2 {
            for term in Set(LexiconKey.glossTerms(entry.gloss)) { postings.append((LexiconKey.text(.glossTerm, term), id)) }
        }
    }

    postings.sort { $0.key != $1.key ? $0.key < $1.key : $0.entry < $1.entry }
    var keys: [UInt64] = [], starts: [UInt32] = []
    for (index, posting) in postings.enumerated() where index == 0 || postings[index - 1].key != posting.key {
        keys.append(posting.key)
        starts.append(UInt32(index))
    }
    starts.append(UInt32(postings.count))

    var file = Data(count: LexiconFormat.headerBytes)
    var header = [UInt64](repeating: 0, count: LexiconFormat.headerBytes / 8)
    header[LexiconFormat.Field.magic.rawValue] = LexiconFormat.magic
    header[LexiconFormat.Field.entryCount.rawValue] = UInt64(entries.count)
    header[LexiconFormat.Field.keyCount.rawValue] = UInt64(keys.count)
    header[LexiconFormat.Field.postingCount.rawValue] = UInt64(postings.count)
    for (offset, value) in ranges.enumerated() { header[LexiconFormat.Field.ranges.rawValue + offset] = UInt64(value) }

    func append<T>(_ field: LexiconFormat.Field, _ values: [T]) {
        while file.count % 8 != 0 { file.append(0) }
        header[field.rawValue] = UInt64(file.count)
        values.withUnsafeBufferPointer { file.append(Data(buffer: $0)) }
    }
    append(.languages, entries.map(\.language.rawValue))
    append(.tiers, entries.map(\.tier))
    append(.freqs, entries.map(\.freq))
    append(.pronOffsets, pronOffsets)
    append(.phones, phones)
    append(.textOffsets, textOffsets)
    append(.text, text)
    append(.keys, keys)
    append(.starts, starts)
    append(.postings, postings.map(\.entry))
    header.withUnsafeBufferPointer { file.replaceSubrange(0..<LexiconFormat.headerBytes, with: Data(buffer: $0)) }
    try file.write(to: url)

    print("lexicon.bin: \(entries.count) entries, \(keys.count) keys, \(postings.count) postings, \(file.count / 1_048_576) MB")
    for language in Language.allCases {
        let slice = entries.filter { $0.language == language }
        let tiers = (0...2).map { tier in slice.filter { $0.tier == tier }.count }
        print("  \(language.name): \(slice.count) (tiers \(tiers)), with meanings \(slice.filter { !$0.gloss.isEmpty }.count)")
    }
}

// MARK: Evaluation

func evaluate(_ data: URL) {
    let hindi = loadWiktionary(data.appendingPathComponent("kaikki-hindi.jsonl"), isScript: isDevanagari)
    var total = 0, same = 0
    var misses: [String] = []
    for (word, lemma) in hindi.lemmas.sorted(by: { $0.key < $1.key }) {
        guard !lemma.roman.isEmpty, let parsed = IAST.phones(lemma.roman) else { continue }
        let expected = IndicG2P.finish(parsed, language: .hindi), got = IndicG2P.pronounce(word, language: .hindi)
        total += 1
        if expected == got { same += 1 } else if misses.count < 4000 { misses.append("\(word) \(lemma.roman): want \(IndicG2P.romanize(expected)) got \(IndicG2P.romanize(got))") }
    }
    print("Hindi: script reader agrees with Wiktionary on \(same)/\(total) (\(same * 100 / max(1, total))%)")
    for miss in stride(from: 0, to: misses.count, by: max(1, misses.count / 40)).map({ misses[$0] }) { print("   ", miss) }

    let gujarati = loadWiktionary(data.appendingPathComponent("kaikki-gujarati.jsonl"), isScript: isGujarati)
    total = 0; same = 0; misses = []
    for (word, ipa) in gujarati.ipa.sorted(by: { $0.key < $1.key }) {
        guard let expected = Skeleton.of(ipa: ipa) else { continue }
        let got = Skeleton.of(IndicG2P.pronounce(word, language: .gujarati, collapsingDoubles: false))
        total += 1
        if expected == got { same += 1 } else { misses.append("\(word) \(ipa): want \(expected) got \(got)") }
    }
    print("Gujarati: script reader agrees with Wiktionary IPA on \(same)/\(total) (\(same * 100 / max(1, total))%)")
    for miss in stride(from: 0, to: misses.count, by: max(1, misses.count / 40)).map({ misses[$0] }) { print("   ", miss) }
}

// MARK: Main

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: lexgen build <data dir> <output dir> | lexgen eval <data dir>")
    exit(1)
}
let dataDirectory = URL(fileURLWithPath: arguments[2])
if arguments[1] == "eval" {
    evaluate(dataDirectory)
} else {
    let output = URL(fileURLWithPath: arguments[3])
    var entries: [RawEntry] = []
    for (language, build) in [(.english, buildEnglish), (.hindi, buildHindi), (.gujarati, buildGujarati), (.spanish, buildSpanish), (.french, buildFrench)] as [(Language, (URL) -> [RawEntry])] {
        let start = Date()
        let name = language.name
        var built = build(dataDirectory)
        applyCorrections(&built, language: language)
        entries += built
        print("\(name): \(built.count) entries in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    }
    try write(entries, to: output.appendingPathComponent("lexicon.bin"))
    let signs = buildSigns(dataDirectory)
    try signs.write(to: output.appendingPathComponent("signs.tsv"), atomically: true, encoding: .utf8)
    print("signs.tsv: \(signs.split(separator: "\n").count) glosses")
}
