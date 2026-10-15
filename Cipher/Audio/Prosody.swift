import Accelerate
import AVFoundation
import Foundation

/// What a voice did on one word: the part of language the text leaves out.
struct WordDelivery: Codable, Sendable, Equatable {
    var text: String
    var start: Double
    var end: Double
    /// Median pitch while voiced, in Hz; 0 when nothing voiced was found.
    var pitch: Double
    /// 0...1 against the loudest word of the take.
    var energy: Double
    /// Louder or higher than the bar around it.
    var stressed: Bool
}

/// How one bar was delivered.
struct BarDelivery: Codable, Sendable, Equatable {
    var text: String
    var start: Double
    var end: Double
    var pitchMean: Double
    /// Semitones between the 10th and 90th percentile of voiced pitch: monotone to expressive.
    var pitchRange: Double
    /// Semitones per second across the bar: falling, level, rising.
    var contour: Double
    /// 0...1 against the loudest bar of the take.
    var energy: Double
    /// Spectral centroid in Hz: dark to bright.
    var brightness: Double
    /// Syllables a second.
    var pace: Double
    /// Share of frames with a voiced pitch.
    var voiced: Double
    /// -1...1 from the words, blended with what the voice did when a classifier is present.
    var valence: Double
    /// 0...1 from energy, pitch range and pace.
    var arousal: Double
    /// The vocal emotion classifier's top label, or empty.
    var emotion: String
    var emotions: [String: Double]
    var words: [WordDelivery]

    var duration: Double { max(0.05, end - start) }

    /// The bar in a few words: "low key, falling, bright".
    var summary: String {
        var parts: [String] = []
        parts.append(arousal > 0.66 ? "fired up" : arousal > 0.33 ? "steady" : "low key")
        parts.append(contour > 1.5 ? "rising" : contour < -1.5 ? "falling" : "level")
        if pitchRange > 9 { parts.append("sung wide") } else if pitchRange < 3 && voiced > 0.3 { parts.append("flat") }
        if !emotion.isEmpty { parts.append(emotion) }
        return parts.joined(separator: ", ")
    }
}

/// The whole take: every bar, and the style it adds up to.
struct SongDelivery: Codable, Sendable, Equatable {
    static let version = 1
    var version = SongDelivery.version
    var bars: [BarDelivery]
    /// Twelve numbers that stand for the take, the way a style token would: mean and spread of
    /// pitch, energy, brightness, pace, voicing, valence and arousal, then contour and range.
    var style: [Double]
    /// The words of the style, for people: "fast, bright, wide, warm".
    var styleWords: [String]

    var bar: (Int) -> BarDelivery? { { index in self.bars.indices.contains(index) ? self.bars[index] : nil } }
}

/// Pitch, loudness and brightness, frame by frame, from a recording. The pitch tracker is
/// YIN (difference function with cumulative mean normalisation), the standard behind the
/// pitch stage of speech synthesis pipelines, run with Accelerate at 16 kHz.
struct ProsodyAnalyzer: Sendable {
    struct Frame: Sendable {
        let time: Double
        /// Hz, or 0 when unvoiced.
        let pitch: Double
        let rms: Double
        let centroid: Double
    }

    static let sampleRate: Double = 16_000
    static let frameLength = 1024
    static let hop = 256
    private static let minimumLag = Int(sampleRate / 500)   // 500 Hz
    private static let maximumLag = Int(sampleRate / 65)    // 65 Hz

