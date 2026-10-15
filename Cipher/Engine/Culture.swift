import Foundation

/// The four worlds the culture index is drawn from, and everywhere else: works from beyond
/// them (the Arabic or Turkish song a Bollywood number was built on) appear only as relatives.
enum Culture: String, Sendable, CaseIterable, Identifiable {
    case us, india = "in", spanish = "es", french = "fr", world = "xx"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .us: "English-language"
        case .india: "Indian"
        case .spanish: "Spanish-language"
        case .french: "French-language"
        case .world: "From elsewhere"
        }
    }

    /// The cultures behind a writer's languages, in the same order of preference.
    static func order(for languages: [Language]) -> [Culture] {
        var order: [Culture] = []
        for language in languages {
            let culture: Culture = switch language {
            case .english: .us
            case .hindi, .gujarati: .india
            case .spanish: .spanish
            case .french: .french
            }
            if !order.contains(culture) { order.append(culture) }
        }
        return order
    }
}

/// A film, show, channel, sporting occasion, piece of writing or song.
struct Work: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable {
        case film, tv, channel, sport, book, song

        var label: String {
            switch self {
            case .film: "film"
            case .tv: "television"
            case .channel: "channel"
            case .sport: "sport"
            case .book: "writing"
            case .song: "song"
            }
        }

        var symbol: String {
            switch self {
            case .film: "film"
            case .tv: "tv"
            case .channel: "antenna.radiowaves.left.and.right"
            case .sport: "trophy"
            case .book: "book"
            case .song: "music.note"
            }
        }
    }

    let id: Int
    let kind: Kind
    let culture: Culture
    let year: Int?
    /// 0...1: how prominent the work is, within its own culture and medium and overall.
    let weight: Double
    let title: String
    /// The title in the culture's own language, when that differs.
    let nativeTitle: String
    let maker: String

    /// The year as people write it: "1975", or "300 BC" for the epics.
    var yearLabel: String? { year.map { $0 < 0 ? "\(-$0) BC" : String($0) } }

    var caption: String { yearLabel.map { "\(title) (\($0))" } ?? title }
}

struct WorkDetail: Sendable {
    struct Theme: Sendable, Hashable {
        let phrase: String
        let weight: Double
    }

    struct Relative: Sendable, Identifiable {
        /// Where a link between two works was found.
        enum Source: String, Sendable {
            case wikipedia = "w", wikidata = "d", musicBrainz = "m", itwofs = "i"

            var name: String {
                switch self {
                case .wikipedia: "Wikipedia"
                case .wikidata: "Wikidata"
                case .musicBrainz: "MusicBrainz"
                case .itwofs: "ItwoFS.com"
                }
            }

            /// Where the link can be checked; ItwoFS's licence asks for the link back beside each use.
            var url: URL? {
                switch self {
                case .itwofs: URL(string: "https://www.itwofs.com/")
                case .musicBrainz: URL(string: "https://musicbrainz.org/")
                default: nil
                }
            }
        }

        let work: Work
        /// "remake of", "inspired by", "samples", "sampled by", "cover of", "kindred", ...
        let relation: String
        let strength: Double
        var source: Source?

        var id: Int { work.id }

        /// A link between songs, or a song and its film: sampling, covers, versions, borrowing.
        /// Films and books have relatives of their own (remakes, adaptations) and keep them apart.
        func isMusical(from work: Work) -> Bool {
            (work.kind == .song || self.work.kind == .song) && relation != "kindred" && relation != "counterpart"
        }
    }

    let work: Work
    let summary: String
    /// The lists and prizes that single it out.
    let canon: [String]
    let themes: [Theme]
    /// Recurring images and metaphors inside the work.
    let motifs: [String]
    /// What the work has come to stand for.
    let meaning: String
    let mood: [String]
    let relatives: [Relative]
    /// How many times the work has been sampled, covered, re-versioned or borrowed from, all of
    /// them (the row keeps only its strongest relatives).
    let timesTaken: Int
}

