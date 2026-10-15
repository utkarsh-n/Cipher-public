import Foundation

/// How a written line sounds, as the engine hears it: what the on-device model's drafts are
/// checked against before the writer sees them.
struct LineVerdict: Sendable {
    /// The line's last word the lexicon could pronounce, and the language it was read in.
    let endWord: String
    let endLanguage: Language?
    let syllables: Int
    /// The share of the line's letters in each script.
    let scripts: [Script: Double]
    /// How strongly the line's end rhymes with the target's, 0...1; 1 means the editor would give
    /// both lines the same rhyme letter.
    let rhyme: Double
    /// The stricter similarity of the two rhyme tails, 0...1: it tells a perfect rhyme from a slant.
    let tail: Double
}

extension Engine {
    /// The engine's reading of `line`, and how its end rhymes with `target`'s. These are the
    /// tests VerseAnalyzer uses to give two lines the same rhyme letter.
    func judge(_ line: String, against target: String?, languages: [Language]) -> LineVerdict {
        let end = lineEnd(line, languages: languages)
        var rhyme = 0.0, tail = 0.0
        if let target, let mine = end, let theirs = lineEnd(target, languages: languages) {
            if Tokenizer.clean(mine.word).lowercased() != Tokenizer.clean(theirs.word).lowercased() {
                let full = Similarity.tails(mine.pron.rhymeTail, theirs.pron.rhymeTail)
                let lastVowel = Similarity.tails(mine.pron.tail(fromLastVowels: 1), theirs.pron.tail(fromLastVowels: 1))
                rhyme = min(1, max(full / 0.6, lastVowel / 0.78))
                tail = full
            }
        }
        return LineVerdict(endWord: end?.word ?? "", endLanguage: end?.language, syllables: end?.syllables ?? 0,
                           scripts: Self.scripts(of: line), rhyme: rhyme, tail: tail)
    }

    private struct LineEnd {
        let word: String
        let language: Language
        let pron: Pron
        let syllables: Int
    }

    /// The line's last pronounceable word, read in the language the detector gives it in context,
    /// and the syllables of the whole line.
    private func lineEnd(_ line: String, languages: [Language]) -> LineEnd? {
        guard let rhymes else { return nil }
        let source = line as NSString
        let matches = Tokenizer.pattern.matches(in: line, range: NSRange(location: 0, length: source.length))
        let tokens = matches.map { Tokenizer.clean(source.substring(with: $0.range)) }
        var breaks = Set<Int>()
        for index in matches.indices.dropLast() {
            let gap = NSRange(location: NSMaxRange(matches[index].range), length: matches[index + 1].range.location - NSMaxRange(matches[index].range))
            if source.substring(with: gap).contains(where: \.isPunctuation) { breaks.insert(index) }
        }
        let detected = rhymes.detector.detect(tokens, breaks: breaks, active: languages)
        var last: (word: String, language: Language, pron: Pron)?
        var syllables = 0
        for (index, token) in tokens.enumerated() where !token.isEmpty {
            guard let pron = rhymes.lexicon.pronounce(token, as: detected[index]).prons.first, !pron.isEmpty else { continue }
            syllables += pron.syllableCount
            last = (token, detected[index], pron)
        }
        guard let last else { return nil }
        return LineEnd(word: last.word, language: last.language, pron: last.pron, syllables: syllables)
    }

    private static func scripts(of line: String) -> [Script: Double] {
        var counts: [Script: Int] = [:]
        for character in line where character.isLetter {
            counts[Script.of(String(character)), default: 0] += 1
        }
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return counts.mapValues { Double($0) / Double(total) }
    }
}
