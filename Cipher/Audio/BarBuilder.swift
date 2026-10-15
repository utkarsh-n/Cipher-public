import Foundation

/// Lays the words heard in a recording out as bars, the way the writer would have typed them:
/// one line per breath of the vocal, broken where the singer paused or the sentence ended.
enum BarBuilder {
    struct Bar: Sendable, Equatable {
        let text: String
        /// Seconds into the recording.
        let start: Double
    }

    /// The longest bar worth keeping on one line, in words. Rap runs about eight to twelve
    /// words a bar; a line past this is two bars the singer did not breathe between.
    static let fullBar = 13

    static func bars(from words: [HeardWord]) -> [Bar] {
        guard !words.isEmpty else { return [] }
        // The singer's own pauses set the threshold: a break is a gap well above the usual
        // one between words, but never shorter than a quarter of a second.
        let gaps = zip(words.dropFirst(), words).map { max(0, $0.start - $1.end) }.sorted()
        let typical = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
        let pause = max(0.25, typical * 3)

        var bars: [Bar] = []
        var current: [String] = []
        var start = words[0].start

        func close() {
            let line = tidy(current.joined(separator: " "))
            if !line.isEmpty { bars.append(Bar(text: line, start: start)) }
            current = []
        }

        for (index, word) in words.enumerated() {
            if current.isEmpty { start = word.start }
            current.append(word.text)
            let next = index + 1 < words.count ? words[index + 1] : nil
            guard let next else { break }
            let gap = next.start - word.end
            let ended = word.text.last.map { ".!?।".contains($0) } ?? false
            let paused = word.text.last.map { ",;:—".contains($0) } ?? false
            // A bar ends where the singer breathes, where the sentence ends, or at a comma once
            // the line has the length of a bar; never later than a bar and a half.
            if (gap >= pause && current.count >= 2) || (ended && current.count >= 3) || (paused && current.count >= 6) || current.count >= fullBar {
                close()
            }
        }
        close()
        return bars
    }

    /// Bars read as lyrics, not prose: no full stops at the end, a capital to start.
    static func tidy(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".。।".contains(last) { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return "" }
        return first.uppercased() + text.dropFirst()
    }
}
