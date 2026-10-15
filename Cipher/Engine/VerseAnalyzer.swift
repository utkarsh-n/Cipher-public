import Foundation

struct LineInfo: Sendable, Equatable {
    let range: NSRange
    let syllables: Int
    /// End-rhyme letter within the stanza (A, B, ...); nil for blank lines.
    let scheme: String?
}

struct Highlight: Sendable, Equatable {
    let range: NSRange
    /// Index into the highlighter palette; words sharing a sound share a colour.
    let color: Int
}

struct VerseAnalysis: Sendable, Equatable {
    /// UTF-16 length of the text this describes, so the editor can tell when it has gone stale.
    var length = 0
    var lines: [LineInfo] = []
    var highlights: [Highlight] = []
    var bars = 0
    var syllables = 0
    /// How many words of the verse are in each language.
    var languages: [Language: Int] = [:]
}

/// Reads a verse the way a rhyme-scheme highlighter does: syllables per line, end-rhyme
/// letters, and colour groups for every word that shares a vowel sound with a neighbour.
/// It works on sound alone, so a Hindi word can light up against an English one.
struct VerseAnalyzer: Sendable {
    let lexicon: Lexicon
    let detector: LanguageDetector

    /// Too common to be worth colouring unless they end the line.
    static let fillers: [Language: Set<String>] = [
        .english: ["a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "is", "it", "i", "you", "he", "she",
                   "we", "they", "my", "your", "me", "that", "this", "with", "for", "as", "was", "be", "are", "but",
                   "so", "if", "not", "no", "do", "i'm", "it's", "im", "its", "from", "by", "up", "got", "get"],
        .hindi: ["है", "हैं", "का", "की", "के", "को", "से", "में", "पर", "और", "ये", "वो", "तो", "भी", "ने", "हो", "था", "थी",
                 "hai", "hain", "ka", "ki", "ke", "ko", "se", "mein", "me", "par", "aur", "ye", "yeh", "wo", "woh",
                 "to", "toh", "bhi", "ne", "ho", "tha", "thi"],
        .gujarati: ["છે", "ને", "ના", "ની", "નું", "નો", "માં", "થી", "અને", "તો", "પણ", "એ", "આ",
                    "che", "chhe", "ne", "na", "ni", "nu", "no", "ma", "thi", "ane", "to", "pan", "e", "aa"],
        .spanish: ["el", "la", "los", "las", "de", "del", "que", "y", "en", "un", "una", "es", "a", "al", "lo", "se",
                   "me", "te", "mi", "tu", "su", "por", "con", "no", "si"],
        .french: ["le", "la", "les", "de", "des", "du", "un", "une", "et", "est", "je", "tu", "il", "elle", "on",
                  "ne", "pas", "que", "qui", "à", "au", "en", "ce", "se", "me", "te", "mon", "ma", "ton", "ta"],
    ]

    /// Grammar words: they rhyme with plenty and mean nothing, so themed results leave them out.
    static let functionWords: Set<String> = fillers[.english]!.union([
        "some", "all", "yours", "our", "ours", "nor", "more", "any", "than", "then", "them", "their",
        "there", "here", "what", "which", "who", "whom", "when", "where", "why", "how", "been", "were",
        "has", "have", "had", "does", "did", "will", "would", "could", "should", "can", "may", "might",
        "must", "shall", "one", "two", "us", "him", "her", "his", "hers", "these", "those", "such",
        "very", "too", "also", "just", "only", "even", "into", "onto", "over", "under", "about",
        "after", "before", "again", "anymore", "am", "an", "each", "both", "few", "most", "other",
        "however", "although", "though", "still", "yet", "because", "while", "until", "since", "whether",
    ])

    private struct Word {
        let range: NSRange
        let text: String
        let language: Language
        let pron: Pron
    }

