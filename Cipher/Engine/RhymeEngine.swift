import Foundation

/// How far a match may drift from the query, for sound and for meaning alike.
enum Looseness: Int, CaseIterable, Identifiable, Sendable, Comparable {
    case strict, balanced, loose

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .strict: "Strict"
        case .balanced: "Balanced"
        case .loose: "Loose"
        }
    }

    /// Minimum tail similarity for a slant rhyme.
    var slantFloor: Double {
        switch self {
        case .strict: 0.8
        case .balanced: 0.66
        case .loose: 0.52
        }
    }

    static func < (a: Looseness, b: Looseness) -> Bool { a.rawValue < b.rawValue }
}

/// Which words a search may return.
struct Scope: Sendable, Equatable {
    /// The languages in play, in the writer's order of preference.
    var languages: [Language] = Language.allCases
    var looseness = Looseness.balanced
    /// Names, rare words and unattested inflections.
    var includeRare = false
}

struct RhymeHit: Identifiable, Hashable, Sendable {
    /// The word in its own script.
    let word: String
    let language: Language
    /// 0...1; how close the match is (sound for rhymes, meaning for associations).
    let score: Double
    let syllables: Int
    let tier: UInt8
    /// Roman-letter form of a Hindi or Gujarati word.
    var roman = ""
    /// Short English meaning, when the dictionaries have one.
    var gloss = ""

    var id: String { "\(language.code):\(word)" }
}

/// Words whose last `syllables` vowel sounds line up with the query's.
struct MultiGroup: Identifiable, Sendable {
    let syllables: Int
    let hits: [RhymeHit]

    var id: Int { syllables }
}

/// A multisyllabic rhyme assembled from several words: pick one word per slot.
struct Mosaic: Identifiable, Sendable {
    let slots: [[RhymeHit]]

    var id: String { slots.map { "\($0.count)-\($0.first?.id ?? "")" }.joined(separator: "|") }
}

/// Text resolved to sound, ready to query.
struct SoundQuery: Sendable {
    let words: [String]
    /// The language each word was read in.
    let languages: [Language]
    /// Alternate pronunciations for a single word; exactly one entry for a phrase.
    let prons: [Pron]
    /// False when any word had to be guessed from its spelling.
    let known: Bool
    /// The lexicon entries the words resolved to, where they did.
    let entries: [Int32]

    var primary: Pron { prons.first ?? [] }
    var isPhrase: Bool { words.count > 1 }
    /// The language of the word the rhyme lands on.
    var language: Language { languages.last ?? .english }
}

struct RhymeEngine: Sendable {
    let lexicon: Lexicon
    let detector: LanguageDetector

    init(lexicon: Lexicon) {
        self.lexicon = lexicon
        self.detector = LanguageDetector(lexicon: lexicon)
    }

    /// Resolves text to sound. The language of each word is `forced` if given, otherwise
    /// detected from the surrounding line (`context`) or from the words themselves.
    func query(_ text: String, as forced: Language? = nil, context: String? = nil, active: [Language]) -> SoundQuery? {
        let phrases = Tokenizer.phrases(in: text)
        let words = phrases.words
        guard !words.isEmpty else { return nil }

        var languages: [Language]
        if let forced {
            languages = words.map { _ in forced }
        } else if let context {
            let surrounding = Tokenizer.phrases(in: context)
            let detected = detector.detect(surrounding.words, breaks: surrounding.breaks, active: active)
            let alone = detector.detect(words, breaks: phrases.breaks, active: active)
            languages = words.enumerated().map { index, word in
                surrounding.words.lastIndex(of: word).map { detected[$0] } ?? alone[index]
            }
        } else {
            languages = detector.detect(words, breaks: phrases.breaks, active: active)
        }
        // A word in an Indic script is in that script's language whatever was asked for.
        for (index, word) in words.enumerated() {
            switch Script.of(word) {
            case .devanagari: languages[index] = .hindi
            case .gujarati: languages[index] = .gujarati
            default: break
            }
        }

        if words.count == 1 {
            let said = lexicon.pronounce(words[0], as: languages[0])
            guard !said.prons.isEmpty else { return nil }
            var unique: [Pron] = []
            for pron in said.prons where !unique.contains(where: { $0.normalized == pron.normalized }) {
                unique.append(pron)
            }
            return SoundQuery(words: words, languages: languages, prons: unique, known: said.known, entries: said.entry.map { [$0] } ?? [])
        }
        var joined: Pron = []
        var known = true
        var entries: [Int32] = []
        for (word, language) in zip(words, languages) {
            let said = lexicon.pronounce(word, as: language)
            joined += said.prons.first ?? []
            known = known && said.known
            if let entry = said.entry { entries.append(entry) }
        }
        guard !joined.isEmpty else { return nil }
        return SoundQuery(words: words, languages: languages, prons: [joined], known: known, entries: entries)
    }

