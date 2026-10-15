import AVFoundation
import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

/// A recording ready to be written out: where its copy lives and what it is called.
struct Recording: Sendable, Equatable {
    let url: URL
    let title: String
    let artist: String

    /// The file name inside the app's audio folder.
    var fileName: String { url.lastPathComponent }
}

enum ImportError: LocalizedError {
    case protected(String)
    case notReadable
    case denied

    var errorDescription: String? {
        switch self {
        case .protected(let title): "“\(title)” is an Apple Music stream, which apps are not allowed to read, so it cannot be listened to; only tracks you own as files (bought, ripped or added from your computer) can be."
        case .notReadable: "That recording could not be read."
        case .denied: "Cipher was not allowed to read your music library. You can change that in Settings."
        }
    }
}

enum MediaImport {
    /// A copy of a music-library track in the app's own folder, as an M4A. Only a track the
    /// writer owns as a file has readable audio; a stream from Apple Music does not.
    static func copy(_ item: MPMediaItem) async throws -> Recording {
        let title = item.title ?? "Untitled"
        guard let source = item.assetURL, !item.hasProtectedAsset else { throw ImportError.protected(title) }
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw ImportError.notReadable }
        let destination = Song.audioFolder.appendingPathComponent(UUID().uuidString + ".m4a")
        try await session.export(to: destination, as: .m4a)
        return Recording(url: destination, title: title, artist: item.artist ?? "")
    }

    /// A copy of an audio file the writer picked, in the app's own folder.
    static func copy(file url: URL) throws -> Recording {
        let destination = Song.audioFolder.appendingPathComponent(UUID().uuidString + "." + (url.pathExtension.isEmpty ? "m4a" : url.pathExtension))
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: url, to: destination)
        let title = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        return Recording(url: destination, title: title, artist: "")
    }

    /// The track playing in Music right now, if there is one and the library may be read.
    static var nowPlaying: MPMediaItem? {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return nil }
        return MPMusicPlayerController.systemMusicPlayer.nowPlayingItem
    }

    static func requestLibraryAccess() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }
}

/// The music library's own picker. Every track is offered: one whose audio the app cannot
/// read (an Apple Music stream) still has its words looked up by name.
struct MusicPicker: UIViewControllerRepresentable {
    let onPick: (MPMediaItem?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        picker.showsCloudItems = true
        picker.showsItemsWithProtectedAssets = true
        picker.prompt = "Pick a track to write out"
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: MPMediaPickerController, context: Context) {}

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let onPick: (MPMediaItem?) -> Void

        init(onPick: @escaping (MPMediaItem?) -> Void) { self.onPick = onPick }

        func mediaPicker(_ picker: MPMediaPickerController, didPickMediaItems collection: MPMediaItemCollection) {
            onPick(collection.items.first)
        }

        func mediaPickerDidCancel(_ picker: MPMediaPickerController) { onPick(nil) }
    }
}

/// The Files picker, for a recording kept anywhere on the phone or in iCloud Drive.
struct AudioFilePicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void

        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls.first) }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPick(nil) }
    }
}
