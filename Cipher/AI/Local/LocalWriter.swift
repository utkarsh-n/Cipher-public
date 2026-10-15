import Foundation

/// Bars written by the model on the phone the way the rest of Cipher works: the engine proposes
/// the sounds, the model writes, and the engine checks every draft before the writer sees it.
/// A small model cannot hear rhyme (it reads tokens, not sounds), so it writes several drafts and
/// the engine keeps the ones that land.
@MainActor
enum LocalWriter {
    enum Job: Sendable {
        /// The bar after the anchor line.
        case next
        /// The anchor line, rewritten.
        case punchUp
        /// The anchor line is a pile of fragments (images, rhymes, "a : b ::" analogies, chains);
        /// make one bar of them.
        case forge
    }

    struct Request: Sendable {
        var job: Job
        /// The verse up to and including the anchor.
        var verse: String
        var anchor: String
        /// The line whose ending the new bar should rhyme with, when there is one.
        var rhymeTarget: String?
        var syllables: Int?
        /// Words the engine found for the target sound.
        var palette: [String]
        /// Works from the culture index related to the anchor.
        var references: [String]
        var direction: String
        var languages: [Language]
    }

    /// A draft and what the engine heard in it.
    struct Draft: Sendable {
        let text: String
        let verdict: LineVerdict
        let score: Double
    }

    static let system = """
    You are the lyric engine inside Cipher, a songwriting app. The writer mixes English, Hindi, Gujarati, \
    Spanish and French, and writes Hindi and Gujarati either in their own script or in Roman letters. \
    Match their language mix, script, voice and register; profanity and dark imagery are fine when the \
    song calls for it. Rhyme by sound. Never explain. Write only the lyric, inside <bar></bar>.
    """

    /// The user turn for a request: short and concrete, which is what a small model follows.
    static func prompt(_ request: Request) -> String {
        let verse = request.verse.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(8).joined(separator: "\n")
        var parts: [String] = []
        if !verse.isEmpty, request.job != .forge || verse != request.anchor {
            parts.append("The verse so far:\n\(verse)")
        }
        switch request.job {
        case .next:
            parts.append("Write the bar that comes right after \"\(request.anchor)\". It should follow on in sense.")
        case .punchUp:
            parts.append("Rewrite this bar with denser rhyme, a sharper image and a tighter rhythm, keeping what it says: \"\(request.anchor)\"")
        case .forge:
            parts.append("Turn these fragments into one coherent bar that keeps their images and sounds: \(request.anchor)")
        }
        if let target = request.rhymeTarget, let end = target.split(separator: " ").last {
            var rhyme = "It must end on a word that rhymes with \"\(end.trimmingCharacters(in: .punctuationCharacters))\""
            let words = request.palette.prefix(10)
            if !words.isEmpty { rhyme += ", for example: " + words.joined(separator: ", ") }
            parts.append(rhyme + ".")
        }
        if let syllables = request.syllables { parts.append("About \(syllables) syllables.") }
        if !request.references.isEmpty {
            parts.append("References you may use if they fit: " + request.references.prefix(3).joined(separator: "; "))
        }
        let direction = request.direction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direction.isEmpty { parts.append("Direction: \(direction)") }
        return parts.joined(separator: "\n\n")
    }

