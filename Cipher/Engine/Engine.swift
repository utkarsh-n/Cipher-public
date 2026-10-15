import Foundation

/// Everything the Lab shows for one word or phrase.
struct Lookup: Sendable {
    let text: String
    /// The language it was read in.
    let language: Language
    /// Every language the same letters could be read in, likeliest first.
    var readings: [Language] = []
    /// The word in its own script, its romanization and its meaning, when the lexicon has it.
    var native = ""
    var roman = ""
    var gloss = ""
    let phonemes: String
    let syllables: Int
    /// False when the pronunciation was guessed from spelling.
    let known: Bool
    var perfect: [RhymeHit] = []
    var slant: [RhymeHit] = []
    var multis: [MultiGroup] = []
    var mosaics: [Mosaic] = []
    var homophones: [RhymeHit] = []
    var soundAlikes: [String] = []
    var consonance: [RhymeHit] = []
    var frontRhymes: [RhymeHit] = []
    /// The same meaning in the other languages.
    var translations: [RhymeHit] = []
    /// Words near it in meaning, in every language.
    var related: [RhymeHit] = []
    /// The Latin, Greek or Sanskrit it grew from, and its siblings through them.
    var roots = RootReading()
    var signs: [SignToken] = []
    /// The English senses it stands for: itself for English, its dictionary meanings otherwise.
    var ideas: [String] = []
}

struct BridgeHit: Identifiable, Sendable {
    enum Kind: String, Sendable { case perfect = "Perfect", slant = "Slant", multi = "Multi" }

    let hit: RhymeHit
    let kind: Kind
    /// 0...1; how close the word sits to the theme.
    let closeness: Double

    var id: String { hit.id }
}

struct Bridge: Sendable {
    var themedRhymes: [BridgeHit] = []
    var commonGround: [RhymeHit] = []
    var rhymeFound = true
    var themeFound = true
}

/// What the editor's suggestion tray can show for the target word.
enum TrayMode: String, CaseIterable, Identifiable, Sendable {
    case rhyme = "Rhyme", slant = "Slant", multi = "Multi", alike = "Alike", related = "Related", analogy = "Analogy", chain = "Chain"

    var id: String { rawValue }
}