    // MARK: Perfect

    /// Identical from the rhyming vowel onward, in any language.
    func perfect(_ query: SoundQuery, scope: Scope, limit: Int = 150) -> [RhymeHit] {
        var collector = Collector()
        for pron in query.prons {
            let tail = pron.rhymeTail
            let whole = pron.normalized
            guard !tail.isEmpty else { continue }
            for entry in lexicon.entries(.rhymeTail, tail) where allowed(entry, scope) {
                let candidate = lexicon.pron(entry)
                guard candidate.rhymeTail == tail, candidate.normalized != whole else { continue }
                collector.add(entry, score: 1, syllables: candidate.syllableCount)
            }
        }
        return hits(collector, near: query.primary.syllableCount, excluding: query, scope: scope, limit: limit)
    }

    // MARK: Slant

    /// Same vowels through the rhyme tail with consonants that are close but not identical
    /// (time / mind / line). Vowels a language treats as the same family count as the same
    /// (Spanish "qué", English "day"); loose also lets one vowel drift to a neighbour (pen / pin).
    func slant(_ query: SoundQuery, scope: Scope, limit: Int = 150) -> [RhymeHit] {
        var collector = Collector()
        let drift = scope.looseness == .loose ? 0.55 : 0.8
        for pron in query.prons {
            let tail = pron.rhymeTail
            let whole = pron.normalized
            let tailVowels = tail.filter(\.isVowel)
            guard !tailVowels.isEmpty else { continue }
            var keys = [tailVowels.map(\.vowelKey)]
            for position in tailVowels.indices {
                for neighbor in Similarity.neighborKeys(of: tailVowels[position], atLeast: drift) {
                    var variant = keys[0]
                    variant[position] = neighbor
                    if !keys.contains(variant) { keys.append(variant) }
                }
            }
            for key in keys {
                for entry in lexicon.entries(.tailVowels, key) where allowed(entry, scope) {
                    let candidate = lexicon.pron(entry)
                    let candidateTail = candidate.rhymeTail
                    guard candidateTail != tail, candidate.normalized != whole else { continue }
                    let score = Similarity.tails(tail, candidateTail)
                    guard score >= scope.looseness.slantFloor else { continue }
                    collector.add(entry, score: score, syllables: candidate.syllableCount)
                }
            }
        }
        return hits(collector, near: query.primary.syllableCount, excluding: query, scope: scope, limit: limit)
    }

    // MARK: Multis

    /// Words matching the query's last 2, 3 and 4 vowel sounds regardless of where the stress
    /// falls: the multisyllabic rhymes rap is built on. Longest matches first. `includePerfect`
    /// keeps true rhymes in the groups; the Lab leaves them out because it lists them separately.
    func multis(_ query: SoundQuery, scope: Scope, includePerfect: Bool = false, limitPerGroup: Int = 60) -> [MultiGroup] {
        let pron = query.primary
        let vowels = pron.vowelKeys
        guard vowels.count >= 2 else { return [] }
        let perfectTail = pron.rhymeTail
        var seen = Set<String>()
        var groups: [MultiGroup] = []
        for size in stride(from: min(4, vowels.count), through: 2, by: -1) {
            guard let kind = IndexKind.vowelSuffix(size) else { continue }
            let suffix = Array(vowels.suffix(size))
            let queryTail = pron.tail(fromLastVowels: size)
            var collector = Collector()
            for entry in lexicon.entries(kind, suffix) where allowed(entry, scope) {
                let candidate = lexicon.pron(entry)
                guard candidate.vowelKeys.suffix(size).elementsEqual(suffix),
                      includePerfect || candidate.rhymeTail != perfectTail else { continue }
                collector.add(entry, score: Similarity.tails(queryTail, candidate.tail(fromLastVowels: size)), syllables: candidate.syllableCount)
            }
            let fresh = hits(collector, near: pron.syllableCount, excluding: query, scope: scope, limit: limitPerGroup).filter { seen.insert($0.id).inserted }
            if !fresh.isEmpty { groups.append(MultiGroup(syllables: size, hits: fresh)) }
        }
        return groups
    }

