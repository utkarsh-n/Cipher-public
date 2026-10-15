import Foundation

/// Works out which language each word of a bar is in. Scripts settle Hindi and Gujarati when
/// they are written natively; for Roman letters it weighs how common the word is in each
/// language against what the rest of the line is doing, since "main", "to" and "me" are words
/// in several of them.
struct LanguageDetector: Sendable {
    let lexicon: Lexicon

    struct Reading: Sendable {
        let language: Language
        /// 0...1: how ordinary a word this is in that language.
        let weight: Double
    }

    /// The little words of each language. Several are shared ("to", "tu", "me", "the"): listing
    /// one under every language it belongs to makes it equally at home in each, so the line
    /// around it decides.
    private static let markers: [Language: Set<String>] = [
        .english: ["the", "and", "of", "you", "that", "it", "for", "with", "this", "my", "your", "they", "have",
                   "got", "i'm", "don't", "can't", "what", "when", "just", "like", "was", "are", "but", "not",
                   "to", "me", "a", "is", "in", "on", "so", "do", "no", "he", "we", "be", "at", "an", "as", "or",
                   "if", "us", "am", "up", "i"],
        .hindi: ["hai", "hain", "nahi", "nahin", "kya", "kyun", "kyu", "aur", "mera", "meri", "mere", "tera", "teri",
                 "tere", "tum", "hum", "apna", "apni", "tha", "thi", "hoon", "hun", "raha", "rahi", "rahe", "mujhe",
                 "tujhe", "kuch", "bahut", "bohot", "yeh", "woh", "lekin", "agar", "bhi", "kaise", "kahan", "abhi",
                 "phir", "sirf", "ka", "ki", "ke", "ko", "se", "mein", "par",
                 "to", "tu", "hi", "ho", "ye", "wo", "the", "me", "main", "na", "ab", "jo", "ek", "ne", "pe"],
        .gujarati: ["che", "chhe", "cho", "chho", "chu", "chhu", "nathi", "ane", "pan", "hu", "hun", "tame", "tamaro",
                    "taru", "tari", "maru", "mari", "mara", "mane", "tane", "apde", "aapde", "shu", "su", "kem",
                    "kyare", "tyare", "hatu", "hati", "karu", "kare", "thay", "gayu", "joie", "pachi", "have",
                    "bahu", "badhu", "badha", "koi", "kai", "nu", "ni", "na", "no", "ma", "thi", "mate", "sathe",
                    "to", "tu", "e", "aa", "ne", "j"],
        .spanish: ["el", "la", "los", "las", "de", "del", "que", "y", "en", "un", "una", "es", "por", "con", "para",
                   "como", "pero", "más", "su", "al", "lo", "se", "mi", "tú", "te", "yo", "ya", "muy", "qué",
                   "cuando", "porque", "esta", "está", "estoy", "soy", "eres", "tengo", "quiero", "nada", "todo",
                   "tu", "me", "a", "no", "si", "o"],
        .french: ["le", "les", "des", "du", "une", "et", "est", "je", "il", "elle", "nous", "vous", "ils", "qui",
                  "ne", "pas", "pour", "dans", "sur", "avec", "mais", "où", "ça", "c'est", "j'ai", "suis", "mon",
                  "ma", "mes", "ton", "ta", "tes", "ce", "cette", "comme", "plus", "tout", "très", "bien", "quand",
                  "moi", "toi", "lui", "au", "aux", "ces", "sont", "être", "avoir", "fait", "j'suis",
                  "tu", "me", "te", "se", "a", "on", "en", "la", "de", "un", "si"],
    ]

    /// Letters only one of the two accented languages uses.
    private static let spanishOnly = Set("ñáíóú¿¡")
    private static let frenchOnly = Set("çèêàùœâîôûëï")

    /// Every language (of those in play) in which the token is a word, commonest reading first.
    func readings(of token: String, among active: [Language]) -> [Reading] {
        switch Script.of(token) {
        case .devanagari: return [Reading(language: .hindi, weight: 1)]
        case .gujarati: return [Reading(language: .gujarati, weight: 1)]
        default: break
        }
        var found: [Reading] = []
        for language in active {
            let weight: Double
            switch language {
            case .english:
                if let entry = lexicon.bestEntry(forWord: token, in: .english) {
                    weight = lexicon.tier(entry) > 1 ? 0.02 : max(0.15, Double(lexicon.freq(entry)) / 200)
                } else {
                    let said = lexicon.pronounce(token, as: .english)
                    weight = said.known && !said.prons.isEmpty ? 0.2 : 0
                }
            case .spanish, .french:
                var entry = lexicon.bestEntry(forWord: token, in: language)
                if entry == nil, language == .french, let apostrophe = token.firstIndex(of: "'"),
                   FrenchG2P.clitics[String(token[..<apostrophe])] != nil {
                    entry = lexicon.bestEntry(forWord: String(token[token.index(after: apostrophe)...]), in: .french)
                }
                weight = entry.map { max(0.1, Double(lexicon.freq($0)) / 200) } ?? 0
            case .hindi, .gujarati:
                // Only confident spellings count here; a loose match is not evidence of language.
                weight = lexicon.romanMatch(token, in: language, loose: false).map { max(0.05, Double(lexicon.freq($0)) / 200) * 0.9 } ?? 0
            }
            var boosted = weight
            if Self.markers[language]?.contains(token) == true { boosted = max(boosted, 0.6) + 0.4 }
            if language == .spanish, token.contains(where: Self.spanishOnly.contains) { boosted += 1 }
            if language == .french, token.contains(where: Self.frenchOnly.contains) { boosted += 1 }
            if boosted > 0 { found.append(Reading(language: language, weight: boosted)) }
        }
        return found.sorted { $0.weight > $1.weight }
    }