    /// Mono 16 kHz samples of the whole file.
    static func samples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return [] }
        let capacity = AVAudioFrameCount(Double(file.length) * sampleRate / file.processingFormat.sampleRate + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var readError: NSError?
        var finished = false
        converter.convert(to: output, error: &readError) { count, status in
            if finished {
                status.pointee = .endOfStream
                return nil
            }
            guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                status.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: chunk)
            } catch {
                status.pointee = .endOfStream
                return nil
            }
            if chunk.frameLength == 0 {
                finished = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return chunk
        }
        if let readError { throw readError }
        guard let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    /// One frame every 16 ms.
    static func frames(of samples: [Float]) -> [Frame] {
        guard samples.count > frameLength else { return [] }
        let log2n = vDSP_Length(log2(Double(frameLength)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return [] }
        var window = [Float](repeating: 0, count: frameLength)
        vDSP_hann_window(&window, vDSP_Length(frameLength), Int32(vDSP_HANN_NORM))
        var frames: [Frame] = []
        var frame = [Float](repeating: 0, count: frameLength)
        var windowed = [Float](repeating: 0, count: frameLength)
        var real = [Float](repeating: 0, count: frameLength / 2)
        var imaginary = [Float](repeating: 0, count: frameLength / 2)
        var magnitudes = [Float](repeating: 0, count: frameLength / 2)
        var difference = [Float](repeating: 0, count: maximumLag + 1)
        var scratch = [Float](repeating: 0, count: frameLength)
        let binWidth = Float(sampleRate) / Float(frameLength)
        var bins = [Float](repeating: 0, count: frameLength / 2)
        for index in bins.indices { bins[index] = Float(index) * binWidth }

        var start = 0
        while start + frameLength <= samples.count {
            samples.withUnsafeBufferPointer { pointer in
                frame.withUnsafeMutableBufferPointer { out in
                    out.baseAddress!.update(from: pointer.baseAddress! + start, count: frameLength)
                }
            }
            var rms: Float = 0
            vDSP_rmsqv(frame, 1, &rms, vDSP_Length(frameLength))

            // Brightness: where the energy sits in the spectrum.
            vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(frameLength))
            var centroid: Float = 0
            windowed.withUnsafeBufferPointer { input in
                real.withUnsafeMutableBufferPointer { realPointer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                        var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: frameLength / 2) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(frameLength / 2))
                        }
                        fft.forward(input: split, output: &split)
                        vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(frameLength / 2))
                    }
                }
            }
            var total: Float = 0
            vDSP_sve(magnitudes, 1, &total, vDSP_Length(frameLength / 2))
            if total > 0 {
                var weighted: Float = 0
                vDSP_dotpr(magnitudes, 1, bins, 1, &weighted, vDSP_Length(frameLength / 2))
                centroid = weighted / total
            }

            // Pitch: YIN. d(τ) = Σ (x[i] − x[i+τ])², normalised by its running mean, first dip below the threshold.
            var pitch: Float = 0
            if rms > 0.004 {
                let span = frameLength - maximumLag
                difference[0] = 1
                var running: Float = 0
                for lag in 1...maximumLag {
                    frame.withUnsafeBufferPointer { pointer in
                        vDSP_vsub(pointer.baseAddress! + lag, 1, pointer.baseAddress!, 1, &scratch, 1, vDSP_Length(span))
                    }
                    var sum: Float = 0
                    vDSP_dotpr(scratch, 1, scratch, 1, &sum, vDSP_Length(span))
                    running += sum
                    difference[lag] = running > 0 ? sum * Float(lag) / running : 1
                }
                var best = -1
                var lag = minimumLag
                while lag < maximumLag {
                    if difference[lag] < 0.14 {
                        // Walk down to the bottom of this dip.
                        while lag + 1 < maximumLag && difference[lag + 1] < difference[lag] { lag += 1 }
                        best = lag
                        break
                    }
                    lag += 1
                }
                if best < 0 {
                    // No clear dip: take the lowest point if it is at all periodic.
                    var lowest: Float = 1
                    for candidate in minimumLag..<maximumLag where difference[candidate] < lowest {
                        lowest = difference[candidate]
                        best = candidate
                    }
                    if lowest > 0.3 { best = -1 }
                }
                if best > 0 {
                    // Parabolic interpolation around the dip for a finer period.
                    let left = difference[max(0, best - 1)], centre = difference[best], right = difference[min(maximumLag, best + 1)]
                    let denominator = left - 2 * centre + right
                    let shift = denominator != 0 ? (left - right) / (2 * denominator) : 0
                    pitch = Float(sampleRate) / (Float(best) + shift)
                }
            }
            frames.append(Frame(time: Double(start) / sampleRate, pitch: Double(pitch), rms: Double(rms), centroid: Double(centroid)))
            start += hop
        }
        return frames
    }

    static func semitones(_ hz: Double) -> Double { 12 * log2(max(hz, 1) / 55) }
}
