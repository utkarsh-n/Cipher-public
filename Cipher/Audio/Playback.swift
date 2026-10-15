import AVFoundation
import Foundation
import Observation

/// Plays a transcribed song's recording so the writer can follow the bars as they are sung.
@MainActor
@Observable
final class Playback {
    private(set) var isPlaying = false
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    var isLoaded: Bool { player != nil }

    func load(_ url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        time = 0
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            isPlaying = true
            tick()
        }
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(duration, seconds))
        time = player.currentTime
    }

    func stop() {
        ticker?.cancel()
        player?.stop()
        isPlaying = false
    }

    /// Keeps `time` fresh while playing, and notices when the recording runs out.
    private func tick() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                self.time = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// "3:07" for 187 seconds.
    static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}