/// How a word touches a work.
enum CultureRole: UInt8, Sendable {
    /// Literal: it is named for the word.
    case named
    /// Figurative: the word is one of its themes, motifs or meanings.
    case about
    /// Subjective: the word is how it feels.
    case feeling
}

/// How much each kind of connection counts when works are ranked. The writer sets these.
struct CultureWeights: Sendable, Equatable {
    enum Era: String, Sendable, CaseIterable, Identifiable {
        case any, early, classic, modern, recent

        var id: String { rawValue }

        var label: String {
            switch self {
            case .any: "Any era"
            case .early: "Before 1960"
            case .classic: "1960 to 1989"
            case .modern: "1990 to 2009"
            case .recent: "2010 on"
            }
        }

        var years: ClosedRange<Int>? {
            switch self {
            case .any: nil
            case .early: 0...1959
            case .classic: 1960...1989
            case .modern: 1990...2009
            case .recent: 2010...3000
            }
        }
    }

    /// Literal: the work is named for the word.
    var literal = 1.0
    /// Figurative: the word is among its themes, motifs or what it stands for.
    var figurative = 0.85
    /// Subjective: the word is its mood.
    var subjective = 0.6
    /// Works from this era count in full; others are marked down.
    var era = Era.any
    /// The weakest kinship worth showing between two works, 0...1.
    var kinship = 0.4

    func weight(_ role: CultureRole) -> Double {
        switch role {
        case .named: literal
        case .about: figurative
        case .feeling: subjective
        }
    }

    func weight(year: Int?) -> Double {
        guard let years = era.years else { return 1 }
        guard let year else { return 0.6 }
        return years.contains(max(0, year)) ? 1 : 0.4
    }
}

struct CultureHit: Identifiable, Sendable {
    let work: Work
    let role: CultureRole
    let score: Double
    /// The theme or phrase that matched, when it was not the title.
    let via: String

    var id: Int { work.id }
}

struct UsageLine: Identifiable, Sendable {
    let id: Int
    let text: String
    let year: Int?
    let title: String
    let author: String
    let language: Language
}

/// Everything the culture index knows about a word.
struct CultureView: Sendable {
    var named: [CultureHit] = []
    var about: [CultureHit] = []
    var feeling: [CultureHit] = []
    /// How much of the matching work falls in each decade: (1970, share of the total).
    var decades: [(decade: Int, share: Double)] = []
    /// The word in use, from public-domain writing.
    var lines: [UsageLine] = []
    /// Ideas that run with this one across the corpus: (theme, 0...1 strength).
    var neighbours: [(theme: String, weight: Double)] = []

    var isEmpty: Bool { named.isEmpty && about.isEmpty && feeling.isEmpty && lines.isEmpty && neighbours.isEmpty }
}

