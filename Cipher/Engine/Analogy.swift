import Foundation
import NaturalLanguage

/// "smoke : fire ::" — the writer sets a relation and the app finds other pairs that hold it.
struct AnalogyQuery: Equatable, Sendable {
    let a: String
    let b: String
    /// The left side of the answering pair, when the writer has given it ("smoke : fire :: vapor :").
    let c: String?

    /// Reads "smoke : fire ::", "smoke:fire::vapor:", "smoke : fire :: vapor : ?" from a line.
    /// The analogy may follow other words on the line; only its own words count.
    static func parse(_ line: String) -> AnalogyQuery? {
        guard let double = line.range(of: "::", options: .backwards), line.components(separatedBy: "::").count == 2 else { return nil }
        let before = line[..<double.lowerBound]
        // "a : b ::" and nothing more on the left; a longer trail of colons is a chain, not an analogy.
        guard before.filter({ $0 == ":" }).count == 1 else { return nil }
        guard let single = before.range(of: ":", options: .backwards) else { return nil }
        let a = tail(of: before[..<single.lowerBound])
        let b = word(before[single.upperBound...])
        guard !a.isEmpty, !b.isEmpty else { return nil }
        var rest = line[double.upperBound...].trimmingCharacters(in: .whitespaces)
        // "smoke : fire :: vapor : mist" is finished; only an open right side asks for pairs.
        if let colon = rest.firstIndex(of: ":") {
            let answer = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !answer.isEmpty && answer != "?" { return nil }
            rest = String(rest[..<colon])
        }
        while let last = rest.last, ":?".contains(last) { rest.removeLast(); rest = rest.trimmingCharacters(in: .whitespaces) }
        let c = word(rest[...])
        return AnalogyQuery(a: a, b: b, c: c.isEmpty ? nil : c)
    }

    /// The last word or two before the colon: "I spit smoke" gives "smoke".
    private static func tail(of text: Substring) -> String {
        let words = Tokenizer.words(in: String(text))
        return words.last ?? ""
    }

    private static func word(_ text: Substring) -> String {
        let words = Tokenizer.words(in: String(text))
        return words.prefix(2).joined(separator: " ")
    }
}

/// A pair that holds the writer's relation.
struct Analogy: Identifiable, Sendable, Hashable {
    let left: String
    let right: String
    /// 0 for a pair that mirrors the given one tightly, 1 for a lateral leap.
    let looseness: Double
    let score: Double

    var id: String { left + " : " + right }
    var text: String { "\(left) : \(right)" }
}

