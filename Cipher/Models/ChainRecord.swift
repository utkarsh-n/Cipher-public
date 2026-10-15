import Foundation
import SwiftData

/// A chain walked in the sphere, kept on the phone so it survives the app being closed and can
/// be picked up again from the history. Saved after every step.
@Model
final class ChainRecord {
    /// Where a chain was begun.
    enum Origin: String, CaseIterable {
        case sphere, editor, lab

        var symbol: String {
            switch self {
            case .sphere: "circle.hexagonpath"
            case .editor: "pencil.line"
            case .lab: "waveform"
            }
        }
    }

    @Attribute(.unique) var id: UUID
    /// Every step walked, oldest first. The first `cursor` of them are the chain as it stands;
    /// the rest were stepped back from, and come back with Forward, the way a browser's do.
    var steps: [String]
    var cursor: Int
    var createdAt: Date
    var updatedAt: Date
    /// Starred in the history: kept at the top and never tidied away.
    var starred: Bool
    /// Words pinned while walking it: attractors the sphere keeps in view.
    var pins: [String]
    var origin: String

    init(steps: [String], origin: Origin, pins: [String] = []) {
        id = UUID()
        self.steps = steps
        cursor = steps.count
        createdAt = .now
        updatedAt = .now
        starred = false
        self.pins = pins
        self.origin = origin.rawValue
    }

    var originKind: Origin { Origin(rawValue: origin) ?? .sphere }

    /// The chain as it stands.
    var chain: [String] { Array(steps.prefix(max(0, min(cursor, steps.count)))) }

    /// The whole walk, in the writer's own notation.
    var text: String { steps.joined(separator: " : ") }

    /// Worth keeping in the history: a step was taken, it was starred, or a word was pinned on it.
    var isWalked: Bool { steps.count >= 2 || starred || !pins.isEmpty }
}
