import SwiftUI

extension BarDelivery {
    /// The bar's feel as a colour: cold blue to warm lime by valence, dim to bright by arousal.
    var tint: Color {
        Color(hue: 0.62 - 0.42 * (valence + 1) / 2, saturation: 0.75, brightness: 0.45 + 0.55 * arousal)
    }

    /// "A3" for 220 Hz.
    static func note(_ hz: Double) -> String {
        guard hz > 0 else { return "–" }
        let names = ["A", "A♯", "B", "C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯"]
        let semitones = Int((12 * log2(hz / 55)).rounded())
        let octave = 1 + (semitones + 9) / 12
        return names[((semitones % 12) + 12) % 12] + String(octave)
    }

    var pitchHz: Double { pitchMean > 0 ? 55 * pow(2, pitchMean / 12) : 0 }
}

/// Every bar of the take in a row: its pitch line, loudness and feel, small enough to sit
/// under the title while the bars are being read or played.
struct DeliveryStrip: View {
    let delivery: SongDelivery
    var current: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(delivery.sungBars, id: \.offset) { index, number, bar in
                        BarChip(bar: bar, number: number, isCurrent: current == index) { onSelect(index) }
                            .id(index)
                    }
                }
            }
            .onChange(of: current) { if let current { withAnimation { proxy.scrollTo(current, anchor: .center) } } }
        }
    }
}

private struct BarChip: View {
    let bar: BarDelivery
    let number: Int
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        Button(action: action) {
            VStack(spacing: 3) {
                BarGlyph(bar: bar).frame(width: 46, height: 22)
                Text("\(number)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(5)
            .background(bar.tint.opacity(isCurrent ? 0.5 : 0.16), in: shape)
            .overlay(shape.strokeBorder(bar.tint.opacity(isCurrent ? 1 : 0.35)))
        }
        .buttonStyle(.plain)
    }
}

/// A bar's pitch line, drawn from its words when they were timed, else from its contour;
/// thicker when louder.
struct BarGlyph: View {
    let bar: BarDelivery

    var body: some View {
        Canvas { context, size in
            let centre = bar.pitchMean
            let scale = max(6, bar.pitchRange)
            var points: [CGPoint] = []
            let timed = bar.words.filter { $0.pitch > 0 }
            if timed.count >= 2 {
                for word in timed {
                    let x = (word.start - bar.start) / bar.duration
                    let y = 0.5 - (ProsodyAnalyzer.semitones(word.pitch) - centre) / (2 * scale)
                    points.append(CGPoint(x: size.width * max(0, min(1, x)), y: size.height * max(0.05, min(0.95, y))))
                }
            } else if bar.voiced > 0.05 {
                let drop = bar.contour * bar.duration / 2 / (2 * scale)
                points = [CGPoint(x: 2, y: size.height * max(0.1, min(0.9, 0.5 + drop))), CGPoint(x: size.width - 2, y: size.height * max(0.1, min(0.9, 0.5 - drop)))]
            }
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height / 2))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(baseline, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
            guard points.count >= 2 else { return }
            var line = Path()
            line.move(to: points[0])
            for point in points.dropFirst() { line.addLine(to: point) }
            context.stroke(line, with: .color(bar.tint), style: StrokeStyle(lineWidth: 1 + 2 * bar.energy, lineCap: .round, lineJoin: .round))
        }
    }
}

