import Foundation

/// The directions a word can be left in. Each is one of the moves in the writer's own chains:
/// "sunshine … photosynthetic" loops home, "might : mite : smite" is sound, "pagal : paa's gal"
/// recuts the same letters, "tape : roll : reel" is meaning, "Bapesta : Planet of the Apes :
/// Caesar" is culture, "sweet heart : bleeding heart : bleeding edge" is the hinge, "pagal : my
/// krazy life" crosses tongues, "dodge a wrench : dodge a hex" is a leap.
enum OrbitDirection: String, CaseIterable, Identifiable, Sendable, Codable {
    case home, sound, recut, meaning, roots, culture, hinge, tongues, leap

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: "Home"
        case .sound: "Sound"
        case .recut: "Recut"
        case .meaning: "Meaning"
        case .roots: "Roots"
        case .culture: "Culture"
        case .hinge: "Hinge"
        case .tongues: "Tongues"
        case .leap: "Leap"
        }
    }

    var blurb: String {
        switch self {
        case .home: "where you came from, the bridge words, echoes"
        case .sound: "rhymes, homophones, the same tail"
        case .recut: "the same letters cut another way"
        case .meaning: "what it means, sits near, and keeps going"
        case .roots: "the Latin, Greek or Sanskrit it grew from, and its siblings"
        case .culture: "films, shows and books it runs through"
        case .hinge: "half the phrase stays, half swaps"
        case .tongues: "the same thing in your other languages"
        case .leap: "idiom twists and far jumps"
        }
    }

    var symbol: String {
        switch self {
        case .home: "arrow.uturn.backward"
        case .sound: "waveform"
        case .recut: "scissors"
        case .meaning: "brain"
        case .roots: "tree"
        case .culture: "film"
        case .hinge: "link"
        case .tongues: "globe"
        case .leap: "sparkles"
        }
    }

    /// Where the direction sits on the sphere, in degrees of longitude from the front: the
    /// directions share the circle evenly.
    var longitude: Double { Double(OrbitDirection.allCases.firstIndex(of: self) ?? 0) * 360 / Double(OrbitDirection.allCases.count) }

    /// The five pulls every node is measured on.
    static let measured: [OrbitDirection] = [.sound, .hinge, .meaning, .culture, .tongues]
}

/// One place to go next, and how hard it pulls.
struct OrbitNode: Identifiable, Sendable, Hashable {
    let text: String
    let direction: OrbitDirection
    /// 0...1 along its own direction.
    let weight: Double
    /// Why it is here, in a few words ("rhymes", "· heart", "near in meaning", "about it").
    let why: String
    let language: Language
    /// Its pull in every measured direction at once: sound, hinge, meaning, culture, tongues, 0...1 each.
    var vector: [Double] = [0, 0, 0, 0, 0]
    /// Roman spelling or short meaning, shown small.
    var aside = ""
    /// The English meaning, for a node in another language.
    var gloss = ""
    /// The Roman spelling of a Hindi or Gujarati word, so its script never has to be read alone.
    var roman = ""

    var id: String { direction.rawValue + "|" + text }
}

/// Everything around one word.
struct Orbit: Sendable {
    let centre: String
    let language: Language
    /// The English ideas behind the centre, for the culture index.
    var ideas: [String] = []
    /// The centre's Roman spelling when it is a Hindi or Gujarati word in its own script.
    var roman = ""
    var nodes: [OrbitNode] = []
    /// Nodes that connect back to an earlier step of the chain.
    var echoes: Set<String> = []
    /// The classical words around it (Latin lūx, *lewk-), by node text, with their family's key:
    /// stepping onto one stands in exactly that family.
    var classical: [String: String] = [:]

    func nodes(in direction: OrbitDirection) -> [OrbitNode] {
        nodes.filter { $0.direction == direction }.sorted { $0.weight > $1.weight }
    }
}

