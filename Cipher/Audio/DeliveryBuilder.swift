import Foundation

extension Engine {
    /// How warm or cold a word or phrase reads, -1...1: the sentiment model on the text, or on
    /// its English meaning for the other languages; nil when nothing can be said.
    func feel(of text: String, languages: [Language]) -> Double? {
        if let direct = semantics.sentiment(of: text) { return direct }
        guard let rhymes, let query = rhymes.query(text, active: languages) else { return nil }
        let ideas = concepts(for: query)
        guard !ideas.isEmpty else { return nil }
        return semantics.sentiment(of: ideas.prefix(3).joined(separator: ", "))
    }

    /// Reads a take: pitch, loudness, brightness and pace bar by bar from the recording, the
    /// warmth of the words from the sentiment model, and the voice's emotion from the
    /// classifier when one is bundled. `bars` are the lines of the song with when each starts;
    /// `words` are the transcriber's timed words, when there are any.
    func delivery(audio url: URL, bars: [(text: String, start: Double)], words: [HeardWord], languages: [Language]) async throws -> SongDelivery {
        // A whole track takes seconds to read; a sheet closed meanwhile should not keep the
        // engine busy with it.
        let samples = try ProsodyAnalyzer.samples(of: url)
        try Task.checkCancellation()
        let frames = ProsodyAnalyzer.frames(of: samples)
        try Task.checkCancellation()
        let duration = Double(samples.count) / ProsodyAnalyzer.sampleRate
        let emotions = (try? await EmotionClassifier.classify(url)) ?? []
        try Task.checkCancellation()
        let analysis = analyze(bars.map(\.text).joined(separator: "\n"), languages: languages)
        var syllables: [Int] = []
        let text = bars.map(\.text).joined(separator: "\n") as NSString
        for line in analysis.lines where line.range.location <= text.length {
            syllables.append(line.syllables)
        }

        var built: [BarDelivery] = []
        for (index, bar) in bars.enumerated() {
            if index % 8 == 0 { try Task.checkCancellation() }
            let start = bar.start
            // Bars that share a time share the span up to the next later one.
            let end = bars[(index + 1)...].first { $0.start > start }?.start ?? duration
            let span = frames.filter { $0.time >= start && $0.time < end }
            let voiced = span.filter { $0.pitch > 0 }
            let pitches = voiced.map { ProsodyAnalyzer.semitones($0.pitch) }.sorted()
            let pitchMean = pitches.isEmpty ? 0 : pitches.reduce(0, +) / Double(pitches.count)
            let range = pitches.count >= 5 ? pitches[Int(Double(pitches.count - 1) * 0.9)] - pitches[Int(Double(pitches.count - 1) * 0.1)] : 0
            let energy = span.isEmpty ? 0 : span.map(\.rms).reduce(0, +) / Double(span.count)
            let loud = span.filter { $0.rms > 0.004 }
            let brightness = loud.isEmpty ? 0 : loud.map { $0.centroid * $0.rms }.reduce(0, +) / loud.map(\.rms).reduce(0, +)
            let count = index < syllables.count ? syllables[index] : max(1, Tokenizer.words(in: bar.text).count)
            let pace = Double(count) / max(0.5, end - start)

            // The contour: how the pitch moves across the bar, in semitones a second.
            var contour = 0.0
            if voiced.count >= 5 {
                let times = voiced.map(\.time), tones = voiced.map { ProsodyAnalyzer.semitones($0.pitch) }
                let meanTime = times.reduce(0, +) / Double(times.count), meanTone = tones.reduce(0, +) / Double(tones.count)
                let covariance = zip(times, tones).reduce(0) { $0 + ($1.0 - meanTime) * ($1.1 - meanTone) }
                let variance = times.reduce(0) { $0 + ($1 - meanTime) * ($1 - meanTime) }
                contour = variance > 0 ? covariance / variance : 0
            }

            var barWords: [WordDelivery] = []
            for word in words where word.start >= start - 0.05 && word.start < end {
                let own = frames.filter { $0.time >= word.start && $0.time < max(word.end, word.start + 0.08) }
                let ownPitches = own.filter { $0.pitch > 0 }.map(\.pitch).sorted()
                let pitch = ownPitches.isEmpty ? 0 : ownPitches[ownPitches.count / 2]
                let ownEnergy = own.isEmpty ? 0 : own.map(\.rms).reduce(0, +) / Double(own.count)
                barWords.append(WordDelivery(text: word.text, start: word.start, end: word.end, pitch: pitch, energy: ownEnergy, stressed: false))
            }

            let windows = emotions.filter { $0.end > start && $0.start < end }
            var scores: [String: Double] = [:]
            for window in windows {
                for (label, score) in window.scores { scores[label, default: 0] += score / Double(windows.count) }
            }
            let top = scores.max { $0.value < $1.value }
            let spoken = semantics.sentiment(of: bar.text)
            var valence = spoken ?? 0
            var arousal = max(0, min(1, 0.45 * min(1, energy / 0.12) + 0.3 * min(1, range / 12) + 0.25 * min(1, pace / 6)))
            if !scores.isEmpty {
                let heard = scores.reduce(0.0) { $0 + $1.value * (EmotionClassifier.valence[$1.key] ?? 0) }
                let heat = scores.reduce(0.0) { $0 + $1.value * (EmotionClassifier.arousal[$1.key] ?? 0.3) }
                valence = spoken == nil ? heard : 0.6 * valence + 0.4 * heard
                arousal = 0.7 * arousal + 0.3 * heat
            }
            built.append(BarDelivery(text: bar.text, start: start, end: end, pitchMean: pitchMean, pitchRange: range, contour: contour,
                                     energy: energy, brightness: brightness, pace: pace, voiced: span.isEmpty ? 0 : Double(voiced.count) / Double(span.count),
                                     valence: valence, arousal: arousal, emotion: (top?.value ?? 0) > 0.4 ? top!.key : "", emotions: scores, words: barWords))
        }

        // Loudness against the take's own loudest bar and word; stress against each bar's own mean.
        // Against the loudest sung bar: an instrumental break, a blank line, is often louder.
        let loudest = built.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.map(\.energy).max() ?? built.map(\.energy).max() ?? 1
        let loudestWord = built.flatMap(\.words).map(\.energy).max() ?? 1
        for index in built.indices {
            built[index].energy = loudest > 0 ? min(1, built[index].energy / loudest) : 0
            let mean = built[index].words.isEmpty ? 0 : built[index].words.map(\.energy).reduce(0, +) / Double(built[index].words.count)
            let tone = built[index].pitchMean
            for word in built[index].words.indices {
                let own = built[index].words[word]
                built[index].words[word].stressed = own.energy > mean * 1.25 || (own.pitch > 0 && ProsodyAnalyzer.semitones(own.pitch) > tone + 2.5)
                built[index].words[word].energy = loudestWord > 0 ? min(1, own.energy / loudestWord) : 0
            }
        }
        // The take's style is its sung bars'; a blank line (an instrumental break) has no voice to read.
        let sung = built.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let basis = sung.isEmpty ? built : sung
        return SongDelivery(bars: built, style: Self.style(of: basis), styleWords: Self.styleWords(of: basis))
    }