    /// One language per token. Every word votes for the languages it could be, and an
    /// ambiguous word goes with its neighbours: nearby words count for more than distant ones,
    /// because writers switch language mid-line. `active` breaks ties in the writer's order.
    /// `breaks` marks words followed by punctuation; a clause boundary is where writers switch.
    func detect(_ tokens: [String], breaks: Set<Int> = [], active: [Language]) -> [Language] {
        guard let fallback = active.first else { return tokens.map { _ in .english } }
        var readings = tokens.map { readings(of: $0, among: active) }

        // Nobody writes a language in its own script and in Roman letters in the same line,
        // so a line with Devanagari in it has no romanized Hindi (and likewise Gujarati).
        for (script, language) in [(Script.devanagari, Language.hindi), (.gujarati, .gujarati)] where tokens.contains(where: { Script.of($0) == script }) {
            for index in readings.indices where Script.of(tokens[index]) == .latin && readings[index].count > 1 {
                readings[index].removeAll { $0.language == language }
            }
        }

        // What each word says about the line, before its neighbours weigh in.
        let ballots: [[Language: Double]] = readings.map { options in
            let total = options.reduce(0) { $0 + $1.weight }
            guard total > 0 else { return [:] }
            return Dictionary(uniqueKeysWithValues: options.map { ($0.language, options.count == 1 ? 1 + $0.weight : $0.weight / total) })
        }
        func preference(_ language: Language) -> Double {
            Double(active.count - (active.firstIndex(of: language) ?? active.count)) * 0.02
        }
        /// Support for each language around a position, fading with distance. Crossing
        /// punctuation counts as two extra words of distance.
        func support(at position: Int) -> [Language: Double] {
            var votes: [Language: Double] = [:]
            for (other, ballot) in ballots.enumerated() where other != position {
                let span = min(other, position)..<max(other, position)
                let fade = 1 / Double(span.count + 2 * span.filter(breaks.contains).count)
                for (language, vote) in ballot { votes[language, default: 0] += vote * fade }
            }
            return votes
        }

        return readings.enumerated().map { position, options in
            let votes = support(at: position)
            guard let first = options.first else {
                // An unknown word is read the way the words around it are.
                return votes.max { ($0.value + preference($0.key)) < ($1.value + preference($1.key)) }?.key ?? fallback
            }
            if options.count == 1 { return first.language }
            // How ordinary the word is in a language counts twice over: "hola" stays Spanish in
            // an English line, while "main" or "to", common in several, go with the line.
            let strongest = first.weight
            func score(_ option: Reading) -> Double {
                let fit = option.weight / strongest
                return ((votes[option.language] ?? 0) + 1 + preference(option.language)) * fit * fit
            }
            return options.max { score($0) < score($1) }?.language ?? first.language
        }
    }

    /// The languages a typed word or phrase could be read in, likeliest first.
    func languages(for text: String, active: [Language]) -> [Language] {
        let tokens = Tokenizer.words(in: text)
        guard !tokens.isEmpty else { return [] }
        if tokens.count == 1 {
            let found = readings(of: tokens[0], among: active)
            let ranked = found.sorted { a, b in
                let near = abs(a.weight - b.weight) < 0.2 * max(a.weight, b.weight)
                if near { return (active.firstIndex(of: a.language) ?? 99) < (active.firstIndex(of: b.language) ?? 99) }
                return a.weight > b.weight
            }
            return ranked.map(\.language)
        }
        let phrases = Tokenizer.phrases(in: text)
        var counts: [Language: Int] = [:]
        for language in detect(phrases.words, breaks: phrases.breaks, active: active) { counts[language, default: 0] += 1 }
        return counts.sorted { a, b in
            a.value != b.value ? a.value > b.value : (active.firstIndex(of: a.key) ?? 99) < (active.firstIndex(of: b.key) ?? 99)
        }.map(\.key)
    }
}
