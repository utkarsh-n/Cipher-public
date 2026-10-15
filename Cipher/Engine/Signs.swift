import Foundation

/// One word of a bar as it would be signed.
struct SignToken: Identifiable, Sendable, Hashable {
    let id: Int
    /// The word in the bar this stands for.
    let word: String
    /// Signs in Formal SignWriting. More than one means the word is fingerspelled, a letter each.
    let signs: [String]
    let fingerspelled: Bool
    /// The English sense the sign was chosen by, when that is not the word itself.
    let sense: String
}

/// ASL signs keyed by English gloss, from the SignPuddle community dictionary (extracted by
/// Tools/lexgen into signs.tsv). Manual-alphabet letters are stored under "#a"..."#z".
final class SignDictionary: Sendable {
    private let table: [String: [String]]

    /// English words ASL does not sign in running speech.
    static let unsigned: Set<String> = ["a", "an", "the", "is", "are", "am", "was", "were", "be", "been", "to", "of"]

    init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var table: [String: [String]] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            if fields.count >= 2 { table[fields[0]] = Array(fields.dropFirst()) }
        }
        self.table = table
    }

    func sign(for gloss: String) -> String? { table[gloss]?.first }

    /// One handshape per letter; anything that is not a-z is skipped.
    func fingerspell(_ text: String) -> [String] {
        text.lowercased().folding(options: .diacriticInsensitive, locale: nil).compactMap { table["#\($0)"]?.first }
    }
}