    /// Writes `drafts` drafts, has the engine judge each, and hands back the best `count` as
    /// suggestions, best first. `onUpdate` sees the ranking grow as drafts come in.
    static func suggestions(_ request: Request, model: LocalModel, engine: Engine, count: Int = 3, drafts: Int = 4,
                            onUpdate: ([Suggestion]) -> Void = { _ in }) async throws -> [Suggestion] {
        try await model.ensureWriter()
        let user = prompt(request)
        let expected = scripts(of: request.verse.isEmpty ? request.anchor : request.verse)
        var kept: [Draft] = []
        for index in 0..<drafts {
            try Task.checkCancellation()
            // Later drafts run hotter, for range.
            let temperature = Float(0.75 + 0.1 * Double(index))
            let raw = try await model.write(system: system, user: user, prefill: "<bar>", maxTokens: 72, temperature: temperature, stop: "</bar>")
            guard let text = clean(raw), !kept.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) else { continue }
            let verdict = await engine.judge(text, against: request.rhymeTarget, languages: request.languages)
            kept.append(Draft(text: text, verdict: verdict, score: score(verdict, text: text, request: request, expected: expected)))
            kept.sort { $0.score > $1.score }
            onUpdate(kept.prefix(count).map { suggestion(for: $0, request: request) })
        }
        return kept.prefix(count).map { suggestion(for: $0, request: request) }
    }

    /// Continues a verse by `bars` bars in its own rhyme scheme, one bar at a time, each the best of
    /// `drafts` drafts the engine has checked. `lines` are the verse's lines so far with the
    /// rhyme letters the editor gave them. `onBar` sees each bar as it is chosen.
    static func finish(lines: [(text: String, scheme: String?)], bars: Int = 4, drafts: Int = 3, syllables: Int?,
                       direction: String, languages: [Language], model: LocalModel, engine: Engine,
                       onBar: (String) -> Void = { _ in }) async throws -> [String] {
        try await model.ensureWriter()
        var verse = lines.map(\.text)
        var letters = lines.map(\.scheme)
        // The verse's habit, read from its last rhymed lines: couplets (AABB) unless it alternates (ABAB).
        let rhymed = letters.compactMap { $0 }.suffix(4)
        let alternating = rhymed.count >= 4 && Array(rhymed)[0] == Array(rhymed)[2] && Array(rhymed)[1] == Array(rhymed)[3] && Array(rhymed)[0] != Array(rhymed)[1]
        var written: [String] = []
        for _ in 0..<bars {
            try Task.checkCancellation()
            let count = verse.count
            var target: String?
            if alternating {
                if count >= 2 { target = verse[count - 2] }
            } else if count >= 1 {
                // A couplet's second line rhymes with its first; a line that opens a couplet is free.
                let last = letters[count - 1]
                let pairedAbove = count >= 2 && last != nil && letters[count - 2] == last
                if !pairedAbove { target = verse[count - 1] }
            }
            var palette: [String] = []
            if let target { palette = await engine.palette(for: target, context: target, scope: Scope(languages: languages)) }
            let request = Request(job: .next, verse: verse.joined(separator: "\n"), anchor: verse.last ?? "", rhymeTarget: target,
                                  syllables: syllables, palette: palette, references: [], direction: direction, languages: languages)
            let best = try await suggestions(request, model: model, engine: engine, count: 1, drafts: drafts).first
            guard let bar = best?.text else { break }
            verse.append(bar)
            // The new line takes its target's letter, or a fresh one when it opens a couplet.
            if let target, let index = verse.dropLast().lastIndex(of: target) {
                letters.append(letters[index] ?? "x\(verse.count)")
            } else {
                letters.append("n\(verse.count)")
            }
            written.append(bar)
            onBar(bar)
        }
        return written
    }

    /// The lyric inside the model's answer: one line, no tags, quotes or labels.
    static func clean(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "<bar>", with: "").replacingOccurrences(of: "</bar>", with: "")
        if let tag = text.range(of: "<") { text = String(text[..<tag.lowerBound]) }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard var line = lines.first else { return nil }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'*-•· "))
        return line.count >= 3 ? line : nil
    }

    /// How well a draft does what was asked, as the engine hears it: the rhyme first, then the
    /// pocket (syllables), the script, and for a forge the fragments it kept.
    static func score(_ verdict: LineVerdict, text: String, request: Request, expected: [Script: Double]) -> Double {
        var score = 0.0
        if request.rhymeTarget != nil { score += 3 * verdict.rhyme + verdict.tail }
        if let target = request.syllables, target > 0 {
            score += max(0, 1 - Double(abs(verdict.syllables - target)) / Double(target))
        }
        // Script: the share of letters in the scripts the verse is written in.
        let shared = expected.reduce(0.0) { $0 + min($1.value, verdict.scripts[$1.key] ?? 0) }
        score += 1.5 * shared
        if request.job == .forge {
            let fragments = request.anchor.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 3 }
            if !fragments.isEmpty {
                let lowered = text.lowercased()
                score += Double(fragments.filter { lowered.contains($0) }.count) / Double(fragments.count)
            }
        }
        return score
    }

    /// The draft as Assist shows it, with a note on what the engine heard.
    static func suggestion(for draft: Draft, request: Request) -> Suggestion {
        var notes: [String] = []
        if let target = request.rhymeTarget, let end = target.split(separator: " ").last {
            let theirs = end.trimmingCharacters(in: .punctuationCharacters)
            switch draft.verdict.rhyme {
            case 0.99...: notes.append("“\(draft.verdict.endWord)” rhymes with “\(theirs)”" + (draft.verdict.tail >= 0.85 ? "" : ", slant"))
            case 0.6..<0.99: notes.append("“\(draft.verdict.endWord)” is a loose rhyme for “\(theirs)”")
            default: notes.append("ends on “\(draft.verdict.endWord)”, off the rhyme")
            }
        }
        notes.append("\(draft.verdict.syllables) syllables")
        notes.append("written on this phone")
        return Suggestion(text: draft.text, note: notes.joined(separator: " · "))
    }

    private static func scripts(of text: String) -> [Script: Double] {
        var counts: [Script: Int] = [:]
        for character in text where character.isLetter { counts[Script.of(String(character)), default: 0] += 1 }
        let total = counts.values.reduce(0, +)
        return total == 0 ? [:] : counts.mapValues { Double($0) / Double(total) }
    }
}
