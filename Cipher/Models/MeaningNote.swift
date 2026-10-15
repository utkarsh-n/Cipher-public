import Foundation
import SwiftData

/// A saved answer from Claude about what a word means and evokes, so asking twice is free.
@Model
final class MeaningNote {
    /// "language:word".
    @Attribute(.unique) var key: String
    var payload: Data
    var createdAt: Date

    init(key: String, payload: Data) {
        self.key = key
        self.payload = payload
        self.createdAt = .now
    }
}