/// The culture index: tens of thousands of works with their themes and relatives, and a
/// concordance of public-domain writing. Loaded on first use, off the main thread, and kept
/// apart from the rhyme engine so that a culture lookup never holds up a rhyme.
actor CultureStore {
    /// A row: the work, and its line of the file, split into fields only when the work is opened
    /// (holding every row's fields split would cost tens of megabytes once songs are in).
    private struct Record {
        let work: Work
        let line: Substring

        var fields: [Substring] { line.split(separator: "\t", omittingEmptySubsequences: false) }
        var isEmpty: Bool { line.isEmpty }
    }

    private struct Posting {
        let work: Int32
        let role: CultureRole
        let weight: Float
    }

    private struct ThemeNode {
        let phrase: String
        let count: Int
        let neighbours: [(theme: String, weight: Double)]
    }

    private var records: [Record] = []
    private var index: [String: [Posting]] = [:]
    /// Titles of two words or more by their words in order ("lose yourself"), to spot a title
    /// written into a bar.
    private var titles: [String: [Int32]] = [:]
    /// Keyed by the theme's content words, so "forbidden love" and "Forbidden Love" meet.
    private var themes: [String: ThemeNode] = [:]
    private var lines: LineIndex?
    private var loaded = false

    private static let noise: Set<String> = [
        "the", "of", "and", "a", "an", "in", "to", "for", "on", "at", "by", "with", "from", "or", "as", "is", "its", "it",
        "la", "le", "les", "el", "los", "las", "de", "du", "des", "un", "une", "y", "et", "ka", "ki", "ke", "film", "films",
        "series", "novel", "book", "american", "indian", "french", "spanish", "television", "based", "about",
    ]

    func load(works: URL?, lines linesURL: URL?, themes themesURL: URL? = nil) {
        guard !loaded else { return }
        loaded = true
        lines = linesURL.flatMap { try? LineIndex(contentsOf: $0) }
        if let themesURL, let text = try? String(contentsOf: themesURL, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count >= 3 else { continue }
                let near: [(String, Double)] = fields[2].split(separator: "|").compactMap { entry in
                    guard let colon = entry.lastIndex(of: ":") else { return nil }
                    return (String(entry[..<colon]), Double(entry[entry.index(after: colon)...]) ?? 0)
                }
                themes[CultureStore.tokens(String(fields[0])).joined(separator: " ")] = ThemeNode(phrase: String(fields[0]), count: Int(fields[1]) ?? 0, neighbours: near)
            }
        }
        guard let works, let text = try? String(contentsOf: works, encoding: .utf8) else { return }

        for (row, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 15, let kind = Work.Kind(rawValue: String(fields[1])), let culture = Culture(rawValue: String(fields[2])) else {
                // Keep rows aligned with the file: relatives point at line numbers.
                records.append(Record(work: Work(id: row, kind: .book, culture: .us, year: nil, weight: 0, title: "", nativeTitle: "", maker: ""), line: ""))
                continue
            }
            let work = Work(
                id: row, kind: kind, culture: culture, year: Int(fields[3]), weight: (Double(fields[4]) ?? 0) / 100,
                title: String(fields[5]), nativeTitle: String(fields[6]), maker: String(fields[7])
            )
            records.append(Record(work: work, line: line))

            let id = Int32(row)
            func add(_ text: Substring, _ role: CultureRole, _ weight: Double) {
                let tokens = CultureStore.tokens(String(text))
                guard !tokens.isEmpty else { return }
                // A one-word theme is that word; a word inside a long phrase is only part of it.
                let share = Float(weight / Double(tokens.count).squareRoot())
                for token in tokens { index[token, default: []].append(Posting(work: id, role: role, weight: share)) }
            }
            add(fields[5], .named, 1)
            add(fields[6], .named, 1)
            if kind != .sport, kind != .channel {
                for title in [fields[5], fields[6]] where !title.isEmpty {
                    let words = CultureStore.titleWords(title)
                    if (2...8).contains(words.count) { titles[words.joined(separator: " "), default: []].append(id) }
                }
            }
            for theme in fields[10].split(separator: "|") {
                let parts = theme.split(separator: ":")
                if let phrase = parts.first { add(phrase, .about, parts.count > 1 ? Double(parts[1]) ?? 0.6 : 0.6) }
            }
            for motif in fields[11].split(separator: "|") { add(motif, .about, 0.7) }
            add(fields[12], .about, 0.6)
            for mood in fields[13].split(separator: "|") {
                // A mood the tagging pass gave counts in full; one inferred from genre carries its own weight.
                let parts = mood.split(separator: ":")
                if let phrase = parts.first { add(phrase, .feeling, parts.count > 1 ? Double(parts[1]) ?? 0.9 : 0.9) }
            }
            add(fields[8], .about, 0.3)
        }
    }

    /// Lowercased content words with plurals folded, so "gangsters" finds "gangster".
    static func tokens(_ text: String) -> [String] {
        var seen = Set<String>()
        return Tokenizer.words(in: text).compactMap { word in
            let token = stem(word)
            return token.count > 1 && !noise.contains(token) && seen.insert(token).inserted ? token : nil
        }
    }

    private static func stem(_ word: String) -> String {
        guard word.allSatisfy(\.isASCII), word.count > 3 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("sses") || word.hasSuffix("ches") || word.hasSuffix("shes") || word.hasSuffix("xes") { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") { return String(word.dropLast()) }
        return word
    }

    /// What the index holds for a word. `ideas` are the English senses to search by (the word
    /// itself for English, its dictionary meanings otherwise); `word` is what was typed, which
    /// is also tried against titles and against the concordance in its own language.
    func view(ideas: [String], word: String, language: Language, cultures: [Culture], weights: CultureWeights = CultureWeights()) -> CultureView {
        var view = CultureView()
        let terms = ideas + [word]
        var best: [Int32: (role: CultureRole, score: Double, via: String)] = [:]
        for (position, term) in terms.enumerated() {
            let tokens = CultureStore.tokens(term)
            guard !tokens.isEmpty else { continue }
            // Later ideas are secondary senses; they count for less.
            let rank = position == 0 || position == terms.count - 1 ? 1.0 : 0.8
            var matched: [Int32: [CultureRole: (score: Double, hits: Int)]] = [:]
            for token in tokens {
                for posting in index[token] ?? [] {
                    var entry = matched[posting.work, default: [:]][posting.role] ?? (0, 0)
                    entry.score += Double(posting.weight)
                    entry.hits += 1
                    matched[posting.work, default: [:]][posting.role] = entry
                }
            }
            for (work, roles) in matched {
                let record = records[Int(work)]
                guard cultures.contains(record.work.culture) else { continue }
                for (role, entry) in roles {
                    // Every word of the query has to be there for a full match.
                    let coverage = Double(min(entry.hits, tokens.count)) / Double(tokens.count)
                    let score = weights.weight(role) * weights.weight(year: record.work.year) * min(1.2, entry.score)
                        * coverage * coverage * rank * (0.35 + 0.65 * record.work.weight)
                    if score > (best[work]?.score ?? 0) { best[work] = (role, score, role == .named ? "" : term) }
                }
            }
        }

        var decades: [Int: Double] = [:]
        var hits: [CultureRole: [CultureHit]] = [:]
        for (work, match) in best where match.score >= 0.12 {
            let record = records[Int(work)]
            hits[match.role, default: []].append(CultureHit(work: record.work, role: match.role, score: match.score, via: match.via))
            if let year = record.work.year, year > 1000 { decades[year / 10 * 10, default: 0] += match.score }
        }
        func top(_ role: CultureRole) -> [CultureHit] {
            // The best of each culture, so that no single one fills the list.
            var taken: [Culture: Int] = [:]
            return (hits[role] ?? []).sorted { $0.score != $1.score ? $0.score > $1.score : $0.work.id < $1.work.id }.filter { hit in
                taken[hit.work.culture, default: 0] += 1
                return taken[hit.work.culture]! <= 12
            }
        }
        view.named = top(.named)
        view.about = top(.about)
        view.feeling = top(.feeling)
        let total = decades.values.reduce(0, +)
        if total > 0 { view.decades = decades.sorted { $0.key < $1.key }.map { ($0.key, $0.value / total) } }
        view.lines = lines?.lines(for: Tokenizer.clean(word), language: language) ?? []
        view.neighbours = neighbours(of: terms)
        return view
    }

    /// Titles of songs, films, shows and books written into a line, longest and best known
    /// first, with how many times each has been sampled, covered or borrowed from: what in a bar
    /// has already been used.
    func titled(in line: String, cultures: [Culture], limit: Int = 3) -> [(work: Work, taken: Int)] {
        let words = CultureStore.titleWords(Substring(line))
        guard words.count >= 2 else { return [] }
        var found: [(work: Work, length: Int)] = []
        var seen = Set<Int32>()
        // The same song can sit in several rows (a single and its composition); one is enough.
        var named = Set<String>()
        for length in stride(from: min(8, words.count), through: 2, by: -1) {
            for start in 0...(words.count - length) {
                let key = words[start..<(start + length)].joined(separator: " ")
                for row in titles[key] ?? [] where seen.insert(row).inserted {
                    let work = records[Int(row)].work
                    guard cultures.contains(work.culture) || work.culture == .world else { continue }
                    if named.insert(work.kind.rawValue + "|" + key + "|" + work.maker.lowercased()).inserted { found.append((work, length)) }
                }
            }
        }
        return found
            .sorted { $0.length != $1.length ? $0.length > $1.length : ($0.work.kind == .song) != ($1.work.kind == .song) ? $0.work.kind == .song : $0.work.weight > $1.work.weight }
            .prefix(limit)
            .map { ($0.work, detail($0.work.id)?.timesTaken ?? 0) }
    }

    /// A title's words for matching, lowercased, without the regex tokenizer's cost (it runs for
    /// every title at load): letters, digits and apostrophes, split on everything else.
    static func titleWords(_ text: Substring) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "\u{2019}") }.map { $0.replacingOccurrences(of: "\u{2019}", with: "'") }
    }

    /// The themes that run with any of these ideas, strongest first.
    func neighbours(of terms: [String], limit: Int = 12) -> [(theme: String, weight: Double)] {
        var best: [String: Double] = [:]
        var asked = Set<String>()
        for term in terms {
            let key = CultureStore.tokens(term).joined(separator: " ")
            guard !key.isEmpty, asked.insert(key).inserted, let node = themes[key] else { continue }
            for (theme, weight) in node.neighbours where CultureStore.tokens(theme).joined(separator: " ") != key {
                best[theme] = max(best[theme] ?? 0, weight)
            }
        }
        return best.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map { ($0.key, $0.value) }
    }

    func detail(_ id: Int, kinship: Double = 0) -> WorkDetail? {
        guard records.indices.contains(id), !records[id].isEmpty else { return nil }
        let record = records[id]
        let fields = record.fields
        guard fields.count >= 15 else { return nil }
        func list(_ field: Substring) -> [String] { field.split(separator: "|").map(String.init) }
        let relatives: [WorkDetail.Relative] = fields[14].split(separator: "|").compactMap { entry in
            // line:relation:strength, and where the link was found when that is known.
            let parts = entry.split(separator: ":")
            guard parts.count >= 3, let other = Int(parts[0]), records.indices.contains(other), !records[other].isEmpty else { return nil }
            let strength = Double(parts[2]) ?? 0.5
            let source = parts.count > 3 ? WorkDetail.Relative.Source(rawValue: String(parts[3])) : nil
            return strength >= kinship ? WorkDetail.Relative(work: records[other].work, relation: String(parts[1]), strength: strength, source: source) : nil
        }
        return WorkDetail(
            work: record.work, summary: String(fields[8]), canon: list(fields[9]),
            themes: fields[10].split(separator: "|").compactMap { theme in
                let parts = theme.split(separator: ":")
                return parts.first.map { WorkDetail.Theme(phrase: String($0), weight: parts.count > 1 ? Double(parts[1]) ?? 0.6 : 0.6) }
            },
            motifs: list(fields[11]), meaning: String(fields[12]),
            mood: fields[13].split(separator: "|").compactMap { $0.split(separator: ":").first.map(String.init) }, relatives: relatives,
            timesTaken: fields.count > 15 ? Int(fields[15]) ?? 0 : 0
        )
    }

    /// The themes a work shares with each of its relatives from another culture: the ideas that
    /// travelled with a sample, a cover or a borrowed tune. Keyed by the relative's id.
    func carried(_ id: Int) -> [Int: [String]] {
        guard let own = detail(id) else { return [:] }
        let mine = Set(own.themes.prefix(12).map(\.phrase))
        var found: [Int: [String]] = [:]
        for relative in own.relatives where relative.work.culture != own.work.culture {
            guard let theirs = detail(relative.work.id) else { continue }
            let shared = theirs.themes.prefix(12).map(\.phrase).filter(mine.contains)
            if !shared.isEmpty { found[relative.work.id] = Array(shared.prefix(4)) }
        }
        return found
    }

    /// A few of the most relevant works for some words, as plain text for a Claude prompt.
    func references(for ideas: [String], cultures: [Culture], limit: Int = 6) -> [String] {
        let found = view(ideas: ideas, word: ideas.first ?? "", language: .english, cultures: cultures)
        let hits = (found.named.prefix(3) + found.about.prefix(4) + found.feeling.prefix(1)).sorted { $0.score > $1.score }.prefix(limit)
        return hits.compactMap { hit in
            guard let detail = detail(hit.work.id) else { return nil }
            var line = "\(hit.work.caption), \(hit.work.culture.name) \(hit.work.kind.label)"
            if !detail.themes.isEmpty { line += "; themes: " + detail.themes.prefix(4).map(\.phrase).joined(separator: ", ") }
            if !detail.meaning.isEmpty { line += "; stands for: " + detail.meaning }
            if let relative = detail.relatives.first(where: { $0.work.culture != hit.work.culture }) {
                line += "; \(relative.relation) \(relative.work.caption) (\(relative.work.culture.name))"
            }
            return line
        }
    }
}