/// The two-word phrases a word lives in: "bleeding heart", "heart attack". From hinges.tsv
/// (left, right, weight), one phrase per line, sorted by the left word.
final class HingeIndex: @unchecked Sendable {
    private var byLeft: [String: [(String, Double)]] = [:]
    private var byRight: [String: [(String, Double)]] = [:]

    init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 3, let weight = Double(fields[2]) else { continue }
            let left = String(fields[0]), right = String(fields[1])
            byLeft[left, default: []].append((right, weight))
            byRight[right, default: []].append((left, weight))
        }
    }

    /// The phrases a word sits in, strongest first, with the word's partner marked: "bleeding ·".
    func phrases(with word: String, limit: Int = 30) -> [(phrase: String, partner: String, weight: Double, wordFirst: Bool)] {
        var found: [(String, String, Double, Bool)] = []
        for (right, weight) in byLeft[word] ?? [] { found.append((word + " " + right, right, weight, true)) }
        for (left, weight) in byRight[word] ?? [] { found.append((left + " " + word, left, weight, false)) }
        return found.sorted { $0.2 > $1.2 }.prefix(limit).map { ($0.0, $0.1, $0.2, $0.3) }
    }

    func weight(_ left: String, _ right: String) -> Double {
        byLeft[left]?.first { $0.0 == right }?.1 ?? 0
    }
}

extension Engine {
    /// Prefixes a word can carry over to the next: "re wind : re bar : remitter".
    private static let prefixes = ["counter", "inter", "under", "over", "micro", "tele", "trans", "super", "anti", "auto", "semi", "pre", "pro", "dis", "mis", "out", "sub", "non", "re", "un", "de", "ex", "in"]