extension Semantics {
    /// Pairs that stand in the same relation as A to B. With C given, the words that answer it.
    ///
    /// The relation is the arrow from A to B in meaning-space. A candidate pair is scored on
    /// how parallel its own arrow runs (the heart of an analogy) and how plainly its words sit
    /// where the arrow points. Strictness decides how far from A the left-hand words may roam
    /// and how parallel the arrow has to be.
    func analogies(_ query: AnalogyQuery, looseness: Looseness, limit: Int = 24) -> [Analogy] {
        guard let embedding, let va = vector(for: query.a), let vb = vector(for: query.b) else { return [] }
        let relation = zip(vb, va).map { $0 - $1 }
        guard norm(relation) > 0.05 else { return [] }
        let given = Set([query.a, query.b, query.c ?? ""].flatMap { $0.lowercased().split(separator: " ").map(String.init) })
        // Arrows in this embedding run parallel at modest cosines: a true answer scores about
        // 0.10 to 0.25 (woman for king : queen :: man : ?), so the floors sit low.
        let parallelFloor: Double = switch looseness {
        case .strict: 0.14
        case .balanced: 0.09
        case .loose: 0.05
        }

        func cosine(_ x: [Double], _ y: [Double]) -> Double {
            let lengths = norm(x) * norm(y)
            return lengths > 0 ? zip(x, y).reduce(0) { $0 + $1.0 * $1.1 } / lengths : 0
        }
        /// Candidate vectors come raw from the embedding; the query sides are unit length.
        func unit(_ word: String) -> [Double]? {
            guard let raw = embedding.vector(for: word) else { return nil }
            let length = norm(raw)
            return length > 0 ? raw.map { $0 / length } : nil
        }

        /// How well D completes C: its arrow from C runs parallel to the given one, and it is
        /// the same kind of thing as B (near B, and nearer B than A).
        func fit(_ vc: [Double], _ vd: [Double]) -> (parallel: Double, kind: Double) {
            let arrow = zip(vd, vc).map { $0 - $1 }
            let toB = cosine(vd, vb), toA = cosine(vd, va)
            return (cosine(arrow, relation), max(0, toB - 0.5 * toA))
        }

        func answers(for c: String, _ vc: [Double], count: Int) -> [(word: String, parallel: Double, kind: Double)] {
            let target = zip(vc, relation).map { $0 + $1 }
            var found: [(String, Double, Double)] = []
            var pool = embedding.neighbors(for: target, maximumCount: count).map(\.0)
            pool += embedding.neighbors(for: vb, maximumCount: count / 2).map(\.0)
            var seen = Set<String>()
            for word in pool where seen.insert(word).inserted && !given.contains(word) && !Self.kin(word, c) && !Self.kin(word, query.b) && !Self.kin(word, query.a) {
                guard let vd = unit(word) else { continue }
                let (parallel, kind) = fit(vc, vd)
                guard parallel >= parallelFloor else { continue }
                found.append((word, parallel, kind))
            }
            return found
        }

        if let c = query.c, let vc = vector(for: c) {
            let found = answers(for: c, vc, count: 80).map { answer in
                Analogy(left: c, right: answer.word, looseness: max(0, min(1, 1 - answer.parallel / 0.3)),
                        score: answer.parallel * 0.6 + answer.kind * 0.4)
            }
            return Array(found.sorted { $0.score > $1.score }.prefix(limit))
        }

        // Left-hand words that are the same kind of thing as A: near it, and nearer it than B.
        let reach: Int = switch looseness {
        case .strict: 30
        case .balanced: 50
        case .loose: 80
        }
        var lefts: [(String, [Double], Double)] = []
        func consider(_ word: String) {
            guard !given.contains(word), !Self.kin(word, query.a), !Self.kin(word, query.b), !lefts.contains(where: { $0.0 == word }),
                  let vc = unit(word) else { return }
            let toA = cosine(vc, va), toB = cosine(vc, vb)
            guard toA > toB else { return }
            lefts.append((word, vc, 1 - toA))
        }
        for (word, _) in embedding.neighbors(for: va, maximumCount: reach) { consider(word) }
        if looseness == .loose {
            for (hop, _) in embedding.neighbors(for: va, maximumCount: 10) {
                for (word, _) in embedding.neighbors(for: hop, maximumCount: 15) { consider(word) }
            }
        }
        var results: [Analogy] = []
        var taken = Set<String>()
        for (c, vc, stray) in lefts {
            // Each left-hand word takes its best answer that no earlier pair has used.
            let ranked = answers(for: c, vc, count: 16).sorted { ($0.parallel * 0.6 + $0.kind * 0.4) > ($1.parallel * 0.6 + $1.kind * 0.4) }
            guard let best = ranked.first(where: { !taken.contains($0.word) }) else { continue }
            taken.insert(best.word)
            // Straying from A and a weak parallel are the two ways a pair can be loose.
            let loose = max(0, min(1, 0.5 * stray / 0.5 + 0.5 * (1 - best.parallel / 0.3)))
            let score = best.parallel * 0.5 + best.kind * 0.3 + (1 - min(1, stray / 0.6)) * 0.2
            results.append(Analogy(left: c, right: best.word, looseness: loose, score: score))
        }
        return Array(results.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// "smoke" and "smokes", "smoky": the same word in another coat, which no analogy wants.
    private static func kin(_ word: String, _ other: String) -> Bool {
        let a = word.lowercased(), b = other.lowercased()
        guard a != b else { return true }
        let stem = min(a.count, b.count) >= 5 ? 4 : 3
        return a.prefix(stem) == b.prefix(stem) && abs(a.count - b.count) <= 3 && (a.hasPrefix(b.prefix(b.count - 1)) || b.hasPrefix(a.prefix(a.count - 1)))
    }
}