/// A concordance of public-domain writing: "word<TAB>year<TAB>language<TAB>title<TAB>author<TAB>line",
/// sorted by word, mapped into memory and binary-searched in place.
final class LineIndex: @unchecked Sendable {
    private let data: NSData
    private let bytes: UnsafePointer<UInt8>
    private let count: Int

    init(contentsOf url: URL) throws {
        data = try NSData(contentsOf: url, options: .mappedIfSafe)
        bytes = data.bytes.assumingMemoryBound(to: UInt8.self)
        count = data.length
    }

    /// The start of the line containing or following `position`.
    private func lineStart(after position: Int) -> Int {
        var cursor = position
        while cursor < count, bytes[cursor] != 10 { cursor += 1 }
        return min(count, cursor + 1)
    }

    /// -1, 0 or 1 as the key of the line at `start` sorts before, equal to or after `key`.
    private func compare(_ start: Int, _ key: [UInt8]) -> Int {
        var cursor = start
        for byte in key {
            if cursor >= count || bytes[cursor] == 9 { return -1 }
            if bytes[cursor] != byte { return bytes[cursor] < byte ? -1 : 1 }
            cursor += 1
        }
        return cursor < count && bytes[cursor] == 9 ? 0 : 1
    }

    func lines(for word: String, language: Language, limit: Int = 8) -> [UsageLine] {
        let key = Array(word.utf8)
        guard !key.isEmpty, count > 0 else { return [] }
        // Find the first line whose key is not before the word.
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            let start = mid == 0 ? 0 : lineStart(after: mid - 1)
            if start >= count || compare(start, key) >= 0 { high = mid } else { low = mid + 1 }
        }
        var cursor = low == 0 ? 0 : lineStart(after: low - 1)
        var found: [UsageLine] = []
        while cursor < count, compare(cursor, key) == 0, found.count < limit * 3 {
            let end = lineStart(after: cursor)
            let fields = String(decoding: UnsafeBufferPointer(start: bytes + cursor, count: max(0, end - cursor - 1)), as: UTF8.self)
                .split(separator: "\t", omittingEmptySubsequences: false)
            if fields.count >= 6, let lineLanguage = Language(code: String(fields[2])) {
                found.append(UsageLine(id: cursor, text: String(fields[5]), year: Int(fields[1]), title: String(fields[3]), author: String(fields[4]), language: lineLanguage))
            }
            cursor = end
        }
        // The word's own language first, then the rest, oldest first within each.
        return Array(found.sorted { a, b in
            if (a.language == language) != (b.language == language) { return a.language == language }
            return (a.year ?? 9999) < (b.year ?? 9999)
        }.prefix(limit))
    }
}