    func analyze(_ text: String, active: [Language]) -> VerseAnalysis {
        let source = text as NSString
        var lines: [(range: NSRange, words: [Word])] = []
        var languages: [Language: Int] = [:]
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let matches = Tokenizer.pattern.matches(in: text, range: range)
            let tokens = matches.map { Tokenizer.clean(source.substring(with: $0.range)) }
            var breaks = Set<Int>()
            for index in matches.indices.dropLast() {
                let gap = NSRange(location: NSMaxRange(matches[index].range), length: matches[index + 1].range.location - NSMaxRange(matches[index].range))
                if source.substring(with: gap).contains(where: { $0.isPunctuation }) { breaks.insert(index) }
            }
            let detected = detector.detect(tokens, breaks: breaks, active: active)
            var words: [Word] = []
            for (index, match) in matches.enumerated() where !tokens[index].isEmpty {
                guard let pron = lexicon.pronounce(tokens[index], as: detected[index]).prons.first, !pron.isEmpty else { continue }
                words.append(Word(range: match.range, text: tokens[index], language: detected[index], pron: pron))
                languages[detected[index], default: 0] += 1
            }
            lines.append((range, words))
        }

        var analysis = VerseAnalysis(length: source.length)
        analysis.languages = languages
        var colors: [Pron: Int] = [:]
        var stanza: [Int] = []
        func closeStanza() {
            guard !stanza.isEmpty else { return }
            let schemes = scheme(for: stanza.map { lines[$0].words.last?.pron })
            for (offset, lineIndex) in stanza.enumerated() {
                let line = lines[lineIndex]
                let syllables = line.words.reduce(0) { $0 + $1.pron.syllableCount }
                analysis.lines.append(LineInfo(range: line.range, syllables: syllables, scheme: schemes[offset]))
                analysis.bars += 1
                analysis.syllables += syllables
            }
            analysis.highlights += highlights(in: stanza.map { lines[$0].words }, colors: &colors)
            stanza = []
        }
        for (index, line) in lines.enumerated() {
            if line.words.isEmpty {
                closeStanza()
                analysis.lines.append(LineInfo(range: line.range, syllables: 0, scheme: nil))
            } else {
                stanza.append(index)
            }
        }
        closeStanza()
        analysis.lines.sort { $0.range.location < $1.range.location }
        return analysis
    }

    private func scheme(for endings: [Pron?]) -> [String?] {
        var families: [Pron] = []
        return endings.map { ending in
            guard let ending else { return nil }
            let tail = ending.rhymeTail
            let last = ending.tail(fromLastVowels: 1)
            let match = families.firstIndex { family in
                Similarity.tails(tail, family.rhymeTail) >= 0.6
                    || Similarity.tails(last, family.tail(fromLastVowels: 1)) >= 0.78
            }
            let index = match ?? families.count
            if match == nil { families.append(ending) }
            return String(UnicodeScalar(UInt8(65 + index % 26)))
        }
    }

    private func highlights(in stanza: [[Word]], colors: inout [Pron: Int]) -> [Highlight] {
        struct Member { let range: NSRange; let endsLine: Bool }
        var groups: [Pron: [Member]] = [:]
        var order: [Pron] = []
        for words in stanza {
            for (index, word) in words.enumerated() {
                let endsLine = index == words.count - 1
                guard endsLine || Self.fillers[word.language]?.contains(word.text) != true else { continue }
                // Vowel families rather than exact vowels, so "qué" colours with "day".
                let key = word.pron.rhymeTail.filter(\.isVowel).map(\.vowelKey)
                guard !key.isEmpty else { continue }
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(Member(range: word.range, endsLine: endsLine))
            }
        }
        var result: [Highlight] = []
        for key in order {
            let members = groups[key]!
            // One shared vowel is weak evidence; ask for a line ending or a run of three.
            let qualifies = key.count >= 2
                ? members.count >= 2
                : members.count >= 3 || (members.count == 2 && members.contains(where: \.endsLine))
            guard qualifies else { continue }
            let color = colors[key] ?? colors.count
            colors[key] = color
            result += members.map { Highlight(range: $0.range, color: color) }
        }
        return result
    }
}