    /// Everything one step away from a word or phrase, in every direction the engine can take
    /// on its own. Culture and leaps are added by the caller: culture from its own index,
    /// leaps from Claude.
    func orbit(for text: String, trail: [String], scope: Scope, family: String? = nil) -> Orbit {
        let fallback = scope.languages.first ?? .english
        // A classical word (stepped onto from the roots, or typed as one) has no sound or meaning
        // the engine can read; its sphere is its family and the way home.
        if family != nil || (rhymes?.query(text, active: scope.languages) == nil && RootIndex.looksClassical(text)) {
            return classicalOrbit(for: text, trail: trail, scope: scope, family: family, language: fallback)
        }
        guard let rhymes, let query = rhymes.query(text, active: scope.languages) else { return Orbit(centre: text, language: fallback) }
        let language = query.language
        var orbit = Orbit(centre: text, language: language)
        orbit.ideas = concepts(for: query)
        orbit.roman = romanization(of: text, query: query)
        let lowered = text.lowercased()
        let centreWords = Set(query.words.map { Tokenizer.clean($0) })
        var seen = Set<String>()

        func add(_ node: OrbitNode) {
            guard node.text.lowercased() != lowered, seen.insert(node.id).inserted else { return }
            orbit.nodes.append(node)
        }
        func hit(_ hit: RhymeHit, _ direction: OrbitDirection, weight: Double, why: String) -> OrbitNode {
            let gloss = hit.gloss.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            let roman = !hit.roman.isEmpty && hit.roman != hit.word ? hit.roman : ""
            return OrbitNode(text: hit.word, direction: direction, weight: weight, why: why, language: hit.language,
                             aside: roman.isEmpty ? gloss : roman, gloss: gloss, roman: roman)
        }

        // Sound: the same sound, the same tail.
        for h in rhymes.homophones(query, scope: scope).prefix(8) { add(hit(h, .sound, weight: 1, why: "sounds the same")) }
        for h in rhymes.perfect(query, scope: scope, limit: 22) { add(hit(h, .sound, weight: 0.55 + 0.35 * h.score, why: "rhymes")) }
        for h in rhymes.slant(query, scope: scope, limit: 14) { add(hit(h, .sound, weight: 0.3 + 0.35 * h.score, why: "slant")) }
        for h in rhymes.frontRhymes(query, scope: scope, limit: 6) { add(hit(h, .sound, weight: 0.3 + 0.2 * h.score, why: "front rhyme")) }

        // Recut: the same letters heard another way, flipped, the words hiding inside, the prefix carried.
        for phrase in rhymes.soundAlikes(query, scope: scope, limit: 10) {
            add(OrbitNode(text: phrase, direction: .recut, weight: 0.9, why: "heard as", language: language))
        }
        for flip in Self.flips(of: text, syllables: query.primary.syllableCount) {
            add(OrbitNode(text: flip.text, direction: .recut, weight: flip.weight, why: flip.why, language: language))
        }
        if query.words.count == 1, language == .english || language == .spanish || language == .french {
            let word = Tokenizer.clean(query.words[0])
            for inside in Self.insideWords(of: word, in: language, lexicon: rhymes.lexicon).prefix(8) {
                add(OrbitNode(text: inside.text, direction: .recut, weight: inside.weight, why: "inside", language: language))
            }
            if let prefix = Self.prefixes.first(where: { word.hasPrefix($0) && word.count >= $0.count + 3 }) {
                let carried = rhymes.lexicon.entries(withPrefix: prefix, in: language, limit: 400)
                    .filter { rhymes.lexicon.tier($0) == 0 && rhymes.lexicon.freq($0) >= 40 }
                    .sorted { rhymes.lexicon.freq($0) > rhymes.lexicon.freq($1) }
                for entry in carried.prefix(40) where orbit.nodes.filter({ $0.why.hasPrefix("carries") }).count < 8 {
                    let other = rhymes.lexicon.word(entry)
                    guard other != word, other.count >= prefix.count + 3 else { continue }
                    add(OrbitNode(text: other, direction: .recut, weight: 0.45 + 0.2 * Double(rhymes.lexicon.freq(entry)) / 200, why: "carries \(prefix)·", language: language))
                }
            }
        }

        // Hinge: the phrases each word lives in; for a phrase, swap either half.
        if let hinges {
            let words = query.words.map { Tokenizer.clean($0) }
            for word in words {
                for phrase in hinges.phrases(with: word, limit: words.count > 1 ? 14 : 24) where !words.contains(phrase.partner) {
                    let why = phrase.wordFirst ? "\(word) ·" : "· \(word)"
                    add(OrbitNode(text: phrase.phrase, direction: .hinge, weight: phrase.weight, why: why, language: language))
                }
            }
        }

        // Meaning: the embedding's neighbourhood of the first idea, and what keeps going the way
        // the chain was already moving.
        let seed = orbit.ideas.first { semantics.vector(for: $0) != nil }
        let seedVector = seed.flatMap { semantics.vector(for: $0) }
        if let seed {
            for (word, distance) in semantics.related(to: seed, looseness: scope.looseness, limit: 28) where word != lowered {
                add(OrbitNode(text: word, direction: .meaning, weight: max(0.05, 1 - distance / 1.4), why: "near in meaning", language: .english))
            }
        }
        if let seedVector, let previous = trail.last, let before = semantics.vector(for: idea(for: previous, languages: scope.languages)), let embedding = semantics.embedding {
            let arrow = zip(seedVector, before).map { $0 - $1 }
            if semantics.norm(arrow) > 0.05 {
                let target = zip(seedVector, arrow).map { $0 + $1 }
                for (word, _) in embedding.neighbors(for: target, maximumCount: 30) where word != lowered && !centreWords.contains(word) {
                    guard let raw = embedding.vector(for: word) else { continue }
                    let length = semantics.norm(raw)
                    guard length > 0 else { continue }
                    let step = zip(raw.map { $0 / length }, seedVector).map { $0 - $1 }
                    let lengths = semantics.norm(step) * semantics.norm(arrow)
                    let parallel = lengths > 0 ? zip(step, arrow).reduce(0) { $0 + $1.0 * $1.1 } / lengths : 0
                    guard parallel >= 0.12 else { continue }
                    add(OrbitNode(text: word, direction: .meaning, weight: min(1, 0.4 + parallel), why: "keeps going", language: .english))
                }
            }
        }

        // Roots: the classical word it came from, the deeper root, and the words in every
        // language that grew from them; a classical word stepped onto stands in its family.
        let classical = addRoots(roots(of: text, scope: scope), language: language, add: add, hit: hit)
        orbit.classical.merge(classical) { first, _ in first }

        // Tongues: the same sense in the other languages, and their own-script forms.
        for h in translations(of: orbit.ideas, from: language, scope: scope).prefix(24) where h.language != language || h.word.lowercased() != lowered {
            add(hit(h, .tongues, weight: h.score, why: h.language.name))
        }

        // Home: the origin, the step before, and the words that sit between here and there.
        if let origin = trail.first {
            add(OrbitNode(text: origin, direction: .home, weight: 1, why: "the origin", language: language, roman: romanization(of: origin, languages: scope.languages)))
            if let previous = trail.last, previous != origin {
                add(OrbitNode(text: previous, direction: .home, weight: 0.9, why: "one step back", language: language, roman: romanization(of: previous, languages: scope.languages)))
            }
            if let seed {
                for step in [trail.last, trail.first].compactMap({ $0 }).reversed() {
                    let idea = self.idea(for: step, languages: scope.languages)
                    for (word, distance) in semantics.commonGround(seed, idea, limit: 10).prefix(5) where word != lowered && !VerseAnalyzer.functionWords.contains(word) {
                        add(OrbitNode(text: word, direction: .home, weight: max(0.1, 1 - distance / 1.4), why: "between you and \(step)", language: .english))
                    }
                }
            }
        }

        // Every node's pull in every direction, so the vectors can be seen.
        let trailLowered = trail.map { $0.lowercased() }
        let trailVectors = trail.compactMap { semantics.vector(for: $0) }
        for index in orbit.nodes.indices {
            let node = orbit.nodes[index]
            var vector = [0.0, 0.0, 0.0, 0.0, 0.0]
            vector[0] = node.direction == .sound ? node.weight : soundPull(query, node.text, as: node.language)
            let nodeWords = Set(Tokenizer.words(in: node.text))
            vector[1] = node.direction == .hinge ? node.weight : (hinges.map { h in
                centreWords.contains { c in nodeWords.contains { n in h.weight(c, n) > 0 || h.weight(n, c) > 0 } }
            } ?? false ? 0.6 : 0)
            if let seedVector, let other = meaningVector(for: node) {
                vector[2] = max(0, 1 - semantics.distance(seedVector, other) / 1.4)
            }
            vector[4] = node.direction == .tongues ? node.weight : (node.language != language ? 0.5 : 0)
            orbit.nodes[index].vector = vector
            // An echo: it reaches back to a step the chain already took.
            if node.direction != .home {
                if trailLowered.contains(where: { step in step == node.text.lowercased() || Set(Tokenizer.words(in: step)).isSubset(of: nodeWords) }) {
                    orbit.echoes.insert(node.id)
                } else if let other = meaningVector(for: node), trailVectors.contains(where: { semantics.distance($0, other) < 0.75 }) {
                    orbit.echoes.insert(node.id)
                }
            }
        }
        return orbit
    }

