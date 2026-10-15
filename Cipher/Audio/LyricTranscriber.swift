import AVFoundation
import Foundation
import Speech

/// A word heard in a recording, and when it was sung.
struct HeardWord: Sendable, Equatable {
    let text: String
    let start: Double
    let end: Double
}

/// What the writer sees while a recording is being written out.
enum TranscriptionStage: Sendable, Equatable {
    case preparing
    /// The speech model for the language is being installed on the device (once per language).
    case downloading
    /// How much of the recording has been heard, 0...1.
    case listening(Double)
    case done
}

enum TranscriptionError: LocalizedError {
    case unavailable
    case unsupported(String)
    case denied
    case nothingHeard

    var errorDescription: String? {
        switch self {
        case .unavailable: "Speech recognition is not available on this device."
        case .unsupported(let name): "This device cannot transcribe \(name) yet."
        case .denied: "Cipher was not allowed to use speech recognition. You can change that in Settings."
        case .nothingHeard: "No words could be made out. Clear vocals or an acapella work best."
        }
    }
}

/// Writes out the words of a recording with the device's own speech recognition. Nothing
/// leaves the phone: the audio is analysed on the device, with a model Apple installs for
/// the language on first use.
actor LyricTranscriber {
    /// A language the device can listen in.
    struct Option: Identifiable, Sendable, Hashable {
        let locale: Locale
        let label: String

        var id: String { locale.identifier }
    }

    /// Which of Apple's speech models fit each of the writer's languages. Spanish takes the
    /// Mexican model, matching the Latin American sound values the rhyme engine uses.
    private static let preferred: [Language: [(String, String)]] = [
        .english: [("en_US", "English")],
        .hindi: [("hi_IN", "Hindi"), ("mul_IN", "Hindi + English")],
        .gujarati: [("gu_IN", "Gujarati")],
        .spanish: [("es_MX", "Spanish"), ("es_ES", "Spanish")],
        .french: [("fr_FR", "French")],
    ]

    /// The languages this device can transcribe, in the writer's order of preference.
    static func options(for languages: [Language]) async -> [Option] {
        var options: [Option] = []
        // Without the newer analyzer (the simulator, say), the older recognizer's languages.
        let legacy = SpeechTranscriber.isAvailable ? [] : SFSpeechRecognizer.supportedLocales().map { $0.identifier.replacingOccurrences(of: "-", with: "_") }
        for language in languages {
            for (identifier, label) in preferred[language] ?? [] where !options.contains(where: { $0.label == label }) {
                if SpeechTranscriber.isAvailable {
                    if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) {
                        options.append(Option(locale: locale, label: label))
                    }
                } else if legacy.contains(identifier) {
                    options.append(Option(locale: Locale(identifier: identifier), label: label))
                }
            }
        }
        return options
    }

    /// The words of the recording at `url`, in order, with their timing.
    func transcribe(_ url: URL, locale: Locale, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [HeardWord] {
        #if targetEnvironment(simulator)
        // The simulator has no speech recognition at all. A transcript made on the Mac and
        // dropped beside the recording as "<name>.words.json" stands in for it while testing.
        if let words = Self.sidecar(for: url) {
            progress(.listening(1))
            return words
        }
        #endif
        guard SpeechTranscriber.isAvailable else { return try await transcribeWithRecognizer(url, locale: locale, progress: progress) }
        progress(.preparing)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupported(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            progress(.downloading)
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let duration = max(1, Double(file.length) / file.processingFormat.sampleRate)
        progress(.listening(0))

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Results stream while the analyzer is still reading the file, so they are gathered
        // alongside it rather than after it.
        let gathering = Task { () -> [HeardWord] in
            var words: [HeardWord] = []
            for try await result in transcriber.results where result.isFinal {
                let text = result.text
                for run in text.runs {
                    let piece = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !piece.isEmpty else { continue }
                    let start = run.audioTimeRange?.start.seconds ?? words.last?.end ?? 0
                    let end = run.audioTimeRange?.end.seconds ?? start
                    words.append(HeardWord(text: piece, start: start, end: end))
                }
                if let last = words.last { progress(.listening(min(1, last.end / duration))) }
            }
            return words
        }
        do {
            // Cancelling the task (the sheet closed) stops the analyzer rather than letting it run on.
            try await withTaskCancellationHandler {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            try Task.checkCancellation()
        } catch {
            gathering.cancel()
            throw error
        }
        let words = try await gathering.value
        progress(.done)
        guard !words.isEmpty else { throw TranscriptionError.nothingHeard }
        return words
    }

    #if targetEnvironment(simulator)
    private static func sidecar(for url: URL) -> [HeardWord]? {
        struct Entry: Decodable { let text: String; let start: Double; let end: Double }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for candidate in try! FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) where candidate.pathExtension == "json" {
            if let data = try? Data(contentsOf: candidate), let entries = try? JSONDecoder().decode([Entry].self, from: data), !entries.isEmpty {
                return entries.map { HeardWord(text: $0.text, start: $0.start, end: $0.end) }
            }
        }
        return nil
    }
    #endif

    /// The older recognizer, for where the analyzer is missing. It may send audio to Apple
    /// and stops after about a minute, so it is the fallback, not the way.
    private func transcribeWithRecognizer(_ url: URL, locale: Locale, progress: @escaping @Sendable (TranscriptionStage) -> Void) async throws -> [HeardWord] {
        progress(.preparing)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.unsupported(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriptionError.denied }
        progress(.listening(0))
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let words: [HeardWord] = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription.segments.map {
                        HeardWord(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    })
                } else if let error {
                    finished = true
                    continuation.resume(throwing: error)
                }
            }
        }
        progress(.done)
        guard !words.isEmpty else { throw TranscriptionError.nothingHeard }
        return words
    }
}
