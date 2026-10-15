import Foundation

/// The classical roots behind words: the Latin, Ancient Greek or Sanskrit word a modern word
/// came from (its etymon), the deeper root that etymon grows from (a Proto-Indo-European root or
/// a Sanskrit dhatu), and every word in the writer's languages that shares either. From
/// roots.tsv, built out of Wiktionary by Tools/roots.
final class RootIndex: @unchecked Sendable {
    /// Where a family's words came from.
    enum Source: String, Sendable {
        case latin = "la", greek = "grc", sanskrit = "sa", indoEuropean = "ine-pro"

        var name: String {
            switch self {
            case .latin: "Latin"
            case .greek: "Greek"
            case .sanskrit: "Sanskrit"
            case .indoEuropean: "Proto-Indo-European"
            }
        }

        var short: String {
            switch self {
            case .latin: "Latin"
            case .greek: "Greek"
            case .sanskrit: "Sanskrit"
            case .indoEuropean: "PIE"
            }
        }
    }

    struct Family: Sendable, Identifiable, Hashable {
        let key: String
        /// A root (PIE, a dhatu) or an etymon (a classical word).
        let isRoot: Bool
        let source: Source
        let form: String
        let roman: String
        let gloss: String
        /// For an etymon, the roots it grows from.
        let roots: [String]
        /// The words in the app's languages that came from it.
        let members: [(language: Language, word: String)]

        var id: String { key }

        /// "Latin lūx, light" for a caption.
        var caption: String {
            let name = isRoot && source == .sanskrit ? "Sanskrit root" : isRoot ? "\(source.short) root" : source.name
            return gloss.isEmpty ? "\(name) \(form)" : "\(name) \(form), \(gloss)"
        }

        static func == (a: Family, b: Family) -> Bool { a.key == b.key }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }
    }

    private var families: [String: Family] = [:]
    /// "hi:बुद्धि" -> the families it belongs to.
    private var byWord: [String: [String]] = [:]
    /// A root -> the etyma that grow from it.
    private var children: [String: [String]] = [:]
    /// A classical form as typed ("lux", "lūx", "बुध्") -> its family keys.
    private var byForm: [String: [String]] = [:]

    var count: Int { families.count }

    init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 8, let source = Source(rawValue: fields[2]) else { continue }
            var members: [(Language, String)] = []
            for member in fields[7].split(separator: "|") {
                let parts = member.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let language = Language(code: parts[0]) else { continue }
                let word = language.isIndic ? parts[1].precomposedStringWithCanonicalMapping : parts[1].lowercased()
                members.append((language, word))
            }
            let family = Family(key: fields[0], isRoot: fields[1] == "root", source: source, form: fields[3], roman: fields[4],
                                gloss: fields[5], roots: fields[6].split(separator: "|").map(String.init), members: members)
            families[family.key] = family
            for (language, word) in members { byWord[language.code + ":" + word, default: []].append(family.key) }
            for root in family.roots { children[root, default: []].append(family.key) }
            byForm[Self.fold(family.form), default: []].append(family.key)
            if !family.roman.isEmpty { byForm[Self.fold(family.roman), default: []].append(family.key) }
        }
    }

    /// Whether typed text is a classical form in its own right: a reconstruction, Greek, or a
    /// Sanskrit root written with its final virama.
    static func looksClassical(_ text: String) -> Bool {
        if text.hasPrefix("*") { return true }
        return text.unicodeScalars.contains { (0x0370...0x03FF).contains($0.value) || (0x1F00...0x1FFF).contains($0.value) }
            || text.hasSuffix("\u{094D}")
    }

    /// The form a classical word is matched on: no length marks or accents, lowercase, no asterisk.
    static func fold(_ form: String) -> String {
        // Devanagari and Gujarati vowel signs and viramas are letters' parts, not accents:
        // folding them away would make different words one.
        let indic = form.unicodeScalars.contains { (0x0900...0x0AFF).contains($0.value) }
        let folded = indic ? form.precomposedStringWithCanonicalMapping : form.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded.trimmingCharacters(in: CharacterSet(charactersIn: "*-"))
    }

    func family(_ key: String) -> Family? { families[key] }

    /// The families a modern word belongs to: its etyma first, then its roots.
    func families(of word: String, in language: Language) -> [Family] {
        let clean = language.isIndic ? word.precomposedStringWithCanonicalMapping : word.lowercased()
        return (byWord[language.code + ":" + clean] ?? []).compactMap { families[$0] }.sorted { !$0.isRoot && $1.isRoot }
    }

    /// The families whose classical form is this text: stepping onto "lūx" stands in its family.
    func families(named text: String) -> [Family] {
        (byForm[Self.fold(text)] ?? []).compactMap { families[$0] }
    }

    /// For a root, the etyma that grow from it; for an etymon, its siblings under the same roots.
    func relatives(of family: Family) -> [Family] {
        let roots = family.isRoot ? [family.key] : family.roots
        var seen: Set<String> = [family.key]
        var found: [Family] = []
        for root in roots {
            if seen.insert(root).inserted, let own = families[root] { found.append(own) }
            for child in children[root] ?? [] where seen.insert(child).inserted {
                if let other = families[child] { found.append(other) }
            }
        }
        return found
    }
}