    /// The roots direction: each etymon and root as a node (remembered by key, so stepping onto
    /// it is exact), and the words in the writer's languages that grew from them.
    private func addRoots(_ reading: RootReading, language: Language,
                          add: (OrbitNode) -> Void, hit: (RhymeHit, OrbitDirection, Double, String) -> OrbitNode) -> [String: String] {
        var classical: [String: String] = [:]
        for step in reading.etyma {
            classical[step.family.form] = step.family.key
            add(OrbitNode(text: step.family.form, direction: .roots, weight: 1, why: step.family.source.name + " origin",
                          language: language, aside: step.family.gloss, gloss: step.family.gloss, roman: step.family.roman == step.family.form ? "" : step.family.roman))
            for sibling in step.siblings.prefix(10) { add(hit(sibling, .roots, 0.85 * max(0.6, sibling.score), "from \(step.family.source.short) \(step.family.form)")) }
        }
        for step in reading.roots {
            classical[step.family.form] = step.family.key
            add(OrbitNode(text: step.family.form, direction: .roots, weight: 0.8, why: step.family.source.short + " root",
                          language: language, aside: step.family.gloss, gloss: step.family.gloss, roman: step.family.roman == step.family.form ? "" : step.family.roman))
            for sibling in step.siblings.prefix(8) { add(hit(sibling, .roots, 0.55 * max(0.6, sibling.score), "root \(step.family.form)")) }
        }
        return classical
    }

