import Foundation
import NaturalLanguage

/// Meaning-side lookups, backed by Apple's on-device English word embedding (~57k everyday
/// words). The other languages reach it through their English glosses, which puts all five in
/// one space of meaning. Not thread-safe on its own; the Engine actor serializes access.
final class Semantics: @unchecked Sendable {
    let embedding = NLEmbedding.wordEmbedding(for: .english)
    private let tagger = NLTagger(tagSchemes: [.lemma])
    private let sentimentTagger = NLTagger(tagSchemes: [.sentimentScore])

    var isAvailable: Bool { embedding != nil }

    func knows(_ word: String) -> Bool { embedding?.contains(word) ?? false }

    /// How warm or cold a line reads, -1...1, from the system's sentiment model; nil when the
    /// model has no opinion (it knows English).
    func sentiment(of text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        sentimentTagger.string = trimmed
        let (tag, _) = sentimentTagger.tag(at: trimmed.startIndex, unit: .paragraph, scheme: .sentimentScore)
        guard let score = tag.flatMap({ Double($0.rawValue) }) else { return nil }
        return max(-1, min(1, score))
    }

    /// The dictionary form of an English word: running -> run, dogs -> dog.
    func lemma(of word: String) -> String {
        tagger.string = word
        tagger.setLanguage(.english, range: word.startIndex..<word.endIndex)
        let (tag, _) = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma)
        let lemma = tag?.rawValue.lowercased() ?? ""
        return lemma.isEmpty ? word : lemma
    }

    /// A single point in meaning-space for a word or phrase (the average of the words it knows).
    func vector(for text: String) -> [Double]? {
        guard let embedding else { return nil }
        let vectors = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .compactMap { embedding.vector(for: String($0)) }
        guard let first = vectors.first else { return nil }
        var sum = [Double](repeating: 0, count: first.count)
        var counted = 0
        for vector in vectors where vector.count == sum.count {
            let length = norm(vector)
            guard length > 0 else { continue }
            for index in sum.indices { sum[index] += vector[index] / length }
            counted += 1
        }
        // A zero vector would put NaN into every distance and neighbour search downstream.
        return counted > 0 && norm(sum) > 0 ? sum : nil
    }

    /// Distance on the same scale NLEmbedding reports: 0 identical, ~1.4 unrelated.
    func distance(from vector: [Double], to word: String) -> Double? {
        guard let other = embedding?.vector(for: word) else { return nil }
        return distance(vector, other)
    }

    func distance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return 2 }
        var dot = 0.0
        for index in a.indices { dot += a[index] * b[index] }
        let lengths = norm(a) * norm(b)
        guard lengths > 0 else { return 2 }
        return (max(0, 2 - 2 * dot / lengths)).squareRoot()
    }

    /// Associated English words, nearest first. Strict keeps only the tight cluster; loose
    /// walks out a second step (neighbours of neighbours) to reach the more lateral connections.
    func related(to text: String, looseness: Looseness, limit: Int = 120) -> [(word: String, distance: Double)] {
        guard let embedding, let origin = vector(for: text) else { return [] }
        let queryWords = Set(text.lowercased().split(separator: " ").map(String.init))
        var best: [String: Double] = [:]
        let direct = embedding.neighbors(for: origin, maximumCount: 50)
        for (word, _) in direct where !queryWords.contains(word) {
            if let d = distance(from: origin, to: word) { best[word] = d }
        }
        switch looseness {
        case .strict:
            let tight = best.filter { $0.value <= 0.95 }
            if tight.count >= 8 {
                best = tight
            } else {
                best = Dictionary(uniqueKeysWithValues: best.sorted { $0.value < $1.value }.prefix(8).map { ($0.key, $0.value) })
            }
        case .balanced:
            break
        case .loose:
            for (hop, _) in direct.prefix(12) {
                for (word, _) in embedding.neighbors(for: hop, maximumCount: 25)
                where best[word] == nil && !queryWords.contains(word) {
                    if let d = distance(from: origin, to: word), d <= 1.22 { best[word] = d }
                }
            }
        }
        return best.sorted { $0.value < $1.value }.prefix(limit).map { ($0.key, $0.value) }
    }

    /// Words that sit between two ideas: the shared ground a metaphor can stand on.
    func commonGround(_ a: String, _ b: String, limit: Int = 40) -> [(word: String, distance: Double)] {
        guard let embedding, let va = vector(for: a), let vb = vector(for: b) else { return [] }
        let excluded = Set((a + " " + b).lowercased().split(separator: " ").map(String.init))
        let la = norm(va), lb = norm(vb)
        guard la > 0, lb > 0, va.count == vb.count else { return [] }
        var midpoint = [Double](repeating: 0, count: va.count)
        for index in midpoint.indices { midpoint[index] = va[index] / la + vb[index] / lb }

        var candidates = Set(embedding.neighbors(for: midpoint, maximumCount: 50).map(\.0))
        candidates.formUnion(embedding.neighbors(for: va, maximumCount: 50).map(\.0))
        candidates.formUnion(embedding.neighbors(for: vb, maximumCount: 50).map(\.0))
        var scored: [(String, Double)] = []
        for word in candidates where !excluded.contains(word) {
            guard let da = distance(from: va, to: word), let db = distance(from: vb, to: word) else { continue }
            // A bridge word has to be near both ends, so it is only as good as its far side.
            scored.append((word, max(da, db)))
        }
        return scored.sorted { $0.1 < $1.1 }.prefix(limit).map { ($0.0, $0.1) }
    }

    func norm(_ vector: [Double]) -> Double {
        vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }
}