/// What the Lab shows for a word's roots.
struct RootReading: Sendable {
    struct Step: Sendable, Identifiable {
        let family: RootIndex.Family
        /// The words in the writer's languages from this family, nearest first.
        let siblings: [RhymeHit]
        var id: String { family.key }
    }

    /// The classical words it came from, each with its own siblings.
    var etyma: [Step] = []
    /// The deeper roots, each with the words from its other etyma.
    var roots: [Step] = []

    var isEmpty: Bool { etyma.isEmpty && roots.isEmpty }
}

extension Engine {
    /// The roots behind a word, and its relatives through them, in the languages in play.
    /// `forced` reads the text in the language the writer chose; `family` is the key of a
    /// classical word stepped onto in the sphere, read as exactly that family.
    func roots(of text: String, scope: Scope, forced: Language? = nil, family key: String? = nil) -> RootReading {
        guard let roots = rootIndex else { return RootReading() }
        var own = Set<String>()
        var families: [RootIndex.Family] = []
        if let key, let family = roots.family(key) {
            families = [family]
        } else {
            if let rhymes, let query = rhymes.query(text, as: forced, active: scope.languages) {
                for (typed, language) in zip(query.words, query.languages) {
                    // Hindi and Gujarati typed in Roman letters ("samajh") are looked up in
                    // their own script (समझ), which is how the dictionary keeps them.
                    let word = language.isIndic ? rhymes.lexicon.pronounce(typed, as: language).entry.map { rhymes.lexicon.word($0) } ?? typed : typed
                    own.insert(language.code + ":" + word)
                    families += roots.families(of: word, in: language)
                }
            }
            // A classical form typed as itself: a reconstruction (*lewk-), Greek, or a
            // Sanskrit root with its virama (बुध्). A plain modern-looking word is never read
            // as a Latin one, or "love" would grow a Latin origin.
            if families.isEmpty, RootIndex.looksClassical(text) { families = roots.families(named: text) }
        }
        var reading = RootReading()
        var seenRoots = Set<String>(), seenEtyma = Set<String>()
        for family in families {
            if family.isRoot {
                guard seenRoots.insert(family.key).inserted else { continue }
                reading.roots.append(RootReading.Step(family: family, siblings: hits(rootSiblings(family, roots: roots), excluding: own, scope: scope)))
            } else {
                guard seenEtyma.insert(family.key).inserted else { continue }
                reading.etyma.append(RootReading.Step(family: family, siblings: hits(family.members, excluding: own, scope: scope)))
                for key in family.roots where seenRoots.insert(key).inserted {
                    if let root = roots.family(key) {
                        reading.roots.append(RootReading.Step(family: root, siblings: hits(rootSiblings(root, roots: roots), excluding: own, scope: scope)))
                    }
                }
            }
        }
        return reading
    }

    /// Every word under a root: its own members and those of each etymon growing from it,
    /// commonest first within each (the file orders them), at most a few hundred.
    private func rootSiblings(_ root: RootIndex.Family, roots: RootIndex) -> [(language: Language, word: String)] {
        var found = Array(root.members.prefix(80))
        for etymon in roots.relatives(of: root) where found.count < 240 {
            found += etymon.members.prefix(12)
        }
        return found
    }

    /// The words as hits, the writer's languages taking turns so that a root shared across
    /// languages shows all of them in its first few, not a page of English.
    private func hits(_ members: [(language: Language, word: String)], excluding own: Set<String>, scope: Scope, limit: Int = 60) -> [RhymeHit] {
        guard let rhymes else { return [] }
        var seen = own
        var byLanguage: [Language: [RhymeHit]] = [:]
        for (language, word) in members where scope.languages.contains(language) && (byLanguage[language]?.count ?? 0) < limit && seen.insert(language.code + ":" + word).inserted {
            let said = rhymes.lexicon.pronounce(word, as: language)
            let roman = language.isIndic ? (said.entry.map { rhymes.lexicon.roman($0) } ?? "") : ""
            let gloss = said.entry.map { rhymes.lexicon.gloss($0) } ?? ""
            byLanguage[language, default: []].append(RhymeHit(word: word, language: language, score: said.entry == nil ? 0.5 : 1,
                                                               syllables: said.prons.first?.syllableCount ?? 0, tier: 0,
                                                               roman: roman == word ? "" : roman, gloss: gloss))
        }
        // Within a language, words the lexicon knows first (they can be rhymed and stepped
        // through), keeping the file's commonest-first order.
        for language in byLanguage.keys {
            byLanguage[language] = byLanguage[language]!.enumerated().sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }.map(\.element)
        }
        var found: [RhymeHit] = []
        var round = 0
        while found.count < byLanguage.values.reduce(0, { $0 + $1.count }) {
            for language in scope.languages {
                if let list = byLanguage[language], round < list.count { found.append(list[round]) }
            }
            round += 1
        }
        return found
    }
}