    /// The sphere of a classical word: its family (or the root it is) and the way home.
    private func classicalOrbit(for text: String, trail: [String], scope: Scope, family: String?, language: Language) -> Orbit {
        var orbit = Orbit(centre: text, language: language)
        var seen = Set<String>()
        func add(_ node: OrbitNode) {
            guard node.text != text, seen.insert(node.id).inserted else { return }
            orbit.nodes.append(node)
        }
        func hit(_ hit: RhymeHit, _ direction: OrbitDirection, _ weight: Double, _ why: String) -> OrbitNode {
            let gloss = hit.gloss.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            let roman = !hit.roman.isEmpty && hit.roman != hit.word ? hit.roman : ""
            return OrbitNode(text: hit.word, direction: direction, weight: weight, why: why, language: hit.language,
                             aside: roman.isEmpty ? gloss : roman, gloss: gloss, roman: roman)
        }
        let classical = addRoots(roots(of: text, scope: scope, family: family), language: language, add: add, hit: hit)
        orbit.classical.merge(classical) { first, _ in first }
        if let origin = trail.first {
            add(OrbitNode(text: origin, direction: .home, weight: 1, why: "the origin", language: language))
            if let previous = trail.last, previous != origin {
                add(OrbitNode(text: previous, direction: .home, weight: 0.9, why: "one step back", language: language))
            }
        }
        return orbit
    }

    /// The Roman spelling of a Devanagari or Gujarati word or phrase, from the dictionary where
    /// it has one; "" for anything already in Roman letters.
    func romanization(of text: String, languages: [Language]) -> String {
        guard let rhymes, let query = rhymes.query(text, active: languages) else { return "" }
        return romanization(of: text, query: query)
    }

    private func romanization(of text: String, query: SoundQuery) -> String {
        guard let rhymes, query.language.isIndic, Script.of(text) != .latin else { return "" }
        let roman: String
        if query.isPhrase {
            // Only when every word is known: a half-spelt phrase would read as the wrong one.
            guard query.entries.count == query.words.count else { return "" }
            roman = query.entries.map { rhymes.lexicon.roman($0) }.joined(separator: " ")
        } else {
            roman = query.entries.first.map { rhymes.lexicon.roman($0) } ?? IndicG2P.romanize(query.primary)
        }
        return roman.trimmingCharacters(in: .whitespaces).isEmpty || roman == text ? "" : roman
    }

    /// The words that sit between two steps: the unwritten bridge of a hop ("organ failure"
    /// to "edge node" goes through "node").
    func bridge(between a: String, and b: String, languages: [Language]) -> [String] {
        let first = idea(for: a, languages: languages), second = idea(for: b, languages: languages)
        let own = Set(Tokenizer.words(in: first) + Tokenizer.words(in: second))
        return semantics.commonGround(first, second, limit: 12)
            .map(\.word)
            .filter { !own.contains($0) && !VerseAnalyzer.functionWords.contains($0) }
            .prefix(3)
            .map { $0 }
    }