/// One bar up close: the numbers behind its feel, and which words carried the weight.
struct DeliveryCard: View {
    let bar: BarDelivery
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bar \(index + 1)").font(.headline)
                Spacer()
                Text(bar.summary).font(.subheadline).foregroundStyle(bar.tint)
            }
            Text(bar.text).font(.body)
            if !bar.words.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(Array(bar.words.enumerated()), id: \.offset) { _, word in
                        Text(word.text)
                            .font(word.stressed ? .subheadline.weight(.bold) : .subheadline)
                            .foregroundStyle(word.stressed ? Color.white : Color.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(bar.tint.opacity(0.1 + 0.5 * word.energy), in: Capsule())
                    }
                }
                Text("Bold words carried the stress; the fill is how loud each was.").font(.caption2).foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                figure("Pitch", bar.pitchHz > 0 ? "\(BarDelivery.note(bar.pitchHz)) · \(Int(bar.pitchHz)) Hz" : "unvoiced")
                figure("Range", String(format: "%.1f st", bar.pitchRange))
                figure("Contour", String(format: "%+.1f st/s", bar.contour))
                figure("Loudness", "\(Int(bar.energy * 100))%")
                figure("Brightness", bar.brightness > 0 ? "\(Int(bar.brightness)) Hz" : "–")
                figure("Pace", String(format: "%.1f syl/s", bar.pace))
                figure("Valence", String(format: "%+.2f", bar.valence))
                figure("Arousal", String(format: "%.2f", bar.arousal))
                figure("Voiced", "\(Int(bar.voiced * 100))%")
            }
            if !bar.emotions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What the voice sounded like").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(bar.emotions.sorted { $0.value > $1.value }.prefix(4), id: \.key) { label, score in
                        HStack {
                            Text(label).font(.caption).frame(width: 70, alignment: .leading)
                            Capsule().fill(Color.white.opacity(0.1)).frame(height: 5)
                                .overlay(alignment: .leading) { GeometryReader { g in Capsule().fill(bar.tint).frame(width: g.size.width * score) } }
                            Text(String(format: "%.2f", score)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("No vocal emotion model is bundled yet; valence here comes from the words.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
    }

    private func figure(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}

/// The whole take: arousal and warmth bar by bar, the style it adds up to, and every bar's card.
struct DeliverySheet: View {
    let delivery: SongDelivery
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("How it was delivered").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(delivery.styleWords.joined(separator: " · ")).font(.title3.weight(.semibold))
                    }
                    timeline
                    styleVector
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Bar by bar").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(delivery.sungBars, id: \.offset) { _, number, bar in
                            NavigationLink {
                                ScrollView { DeliveryCard(bar: bar, index: number - 1) }.background(Theme.ink)
                            } label: {
                                HStack(spacing: 10) {
                                    BarGlyph(bar: bar).frame(width: 46, height: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bar.text).font(.subheadline).lineLimit(1)
                                        Text(bar.summary).font(.caption).foregroundStyle(bar.tint)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(10)
                                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.ink)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    /// Arousal as a curve, warmth as the colour under it, one column per bar.
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Heat and warmth, bar by bar").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Canvas { context, size in
                let bars = delivery.sungBars.map(\.bar)
                guard !bars.isEmpty else { return }
                let column = size.width / CGFloat(bars.count)
                for (index, bar) in bars.enumerated() {
                    let x = CGFloat(index) * column
                    let height = size.height * CGFloat(0.1 + 0.9 * bar.arousal)
                    let rect = CGRect(x: x + 1, y: size.height - height, width: max(1, column - 2), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(bar.tint.opacity(0.85)))
                }
                var curve = Path()
                for (index, bar) in bars.enumerated() {
                    let point = CGPoint(x: (CGFloat(index) + 0.5) * column, y: size.height * CGFloat(1 - bar.arousal) * 0.9 + 2)
                    if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                }
                context.stroke(curve, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
            }
            .frame(height: 90)
            HStack {
                Text("cold").font(.caption2).foregroundStyle(Color(hue: 0.62, saturation: 0.75, brightness: 0.9))
                Spacer()
                Text("height is heat, colour is warmth").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("warm").font(.caption2).foregroundStyle(Color(hue: 0.2, saturation: 0.75, brightness: 0.9))
            }
        }
    }

    /// The take's twelve numbers: what a style token looks like when you can read it.
    private var styleVector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Style vector").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            let names = ["pitch", "pitch spread", "loudness", "loud spread", "brightness", "pace", "voiced", "warmth", "warmth spread", "heat", "contour", "range"]
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                ForEach(Array(zip(names, delivery.style)), id: \.0) { name, value in
                    VStack(spacing: 3) {
                        Capsule().fill(Color.white.opacity(0.1)).frame(height: 5)
                            .overlay(alignment: .leading) { GeometryReader { g in Capsule().fill(Theme.accent).frame(width: g.size.width * value) } }
                        Text(String(format: "%@ %.2f", name, value)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}

extension SongDelivery {
    /// The bars with words in them: where each sits among the song's lines, and its number as
    /// the writer counts bars. A blank line (a break between verses, an instrumental stretch) is
    /// a bar of its own but has nothing to show and is not counted.
    var sungBars: [(offset: Int, number: Int, bar: BarDelivery)] {
        bars.enumerated().filter { !$0.element.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .enumerated().map { ($0.element.offset, $0.offset + 1, $0.element.element) }
    }

    /// The bar being sung `time` seconds in, by the delivery's own times; nil in a break.
    func sungBar(at time: Double) -> Int? {
        guard let index = bars.lastIndex(where: { $0.start <= time + 0.05 }),
              !bars[index].text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return index
    }
}