    // MARK: Mosaic

    /// Splits the query into two runs of vowels and finds everyday words for each, so
    /// "orange" can be answered by "door" + "hinge".
    func mosaics(_ query: SoundQuery, scope: Scope, perSlot: Int = 16) -> [Mosaic] {
        let pron = query.primary
        let vowelPositions = pron.indices.filter { pron[$0].isVowel }
        let total = vowelPositions.count
        guard total >= 2, total <= 8 else { return [] }
        let half = total / 2
        var cuts = [half]
        if total - half != half { cuts.append(total - half) } else if half > 1 { cuts.append(half - 1) }

        var result: [Mosaic] = []
        for cut in cuts where cut >= 1 && total - cut >= 1 && cut <= 4 && total - cut <= 4 {
            // Stress comes off but a weak "ih" stays "ih", so "-ing" finds "king" rather than "hung".
            let first = pron[vowelPositions[0]..<vowelPositions[cut]].map(\.unstressed)
            let second = pron[vowelPositions[cut]...].map(\.unstressed)
            let slots = [first, second].map { slot(matching: $0, excluding: query, scope: scope, limit: perSlot) }
            if slots.allSatisfy({ !$0.isEmpty }) { result.append(Mosaic(slots: slots)) }
        }
        return result
    }

    private func slot(matching segment: Pron, excluding query: SoundQuery, scope: Scope, limit: Int) -> [RhymeHit] {
        var collector = Collector()
        let vowels = segment.filter(\.isVowel).map(\.vowelKey)
        for entry in lexicon.entries(.wholeVowels, vowels) where lexicon.tier(entry) == 0 && scope.languages.contains(lexicon.language(entry)) {
            let candidate = lexicon.pron(entry)
            guard candidate.vowelKeys == vowels else { continue }
            collector.add(entry, score: Similarity.tails(segment, candidate.tail(fromLastVowels: vowels.count)), syllables: candidate.syllableCount)
        }
        // One row of chips per slot, so the languages share a single list here.
        return Array(hits(collector, near: vowels.count, excluding: query, scope: scope, limit: limit).prefix(limit))
    }

    // MARK: Homophones

    /// Different word, same sound, in any language. Beyond strict, also words one similar
    /// sound away (accept / except; dil / dill).
    func homophones(_ query: SoundQuery, scope: Scope) -> [RhymeHit] {
        guard !query.isPhrase else { return [] }
        let near = scope.looseness != .strict
        let floor = scope.looseness == .loose ? 0.55 : 0.6
        var collector = Collector()
        // Every sound in its plain form, to try as a replacement.
        let last = Phone.consonantCount + UInt8(Phone.vowelSymbols.count) * 3
        let inventory = Set((0..<last).map { Phone($0).normalized })
        for pron in query.prons {
            let whole = pron.normalized
            func collect(_ variant: Pron, score: Double) {
                for entry in lexicon.entries(.wholePron, variant) where allowed(entry, scope) {
                    let candidate = lexicon.pron(entry)
                    guard candidate.normalized == variant else { continue }
                    collector.add(entry, score: score, syllables: candidate.syllableCount)
                }
            }
            collect(whole, score: 1)
            guard near, whole.count >= 3 else { continue }
            for position in whole.indices {
                let original = whole[position]
                for replacement in inventory where replacement != original && replacement.isVowel == original.isVowel {
                    let similarity = Similarity.of(original, replacement)
                    guard similarity >= floor else { continue }
                    var variant = whole
                    variant[position] = replacement
                    collect(variant, score: 0.5 + similarity * 0.4)
                }
            }
        }
        return hits(collector, near: query.primary.syllableCount, excluding: query, scope: scope, limit: 40)
            .sorted { ($0.score, -Int($0.tier)) > ($1.score, -Int($1.tier)) }
    }