    /// The meaning vector of a node: its own words when English, its gloss otherwise.
    /// The nodes that lead toward a pinned word: they share a word with it, or sit close to it
    /// in meaning. The same test as an echo of the chain, against the pins instead.
    func attracted(_ nodes: [OrbitNode], to pins: [String], languages: [Language]) -> Set<String> {
        let pinned = pins.map { (lowered: $0.lowercased(), words: Set(Tokenizer.words(in: $0)), vector: semantics.vector(for: idea(for: $0, languages: languages))) }
        var found = Set<String>()
        for node in nodes {
            let text = node.text.lowercased()
            let words = Set(Tokenizer.words(in: node.text))
            let vector = meaningVector(for: node)
            for pin in pinned {
                let shared = text == pin.lowered || (!pin.words.isEmpty && (pin.words.isSubset(of: words) || words.isSubset(of: pin.words) && !words.isEmpty))
                let near = vector.flatMap { own in pin.vector.map { semantics.distance(own, $0) < 0.8 } } ?? false
                if shared || near {
                    found.insert(node.id)
                    break
                }
            }
        }
        return found
    }

    private func meaningVector(for node: OrbitNode) -> [Double]? {
        if node.language == .english, let vector = semantics.vector(for: node.text) { return vector }
        guard !node.gloss.isEmpty else { return nil }
        return semantics.vector(for: node.gloss)
    }

    /// How much a word shares the centre's sound: the whole tail, the last vowel, or nothing.
    private func soundPull(_ query: SoundQuery, _ word: String, as language: Language) -> Double {
        guard let rhymes, let centre = query.prons.first, !centre.isEmpty,
              let other = rhymes.lexicon.pronounce(Tokenizer.words(in: word).last ?? word, as: language).prons.first, !other.isEmpty else { return 0 }
        if centre.rhymeTail.map(\.normalized) == other.rhymeTail.map(\.normalized) { return 1 }
        if centre.vowelKeys.last == other.vowelKeys.last { return 0.45 }
        return 0
    }

    /// The everyday words hiding inside a longer one: telephony holds "phony", "tele".
    static func insideWords(of word: String, in language: Language, lexicon: Lexicon) -> [(text: String, weight: Double)] {
        guard word.count >= 5 else { return [] }
        let letters = Array(word)
        var found: [(String, Double)] = []
        var seen = Set<String>()
        for length in stride(from: min(letters.count - 1, 8), through: 3, by: -1) {
            for start in 0...(letters.count - length) {
                let piece = String(letters[start..<start + length])
                guard seen.insert(piece).inserted, let entry = lexicon.bestEntry(forWord: piece, in: language), lexicon.tier(entry) == 0, lexicon.freq(entry) >= 30 else { continue }
                found.append((piece, 0.4 + 0.3 * Double(length) / Double(letters.count) + 0.1 * Double(lexicon.freq(entry)) / 200))
            }
        }
        return found.sorted { $0.1 > $1.1 }
    }

    /// "this time" flipped to "time this"; "chika" flipped to "ka chi".
    static func flips(of text: String, syllables: Int) -> [(text: String, weight: Double, why: String)] {
        let words = Tokenizer.words(in: text)
        if words.count >= 2 {
            return [(words.reversed().joined(separator: " "), 0.7, "flipped")]
        }
        guard let word = words.first, syllables >= 2, word.count >= 4, word.allSatisfy(\.isASCII) else { return [] }
        let vowels = Set("aeiouy")
        var cut = 0
        var sawVowel = false
        for (index, character) in word.enumerated() {
            if vowels.contains(character) { sawVowel = true } else if sawVowel { cut = index; break }
        }
        guard cut >= 2, cut <= word.count - 2 else { return [] }
        let head = String(word.prefix(cut)), rest = String(word.dropFirst(cut))
        guard rest.contains(where: vowels.contains) else { return [] }
        return [(rest + " " + head, 0.5, "syllables flipped")]
    }
}
