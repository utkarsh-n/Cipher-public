import Foundation
import SwiftData

@Model
final class Song {
    var title: String
    var text: String
    var createdAt: Date
    var updatedAt: Date
    /// For a song transcribed from a recording: who made the track, and the audio file kept
    /// in the app's own folder so the bars can be played back.
    var artist: String = ""
    var audioFile: String = ""
    /// When each bar starts in the recording, in seconds, one entry per line of `text`.
    var barTimes: [Double] = []
    /// How the take was delivered, bar by bar (a `SongDelivery`, stored as JSON).
    var deliveryData: Data?

    init(title: String = "", text: String = "") {
        self.title = title
        self.text = text
        self.createdAt = .now
        self.updatedAt = .now
    }

    var isTranscribed: Bool { !audioFile.isEmpty }

    var delivery: SongDelivery? {
        get { deliveryData.flatMap { try? JSONDecoder().decode(SongDelivery.self, from: $0) } }
        set { deliveryData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var audioURL: URL? {
        audioFile.isEmpty ? nil : Song.audioFolder.appendingPathComponent(audioFile)
    }

    /// Where imported recordings live: Application Support, so they are backed up but never
    /// shown to the writer as documents.
    static var audioFolder: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    var firstLine: String {
        text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? "No bars yet"
    }
}