    // MARK: Sound-alike phrases

    /// Other ways to carve the same stream of sound into words: "ice cream" / "I scream".
    /// The words may come from any language in play. Hindi and Gujarati words are given in
    /// Roman letters so the phrase reads in one line.
    func soundAlikes(_ query: SoundQuery, scope: Scope, limit: Int = 30) -> [String] {
        let sounds = query.primary.normalized
        guard sounds.count >= 3, sounds.count <= 28 else { return [] }
        let original = query.words.joined(separator: " ")
        let maxWords = min(4, max(2, sounds.filter(\.isVowel).count))

        // Best everyday word for each stretch of sound, found once.
        var cache: [Int: [Int: (word: String, tier: UInt8)?]] = [:]
        func word(from start: Int, length: Int) -> (word: String, tier: UInt8)? {
            if let cached = cache[start]?[length] { return cached }
            let segment = Array(sounds[start..<(start + length)])
            var best: (entry: Int32, rank: Int)?
            if segment.contains(where: \.isVowel) {
                for entry in lexicon.entries(.wholePron, segment) where lexicon.tier(entry) < 2 && scope.languages.contains(lexicon.language(entry)) {
                    // Single-sound words only when they are grammar everyone uses (a, I, y, à).
                    guard length > 1 || lexicon.freq(entry) >= 150, lexicon.pron(entry).normalized == segment else { continue }
                    let rank = Int(lexicon.freq(entry)) - Int(lexicon.tier(entry)) * 100
                    if best == nil || rank > best!.rank { best = (entry, rank) }
                }
            }
            let found: (word: String, tier: UInt8)? = best.flatMap { best in
                let language = lexicon.language(best.entry)
                let text = language.isIndic ? lexicon.roman(best.entry) : lexicon.word(best.entry)
                return text.contains("'") || text.isEmpty ? nil : (text, lexicon.tier(best.entry))
            }
            cache[start, default: [:]][length] = found
            return found
        }

        var found: [(phrase: String, words: Int, rarity: Int)] = []
        var current: [(word: String, tier: UInt8)] = []
        func search(_ start: Int) {
            guard found.count < 400 else { return }
            if start == sounds.count {
                let phrase = current.map(\.word).joined(separator: " ")
                if phrase != original && (current.count > 1 || query.isPhrase) {
                    found.append((phrase, current.count, current.reduce(0) { $0 + Int($1.tier) }))
                }
                return
            }
            guard current.count < maxWords else { return }
            for length in 1...min(12, sounds.count - start) {
                guard let match = word(from: start, length: length) else { continue }
                current.append(match)
                search(start + length)
                current.removeLast()
            }
        }
        search(0)

        var seen = Set<String>()
        return found.sorted { ($0.words, $0.rarity, $0.phrase) < ($1.words, $1.rarity, $1.phrase) }
            .compactMap { seen.insert($0.phrase).inserted ? $0.phrase : nil }
            .prefix(limit)
            .map { $0.split(separator: " ").map { $0 == "i" ? "I" : String($0) }.joined(separator: " ") }
    }

    // MARK: Consonance

