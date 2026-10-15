import AVFoundation
import CoreML
import Foundation
import SoundAnalysis

/// What a window of the recording sounded like to the vocal emotion classifier.
struct EmotionWindow: Sendable {
    let start: Double
    let end: Double
    /// Label -> confidence, 0...1.
    let scores: [String: Double]
}

/// The emotion the voice carries, window by window, from a sound classifier trained on acted
/// emotional speech (see Tools/emotion). Absent until that model is bundled as VocalEmotion.
final class EmotionClassifier: NSObject, SNResultsObserving, @unchecked Sendable {
    static var modelURL: URL? { Bundle.main.url(forResource: "VocalEmotion", withExtension: "mlmodelc") }
    static var isAvailable: Bool { modelURL != nil }

    /// Rough valence and arousal of each label, so the classifier's view can be blended with the words'.
    static let valence: [String: Double] = ["happy": 0.8, "calm": 0.45, "surprised": 0.2, "neutral": 0, "sad": -0.6, "fearful": -0.5, "angry": -0.7, "disgust": -0.7]
    static let arousal: [String: Double] = ["angry": 0.9, "surprised": 0.8, "happy": 0.75, "fearful": 0.7, "disgust": 0.5, "neutral": 0.3, "sad": 0.2, "calm": 0.15]

    private var windows: [EmotionWindow] = []
    private var failure: Error?

    /// Every window of the file, in order. Empty when no model is bundled.
    static func classify(_ url: URL) async throws -> [EmotionWindow] {
        guard let modelURL else { return [] }
        let model = try MLModel(contentsOf: modelURL)
        let request = try SNClassifySoundRequest(mlModel: model)
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
        request.overlapFactor = 0.5
        let observer = EmotionClassifier()
        let analyzer = try SNAudioFileAnalyzer(url: url)
        try analyzer.add(request, withObserver: observer)
        await analyzer.analyze()
        if let failure = observer.failure { throw failure }
        return observer.windows
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        let start = classification.timeRange.start.seconds
        let end = start + classification.timeRange.duration.seconds
        var scores: [String: Double] = [:]
        for item in classification.classifications { scores[item.identifier.lowercased()] = item.confidence }
        windows.append(EmotionWindow(start: start, end: end, scores: scores))
    }

    func request(_ request: SNRequest, didFailWithError error: Error) { failure = error }

    func requestDidComplete(_ request: SNRequest) {}
}