    /// The take as twelve numbers: its style token.
    private static func style(of bars: [BarDelivery]) -> [Double] {
        guard !bars.isEmpty else { return Array(repeating: 0, count: 12) }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        func spread(_ values: [Double]) -> Double {
            let m = mean(values)
            return (values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count)).squareRoot()
        }
        let pitch = bars.filter { $0.pitchMean > 0 }.map(\.pitchMean)
        let clamp: (Double) -> Double = { max(0, min(1, $0)) }
        return [
            clamp((pitch.isEmpty ? 0 : mean(pitch)) / 60), clamp((pitch.isEmpty ? 0 : spread(pitch)) / 12),
            clamp(mean(bars.map(\.energy))), clamp(spread(bars.map(\.energy)) * 2),
            clamp(mean(bars.map(\.brightness)) / 4000), clamp(mean(bars.map(\.pace)) / 8),
            clamp(mean(bars.map(\.voiced))), clamp((mean(bars.map(\.valence)) + 1) / 2), clamp(spread(bars.map(\.valence))),
            clamp(mean(bars.map(\.arousal))), clamp((mean(bars.map(\.contour)) + 6) / 12), clamp(mean(bars.map(\.pitchRange)) / 12),
        ]
    }

    private static func styleWords(of bars: [BarDelivery]) -> [String] {
        guard !bars.isEmpty else { return [] }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        var words: [String] = []
        let pace = mean(bars.map(\.pace))
        words.append(pace > 5 ? "fast" : pace < 2.5 ? "slow" : "mid-tempo")
        let brightness = mean(bars.map(\.brightness))
        if brightness > 2200 { words.append("bright") } else if brightness > 0 && brightness < 1200 { words.append("dark") }
        let range = mean(bars.map(\.pitchRange))
        words.append(range > 8 ? "wide" : range < 3 ? "flat" : "lilting")
        let valence = mean(bars.map(\.valence))
        if valence > 0.2 { words.append("warm") } else if valence < -0.2 { words.append("cold") }
        let arousal = mean(bars.map(\.arousal))
        words.append(arousal > 0.6 ? "hot" : arousal < 0.3 ? "cool" : "even")
        let spread = bars.map(\.arousal).max()! - bars.map(\.arousal).min()!
        if spread > 0.4 { words.append("builds") }
        return words
    }
}