/// Owns the lexicon, the embedding and the sign dictionary, and runs every query off the main thread.
actor Engine {
    var rhymes: RhymeEngine?
    private var analyzer: VerseAnalyzer?
    private var signs: SignDictionary?
    let semantics = Semantics()
    /// Two-word phrases every word lives in, for the hinge move.
    var hinges: HingeIndex?
    /// The Latin, Greek and Sanskrit roots behind words, for the roots move.
    var rootIndex: RootIndex?

    func load(lexicon url: URL, signs signsURL: URL?, hinges hingesURL: URL? = nil) throws {
        if let hingesURL { hinges = try? HingeIndex(contentsOf: hingesURL) }
        guard rhymes == nil else { return }
        let lexicon = try Lexicon(contentsOf: url)
        let engine = RhymeEngine(lexicon: lexicon)
        rhymes = engine
        analyzer = VerseAnalyzer(lexicon: lexicon, detector: engine.detector)
        signs = signsURL.flatMap { try? SignDictionary(contentsOf: $0) }
    }

    /// The roots index, read after the app is up: it is not needed to start writing.
    func loadRoots(_ url: URL?) {
        guard let url, rootIndex == nil else { return }
        rootIndex = try? RootIndex(contentsOf: url)
    }

    // MARK: Lab

    func lookup(_ text: String, as forced: Language?, scope: Scope) -> Lookup? {
        guard let rhymes else { return nil }
        let readings = rhymes.detector.languages(for: text, active: scope.languages)
        guard let query = rhymes.query(text, as: forced ?? readings.first, active: scope.languages) else { return nil }
        var lookup = Lookup(
            text: query.words.joined(separator: " "), language: query.language,
            phonemes: query.primary.display, syllables: query.primary.syllableCount, known: query.known
        )
        lookup.readings = readings
        if !query.isPhrase, let entry = query.entries.first {
            lookup.native = rhymes.lexicon.word(entry)
            lookup.roman = rhymes.lexicon.roman(entry)
            lookup.gloss = rhymes.lexicon.gloss(entry)
        } else if !query.isPhrase, query.language.isIndic {
            lookup.roman = IndicG2P.romanize(query.primary)
        }
        lookup.perfect = rhymes.perfect(query, scope: scope)
        lookup.slant = rhymes.slant(query, scope: scope)
        // A short word's multis are its slant rhymes again; only keep what is new.
        let alreadyShown = Set(lookup.slant.map(\.id))
        lookup.multis = rhymes.multis(query, scope: scope).compactMap { group in
            let fresh = group.hits.filter { !alreadyShown.contains($0.id) }
            return fresh.isEmpty ? nil : MultiGroup(syllables: group.syllables, hits: fresh)
        }
        lookup.mosaics = rhymes.mosaics(query, scope: scope)
        lookup.homophones = rhymes.homophones(query, scope: scope)
        lookup.soundAlikes = rhymes.soundAlikes(query, scope: scope)
        lookup.consonance = rhymes.consonance(query, scope: scope)
        lookup.frontRhymes = scope.looseness == .strict ? [] : rhymes.frontRhymes(query, scope: scope)

        let ideas = concepts(for: query)
        lookup.ideas = ideas
        lookup.translations = translations(of: ideas, from: query.language, scope: scope)
        lookup.related = associations(for: ideas, scope: scope, excluding: Set(lookup.translations.map(\.id)))
        lookup.signs = signTokens(query.words, query.languages)
        lookup.roots = roots(of: text, scope: scope, forced: forced)
        return lookup
    }

    /// A word the dictionary can finish a typed prefix into, with its Roman spelling when it
    /// is written in Devanagari or Gujarati.
    struct Completion: Hashable, Sendable {
        let word: String
        let roman: String
    }

    /// Words the lexicon has that begin the way the last word typed does, commonest first:
    /// "pag" offers pagan, page, pagoda. Own-script Hindi and Gujarati complete too; the
    /// Roman spellings of either do not, since they are indexed by sound, not by letter.
    func completions(of text: String, languages: [Language], limit: Int = 8) -> [Completion] {
        guard let rhymes else { return [] }
        let lexicon = rhymes.lexicon
        guard let last = text.split(separator: " ").last.map({ Tokenizer.clean(String($0)) }), last.count >= 2 else { return [] }
        // A short prefix opens on thousands of words in dictionary order; the window has to
        // reach past the rare early ones to find the common ones.
        let window = last.count <= 2 ? 4000 : last.count == 3 ? 1500 : 600
        var found: [(word: String, roman: String, freq: Int)] = []
        for language in languages {
            for entry in lexicon.entries(withPrefix: last, in: language, limit: window) where lexicon.tier(entry) == 0 {
                let word = lexicon.word(entry)
                guard word != last else { continue }
                let roman = language.isIndic ? lexicon.roman(entry) : ""
                found.append((word, roman == word ? "" : roman, Int(lexicon.freq(entry))))
            }
        }
        var seen = Set<String>()
        return found.sorted { $0.freq > $1.freq }
            .compactMap { seen.insert($0.word).inserted ? Completion(word: $0.word, roman: $0.roman) : nil }
            .prefix(limit).map { $0 }
    }

    // MARK: Editor

    func tray(_ text: String, context: String, mode: TrayMode, scope: Scope) -> [RhymeHit] {
        guard let rhymes, let query = rhymes.query(text, context: context, active: scope.languages) else { return [] }
        var wide = scope
        wide.looseness = max(scope.looseness, .balanced)
        switch mode {
        case .rhyme:
            return rhymes.perfect(query, scope: scope, limit: 40)
        case .slant:
            return rhymes.slant(query, scope: wide, limit: 40)
        case .multi:
            return Array(rhymes.multis(query, scope: scope, includePerfect: true, limitPerGroup: 25).flatMap(\.hits).prefix(80))
        case .alike:
            let phrases = rhymes.soundAlikes(query, scope: scope, limit: 20).map {
                RhymeHit(word: $0, language: query.language, score: 1, syllables: query.primary.syllableCount, tier: 0)
            }
            return rhymes.homophones(query, scope: wide) + phrases
        case .related:
            let ideas = concepts(for: query)
            let literal = translations(of: ideas, from: query.language, scope: scope)
            return Array((literal + associations(for: ideas, scope: scope, excluding: Set(literal.map(\.id)))).prefix(80))
        case .analogy, .chain:
            return []  // answered from the whole line: `analogies(in:scope:)` and `orbit(for:trail:scope:)`
        }
    }

    /// Pairs that hold the relation the writer set up on the line, strictest first. Words in
    /// the other languages are read through their English meanings.
    func analogies(in line: String, scope: Scope) -> (query: AnalogyQuery, pairs: [Analogy])? {
        guard let query = AnalogyQuery.parse(line) else { return nil }
        let english = AnalogyQuery(a: idea(for: query.a, languages: scope.languages), b: idea(for: query.b, languages: scope.languages),
                                   c: query.c.map { idea(for: $0, languages: scope.languages) })
        return (query, semantics.analogies(english, looseness: scope.looseness))
    }

    /// The English idea behind one word: itself when the embedding knows it, else its first
    /// dictionary meaning in whichever of the writer's languages it belongs to.
    func idea(for word: String, languages: [Language]) -> String {
        let clean = Tokenizer.words(in: word).joined(separator: " ")
        if semantics.knows(clean) || clean.contains(" ") { return clean }
        guard let rhymes else { return clean }
        for language in rhymes.detector.languages(for: clean, active: languages) where language != .english {
            if let entry = rhymes.lexicon.pronounce(clean, as: language).entry,
               let term = LexiconKey.glossTerms(rhymes.lexicon.gloss(entry)).first(where: { semantics.knows($0) }) {
                return term
            }
        }
        return clean
    }

    /// The English ideas behind a line's content words, for looking the line up in the
    /// culture index: last word first, grammar words left out.
    func ideas(in line: String, languages: [Language]) -> [String] {
        guard let rhymes else { return [] }
        let phrases = Tokenizer.phrases(in: line)
        let detected = rhymes.detector.detect(phrases.words, breaks: phrases.breaks, active: languages)
        var ideas: [String] = []
        for (word, language) in zip(phrases.words, detected).reversed() {
            guard VerseAnalyzer.fillers[language]?.contains(word) != true, !VerseAnalyzer.functionWords.contains(word) else { continue }
            let idea: String?
            if language == .english {
                idea = word
            } else {
                idea = rhymes.lexicon.pronounce(word, as: language).entry.flatMap { LexiconKey.glossTerms(rhymes.lexicon.gloss($0)).first }
            }
            if let idea, !VerseAnalyzer.functionWords.contains(idea), !ideas.contains(idea) { ideas.append(idea) }
            if ideas.count == 4 { break }
        }
        return ideas
    }

    func analyze(_ text: String, languages: [Language]) -> VerseAnalysis {
        analyzer?.analyze(text, active: languages) ?? VerseAnalysis()
    }

    /// A short list of strong rhymes for a line ending, handed to Claude as raw material.
    func palette(for text: String, context: String, scope: Scope) -> [String] {
        guard let rhymes, let query = rhymes.query(text, context: context, active: scope.languages) else { return [] }
        var wide = scope
        wide.looseness = .balanced
        let picks = rhymes.perfect(query, scope: scope, limit: 8) + rhymes.slant(query, scope: wide, limit: 6)
            + rhymes.multis(query, scope: scope, limitPerGroup: 5).flatMap(\.hits)
        return picks.prefix(48).map { $0.roman.isEmpty ? $0.word : "\($0.word) (\($0.roman))" }
    }

    // MARK: Bridge

    /// Rhymes for one idea that also belong to another, in every language in play: the words
    /// that let a line land on sound and on meaning at once.
    func bridge(rhyme: String, theme: String, scope: Scope) -> Bridge {
        var bridge = Bridge()
        guard let rhymes else { return bridge }
        let rhymeQuery = rhymes.query(rhyme, active: scope.languages)
        let themeIdeas = rhymes.query(theme, active: scope.languages).map(concepts) ?? [theme.lowercased()]
        let rhymeIdeas = rhymeQuery.map(concepts) ?? []

        if let a = rhymeIdeas.first(where: { semantics.vector(for: $0) != nil }),
           let b = themeIdeas.first(where: { semantics.vector(for: $0) != nil }) {
            let ground = semantics.commonGround(a, b).filter { !VerseAnalyzer.functionWords.contains($0.word) }
            bridge.commonGround = spread(ground, scope: scope, englishLimit: 30, othersPerWord: 1, othersLimit: 10)
        }
        guard let rhymeQuery else {
            bridge.rhymeFound = false
            return bridge
        }
        guard let themeVector = themeIdeas.lazy.compactMap({ self.semantics.vector(for: $0) }).first else {
            bridge.themeFound = false
            return bridge
        }
        let cutoff: Double = switch scope.looseness {
        case .strict: 1.02
        case .balanced: 1.14
        case .loose: 1.26
        }
        var wide = scope
        wide.looseness = max(scope.looseness, .balanced)
        var candidates: [(RhymeHit, BridgeHit.Kind)] = rhymes.perfect(rhymeQuery, scope: scope, limit: 1500).map { ($0, .perfect) }
        candidates += rhymes.slant(rhymeQuery, scope: wide, limit: 1500).map { ($0, .slant) }
        candidates += rhymes.multis(rhymeQuery, scope: scope, limitPerGroup: 400).flatMap(\.hits).map { ($0, .multi) }

        var seen = Set<String>()
        for (hit, kind) in candidates where seen.insert(hit.id).inserted {
            // A word placed by its dictionary meaning is a rougher fit than one the model knows
            // directly, so it has to clear a slightly higher bar.
            let bar = hit.language == .english ? cutoff : cutoff - 0.08
            guard let distance = distance(from: themeVector, to: hit), distance <= bar else { continue }
            bridge.themedRhymes.append(BridgeHit(hit: hit, kind: kind, closeness: closeness(distance)))
        }
        bridge.themedRhymes.sort { $0.closeness > $1.closeness }
        // Keep the languages balanced: the best few of each rather than eighty of one.
        var taken: [Language: Int] = [:]
        bridge.themedRhymes = bridge.themedRhymes.filter { hit in
            taken[hit.hit.language, default: 0] += 1
            return taken[hit.hit.language]! <= 30
        }
        return bridge
    }

    /// How far a word sits from a point in meaning-space; other languages are placed by their
    /// English meanings.
    private func distance(from vector: [Double], to hit: RhymeHit) -> Double? {
        if hit.language == .english {
            return VerseAnalyzer.functionWords.contains(hit.word) ? nil : semantics.distance(from: vector, to: hit.word)
        }
        let terms = LexiconKey.glossTerms(hit.gloss).prefix(2).filter { !VerseAnalyzer.functionWords.contains($0) }
        return terms.compactMap { semantics.vector(for: $0) }.map { semantics.distance(vector, $0) }.min()
    }

    // MARK: Meaning

    /// The English ideas a query stands for: the words themselves for English, the dictionary
    /// meanings for everything else.
    func concepts(for query: SoundQuery) -> [String] {
        guard let lexicon = rhymes?.lexicon else { return [] }
        if query.language == .english {
            let phrase = query.words.joined(separator: " ")
            var ideas = [phrase]
            if let last = query.words.last {
                let lemma = semantics.lemma(of: last)
                if !ideas.contains(lemma) { ideas.append(lemma) }
            }
            return ideas
        }
        var ideas: [String] = []
        for entry in query.entries.reversed() {
            for term in LexiconKey.glossTerms(lexicon.gloss(entry)).prefix(3) where !ideas.contains(term) {
                ideas.append(term)
            }
        }
        return ideas
    }

    /// Words in the other languages that mean the same thing.
    func translations(of ideas: [String], from source: Language, scope: Scope) -> [RhymeHit] {
        guard let rhymes else { return [] }
        var result: [RhymeHit] = []
        var seen = Set<String>()
        if source != .english, scope.languages.contains(.english) {
            for idea in ideas.prefix(3) where seen.insert("en:\(idea)").inserted {
                result.append(RhymeHit(word: idea, language: .english, score: 1, syllables: syllables(of: idea), tier: 0))
            }
        }
        for idea in ideas {
            for hit in entries(meaning: idea, scope: scope, perLanguage: 4) where hit.language != source && seen.insert(hit.id).inserted {
                result.append(hit)
            }
        }
        return result
    }

    /// Words near the ideas in meaning, across the languages in play.
    func associations(for ideas: [String], scope: Scope, excluding: Set<String>) -> [RhymeHit] {
        guard let seed = ideas.first(where: { semantics.vector(for: $0) != nil }) else { return [] }
        let excluded = excluding.union(ideas.map { "en:\($0)" })
        return spread(semantics.related(to: seed, looseness: scope.looseness), scope: scope, englishLimit: 60, othersPerWord: 2, othersLimit: 30)
            .filter { !excluded.contains($0.id) }
    }

    /// Turns English words with distances into hits in every language: the words themselves,
    /// plus the commonest words of each other language that carry the same meaning.
    private func spread(_ scored: [(word: String, distance: Double)], scope: Scope, englishLimit: Int, othersPerWord: Int, othersLimit: Int) -> [RhymeHit] {
        var result: [RhymeHit] = []
        var seen = Set<String>()
        var taken: [Language: Int] = [:]
        for (word, distance) in scored {
            let score = closeness(distance)
            if scope.languages.contains(.english), taken[.english, default: 0] < englishLimit, seen.insert("en:\(word)").inserted {
                taken[.english, default: 0] += 1
                result.append(RhymeHit(word: word, language: .english, score: score, syllables: syllables(of: word), tier: 0))
            }
            for hit in entries(meaning: word, scope: scope, perLanguage: othersPerWord, score: score * 0.95)
            where taken[hit.language, default: 0] < othersLimit && seen.insert(hit.id).inserted {
                taken[hit.language, default: 0] += 1
                result.append(hit)
            }
        }
        return result
    }

    /// The commonest non-English words whose dictionary meaning includes an English term. A
    /// word whose first meaning is the term ranks ahead of one that only lists it later.
    func entries(meaning term: String, scope: Scope, perLanguage: Int, score: Double = 1) -> [RhymeHit] {
        guard let rhymes else { return [] }
        let lexicon = rhymes.lexicon
        var ranked: [(entry: Int32, rank: Int)] = []
        for entry in lexicon.entries(meaning: term) where scope.languages.contains(lexicon.language(entry)) {
            let terms = LexiconKey.glossTerms(lexicon.gloss(entry))
            guard let position = terms.firstIndex(of: term) else { continue }
            ranked.append((entry, Int(lexicon.freq(entry)) - position * 60))
        }
        ranked.sort { $0.rank != $1.rank ? $0.rank > $1.rank : $0.entry < $1.entry }
        var taken: [Language: Int] = [:]
        var seen = Set<String>()
        var result: [RhymeHit] = []
        for (entry, _) in ranked {
            let language = lexicon.language(entry)
            guard taken[language, default: 0] < perLanguage else { continue }
            let hit = rhymes.hit(entry, score: score)
            // Inflections share their lemma's meaning (aimer, aimes, aimait); one of each is enough.
            guard seen.insert(hit.id).inserted, seen.insert("\(language.code)=\(hit.gloss)").inserted else { continue }
            taken[language, default: 0] += 1
            result.append(hit)
        }
        return result
    }

    private func syllables(of english: String) -> Int {
        guard let rhymes else { return 0 }
        return Tokenizer.words(in: english).reduce(0) { $0 + (rhymes.lexicon.pronounce($1, as: .english).prons.first?.syllableCount ?? 0) }
    }

    private func closeness(_ distance: Double) -> Double {
        max(0, min(1, 1 - (distance - 0.6) / 0.8))
    }

    // MARK: Signs

    /// The bar as ASL signs, one token per word that is signed. Words are chosen by meaning,
    /// so a Hindi or French word gets the sign for what it means; a word with no sign in the
    /// dictionary is fingerspelled.
    func signs(for line: String, languages: [Language]) -> [SignToken] {
        guard let rhymes else { return [] }
        let phrases = Tokenizer.phrases(in: line)
        return signTokens(phrases.words, rhymes.detector.detect(phrases.words, breaks: phrases.breaks, active: languages))
    }

    private func signTokens(_ words: [String], _ languages: [Language]) -> [SignToken] {
        guard let rhymes, let signs else { return [] }
        var tokens: [SignToken] = []
        var index = 0
        outer: while index < words.count {
            let word = words[index], language = languages[index]
            defer { index += 1 }
            if language == .english {
                // "thank you", "don't know": some signs cover several English words.
                for span in [3, 2] where index + span <= words.count && languages[index..<(index + span)].allSatisfy({ $0 == .english }) {
                    let phrase = words[index..<(index + span)].joined(separator: " ")
                    if let sign = signs.sign(for: phrase) {
                        tokens.append(SignToken(id: tokens.count, word: phrase, signs: [sign], fingerspelled: false, sense: ""))
                        index += span - 1
                        continue outer
                    }
                }
                if SignDictionary.unsigned.contains(word) { continue }
                if let (sign, sense) = englishSign(word) {
                    tokens.append(SignToken(id: tokens.count, word: word, signs: [sign], fingerspelled: false, sense: sense == word ? "" : sense))
                    continue
                }
                let letters = signs.fingerspell(word)
                if !letters.isEmpty { tokens.append(SignToken(id: tokens.count, word: word, signs: letters, fingerspelled: true, sense: "")) }
                continue
            }
            let said = rhymes.lexicon.pronounce(word, as: language)
            let terms = said.entry.map { LexiconKey.glossTerms(rhymes.lexicon.gloss($0)) } ?? []
            if let first = terms.first, SignDictionary.unsigned.contains(first) { continue }
            if let (sign, sense) = terms.lazy.compactMap({ self.englishSign($0) }).first {
                tokens.append(SignToken(id: tokens.count, word: word, signs: [sign], fingerspelled: false, sense: sense))
                continue
            }
            // No sign for the meaning: spell the word as it would be written in Roman letters.
            var spelling = word
            if language.isIndic {
                spelling = said.entry.map { rhymes.lexicon.roman($0) } ?? said.prons.first.map(IndicG2P.romanize) ?? word
            }
            let letters = signs.fingerspell(spelling)
            if !letters.isEmpty { tokens.append(SignToken(id: tokens.count, word: word, signs: letters, fingerspelled: true, sense: "")) }
        }
        return tokens
    }

    /// A sign for an English word or short phrase: as given, with a contraction undone, or by
    /// its dictionary form.
    private func englishSign(_ word: String) -> (sign: String, sense: String)? {
        guard let signs else { return nil }
        if let sign = signs.sign(for: word) { return (sign, word) }
        if let apostrophe = word.firstIndex(of: "'") {
            let stem = String(word[..<apostrophe])
            if word.hasSuffix("n't"), let sign = signs.sign(for: "not") { return (sign, "not") }
            if let sign = signs.sign(for: stem) { return (sign, stem) }
        }
        let lemma = semantics.lemma(of: word)
        if lemma != word, let sign = signs.sign(for: lemma) { return (sign, lemma) }
        return nil
    }
}