    /// Same consonant skeleton with the vowels swapped out: flip / flop, lover / liver.
    func consonance(_ query: SoundQuery, scope: Scope, limit: Int = 40) -> [RhymeHit] {
        guard !query.isPhrase else { return [] }
        var collector = Collector()
        for pron in query.prons {
            let skeleton = pron.consonants
            guard skeleton.count >= 2 else { continue }
            let vowels = pron.vowels
            for entry in lexicon.entries(.consonants, skeleton) where scope.languages.contains(lexicon.language(entry)) {
                let candidate = lexicon.pron(entry)
                guard candidate.consonants == skeleton, candidate.vowels != vowels else { continue }
                let sameShape = candidate.syllableCount == pron.syllableCount
                collector.add(entry, score: sameShape ? 1 : 0.6, syllables: candidate.syllableCount)
            }
        }
        return hits(collector, near: query.primary.syllableCount, excluding: query, scope: scope, limit: limit)
    }

    /// Same opening sound through the first vowel: flip / flick / flint.
    func frontRhymes(_ query: SoundQuery, scope: Scope, limit: Int = 40) -> [RhymeHit] {
        let pron = query.primary
        guard let firstVowel = pron.firstIndex(where: \.isVowel), firstVowel > 0 else { return [] }
        let head = pron[...firstVowel].map(\.normalized)
        var collector = Collector()
        for entry in lexicon.entries(.head, head) where scope.languages.contains(lexicon.language(entry)) {
            let candidate = lexicon.pron(entry)
            guard candidate.count > firstVowel, candidate[...firstVowel].map(\.normalized) == head,
                  candidate[firstVowel].isStressedVowel == pron[firstVowel].isStressedVowel else { continue }
            collector.add(entry, score: 1, syllables: candidate.syllableCount)
        }
        return hits(collector, near: pron.syllableCount, excluding: query, scope: scope, limit: limit)
    }

    // MARK: Helpers

    private func allowed(_ entry: Int32, _ scope: Scope) -> Bool {
        (scope.includeRare || lexicon.tier(entry) < 2) && scope.languages.contains(lexicon.language(entry))
    }

    /// A result for a lexicon entry, with its script, romanization and meaning filled in.
    func hit(_ entry: Int32, score: Double, syllables: Int? = nil) -> RhymeHit {
        RhymeHit(
            word: lexicon.word(entry), language: lexicon.language(entry), score: score,
            syllables: syllables ?? lexicon.pron(entry).syllableCount, tier: lexicon.tier(entry),
            roman: lexicon.roman(entry), gloss: lexicon.gloss(entry)
        )
    }

    /// Best matches first, with everyday words and words of a similar length to the query
    /// nudged ahead of obscure or lopsided ones. Each language gets its own `limit`, so one
    /// with a huge vocabulary cannot crowd the others out; within the result the languages
    /// stay interleaved by quality.
    private func hits(_ collector: Collector, near target: Int, excluding query: SoundQuery, scope: Scope, limit: Int) -> [RhymeHit] {
        let ranked = collector.all.map { candidate -> (Collector.Candidate, Double) in
            let rank = candidate.score - Double(lexicon.tier(candidate.entry)) * 0.06
                - Double(min(3, abs(candidate.syllables - target))) * 0.02 + Double(lexicon.freq(candidate.entry)) * 0.0004
            return (candidate, rank)
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.entry < $1.0.entry }

        var taken: [Language: Int] = [:]
        var seen = Set<String>()
        var result: [RhymeHit] = []
        let queryWords = Set(zip(query.words, query.languages).map { "\($1.code):\($0)" })
        for (candidate, _) in ranked {
            let language = lexicon.language(candidate.entry)
            guard taken[language, default: 0] < limit, !query.entries.contains(candidate.entry) else { continue }
            let hit = hit(candidate.entry, score: candidate.score, syllables: candidate.syllables)
            guard !queryWords.contains(hit.id), seen.insert(hit.id).inserted else { continue }
            taken[language, default: 0] += 1
            result.append(hit)
        }
        return result
    }

    /// Keeps the best score per lexicon entry.
    private struct Collector {
        struct Candidate {
            let entry: Int32
            let score: Double
            let syllables: Int
        }

        private var best: [Int32: Candidate] = [:]

        mutating func add(_ entry: Int32, score: Double, syllables: Int) {
            if let existing = best[entry], existing.score >= score { return }
            best[entry] = Candidate(entry: entry, score: score, syllables: syllables)
        }

        var all: [Candidate] { Array(best.values) }
    }
}
