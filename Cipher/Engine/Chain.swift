import Foundation

/// A chain written into the lyric in the writer's own notation: "pagal : paa's gal : pascal :".
/// The sphere follows it and writes back to it.
struct ChainLine: Equatable, Sendable {
    let items: [String]
    /// The line ends with a separator: the next step is being looked for.
    let open: Bool
    /// The line in the text, newline excluded.
    let range: NSRange

    var head: String { items.last ?? "" }

    /// Reads a chain off a line. ":" and "::" separate steps (so do "->" and "→"); a colon
    /// between digits (3:30) is not a separator; an analogy ("a : b ::") is not a chain.
    static func parse(_ line: String, range: NSRange) -> ChainLine? {
        guard !line.contains("://"), AnalogyQuery.parse(line) == nil else { return nil }
        var text = line.replacingOccurrences(of: "::", with: ":").replacingOccurrences(of: "->", with: ":").replacingOccurrences(of: "→", with: ":")
        // A colon with digits on both sides is a time, not a step.
        text = text.replacingOccurrences(of: #"(?<=\d):(?=\d)"#, with: "\u{1}", options: .regularExpression)
        guard text.contains(":") else { return nil }
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "\u{1}", with: ":").trimmingCharacters(in: .whitespaces)
        }
        let open = pieces.last?.isEmpty == true
        let items = pieces.filter { !$0.isEmpty }
        guard items.count >= 2 || (items.count == 1 && open) else { return nil }
        // Steps are words and phrases, film and song titles among them. A section label
        // ("Hook:", "Verse 2: ...") or a label and a sentence ("Chorus: I been on the run") is a
        // heading, and a step of more than twelve words is prose.
        let lengths = items.map { $0.split(separator: " ").count }
        guard lengths.allSatisfy({ $0 <= 12 }) else { return nil }
        if isHeading(items[0]), items.count <= 2 { return nil }
        if items.count == 2, !open, lengths[1] > 3 { return nil }
        return ChainLine(items: items, open: open, range: range)
    }

    /// Song-section labels, which end in a colon without being a chain.
    private static let headings: Set<String> = ["hook", "chorus", "verse", "intro", "outro", "bridge", "pre-chorus", "prechorus",
                                                 "refrain", "interlude", "breakdown", "bars", "mukhda", "antara", "coro", "estribillo",
                                                 "couplet", "pont", "puente", "skit", "part", "section"]

    private static func isHeading(_ item: String) -> Bool {
        let words = item.lowercased().split(separator: " ")
        guard let first = words.first, words.count <= 3 else { return false }
        return headings.contains(String(first)) && words.dropFirst().allSatisfy { $0.allSatisfy { $0.isNumber || $0 == "." } || ["one", "two", "three", "1", "2", "3"].contains(String($0)) }
    }

    /// The chain as the writer writes it, left open for the next step.
    static func text(of items: [String], open: Bool) -> String {
        items.joined(separator: " : ") + (open ? " :" : "")
    }
}
