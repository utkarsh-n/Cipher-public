import SwiftUI

struct EditorView: View {
    @Bindable var song: Song
    @Environment(AppModel.self) private var model
    @State private var controller = LyricController()
    @State private var analysis = VerseAnalysis()
    @State private var caret = CaretContext()
    @State private var showHighlights = true
    @State private var isEditing = false
    @State private var trayMode: TrayMode = .rhyme
    @State private var trayHits: [RhymeHit] = []
    @State private var analogies: [Analogy] = []
    @State private var analogyQuery: AnalogyQuery?
    /// Set when the writer picks another mode while the line still reads as an analogy.
    @State private var analogyOverride = false
    @State private var chainNodes: [OrbitNode] = []
    @State private var deepAnalogies: [AnalogyPair] = []
    @State private var deepAnalogyQuery: AnalogyQuery?
    @State private var askingClaude = false
    @State private var analogyProblem: String?
    @State private var signs: [SignToken] = []
    @State private var preferFocus = false
    @State private var showAssist = false
    @State private var showOrbit = false
    @State private var playback = Playback()
    @State private var deliveryBar: BarIndex?
    @State private var showDelivery = false
    @State private var readingDelivery = false
    /// Song, film and book titles written into the line under the caret.
    @State private var titled: [(work: Work, taken: Int)] = []
    @State private var openWork: Work?

    struct BarIndex: Identifiable { let id: Int }

    /// The bar being sung right now, while the recording plays.
    private var currentBar: Int? {
        guard playback.isPlaying, !song.barTimes.isEmpty else { return nil }
        return song.barTimes.lastIndex { $0 <= playback.time + 0.05 }
    }

    /// A line written as "smoke : fire ::" puts the tray in analogy mode by itself; one written
    /// as "pagal : paa's gal :" puts it in chain mode.
    private var effectiveMode: TrayMode {
        if trayMode == .analogy || (!analogyOverride && AnalogyQuery.parse(caret.line) != nil) { return .analogy }
        if trayMode == .chain || (!analogyOverride && ChainLine.parse(caret.line, range: caret.lineRange) != nil) { return .chain }
        return trayMode
    }

    private var chainLine: ChainLine? { ChainLine.parse(caret.line, range: caret.lineRange) }

    /// Whether the tray is answering the bar above rather than the word under the caret.
    private var answersAbove: Bool {
        let aboveFirst = caret.atLineEnd && !preferFocus
        return aboveFirst ? caret.previousLineEnd != nil : caret.focus == nil && caret.previousLineEnd != nil
    }

    /// The word the tray is finding matches for. While writing at the end of a bar that is the
    /// end of the bar above (the sound to land on); on a tapped word it is that word.
    private var target: String? {
        answersAbove ? caret.previousLineEnd : caret.focus ?? caret.previousLineEnd
    }

    /// The line the target sits in, which tells the engine what language to read it in.
    private var targetLine: String {
        answersAbove ? caret.previousLine ?? "" : caret.line
    }

    /// Multis answer a run of syllables, so that mode listens to the whole tail of the bar above
    /// rather than only its last word.
    private var trayQuery: String? {
        guard effectiveMode != .analogy, effectiveMode != .chain, let target else { return nil }
        if trayMode == .multi, answersAbove, let tail = caret.previousLineTail { return tail }
        return target
    }

    private var hasAlternateTarget: Bool {
        caret.focus != nil && caret.previousLineEnd != nil && caret.focus != caret.previousLineEnd
    }

    /// The bar shown as signs: the one being written, or the one above while the line is empty.
    private var signLine: String {
        caret.line.trimmingCharacters(in: .whitespaces).isEmpty ? caret.previousLine ?? "" : caret.line
    }

    private struct TrayKey: Equatable {
        let query: String?
        let line: String
        let mode: TrayMode
        let scope: Scope
    }

    private struct AnalogyKey: Equatable {
        let line: String
        let mode: TrayMode
        let scope: Scope
    }

    private struct SignKey: Equatable {
        let line: String
        let languages: [Language]
        let shown: Bool
    }

    private struct AnalysisKey: Equatable {
        let text: String
        let languages: [Language]
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $song.title)
                    .font(.title2.bold())
                Text([song.artist.isEmpty ? nil : song.artist, "\(analysis.bars) bars · \(analysis.syllables) syllables"].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if song.audioURL != nil { transport }
                if let delivery = song.delivery {
                    // Highlighted by the delivery's own times: its bars stay as they were read
                    // while the lines are edited.
                    DeliveryStrip(delivery: delivery, current: playback.isPlaying ? delivery.sungBar(at: playback.time) : nil) { deliveryBar = BarIndex(id: $0) }
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)

            LyricTextView(
                text: $song.text,
                analysis: analysis,
                showHighlights: showHighlights,
                times: $song.barTimes,
                currentLine: currentBar,
                bottomInset: showOrbit ? 560 : 120,
                controller: controller,
                onCaret: { caret = $0 },
                onFocus: { isEditing = $0 }
            )
            .overlay(alignment: .topLeading) {
                if song.text.isEmpty {
                    Text("Write a bar…")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 12)
                        .padding(.leading, LyricTextView.gutterWidth(timed: !song.barTimes.isEmpty) + 5)
                        .allowsHitTesting(false)
                }
            }
        }
        .task(id: song.audioFile) {
            if let url = song.audioURL { playback.load(url) }
        }
        .onDisappear { playback.stop() }
        .background(Theme.ink)
        .safeAreaInset(edge: .bottom) { tray }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Signs", systemImage: model.showSigns ? "hand.raised.fill" : "hand.raised.slash") {
                    model.showSigns.toggle()
                }
                Button("Highlights", systemImage: showHighlights ? "highlighter" : "pencil.slash") {
                    showHighlights.toggle()
                }
                Button("Orbit", systemImage: "circle.hexagonpath", action: openOrbit)
                Button("Assist", systemImage: "sparkles") { showAssist = true }
            }
        }
        .alert("Claude couldn't answer", isPresented: Binding(get: { analogyProblem != nil }, set: { if !$0 { analogyProblem = nil } })) {
            Button("OK") {}
        } message: {
            Text(analogyProblem ?? "")
        }
        .sheet(item: $deliveryBar) { bar in
            if let delivery = song.delivery, delivery.bars.indices.contains(bar.id) {
                ScrollView { DeliveryCard(bar: delivery.bars[bar.id], index: (delivery.sungBars.first { $0.offset == bar.id }?.number ?? bar.id + 1) - 1) }
                    .background(Theme.ink)
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showDelivery) {
            if let delivery = song.delivery { DeliverySheet(delivery: delivery, title: song.displayTitle) }
        }
        .sheet(isPresented: $showOrbit) {
            // Sticky: the bar stays editable underneath while the sphere is up.
            OrbitView(onInsert: { text in controller.insert(word: text) }, onChain: { chain in
                // Over the line it was read from when that line is still there; else at the caret.
                if let source = model.orbit.source, let range = Range(source.range, in: song.text), String(song.text[range]) == source.text {
                    controller.replace(source.range, with: ChainLine.text(of: chain.components(separatedBy: " : "), open: true))
                } else {
                    controller.insert(word: chain)
                }
            })
        }
        .sheet(isPresented: $showAssist) {
            AssistSheet(song: song, caret: caret, analysis: analysis, controller: controller)
        }
        .onChange(of: song.text) { song.updatedAt = .now }
        .task(id: caret.line) {
            // A title in the bar: what has already been used, and how often it has been taken from.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await model.culture.titled(in: caret.line, cultures: Culture.order(for: model.languages))
            guard !Task.isCancelled else { return }
            titled = found
        }
        .sheet(item: $openWork) { WorkSheet(work: $0) }
        .onAppear { controller.onOrbit = openOrbit }
        // The closure holds this view's state, which holds the controller: let go of it.
        .onDisappear { controller.onOrbit = nil }
        .task(id: AnalysisKey(text: song.text, languages: model.languages)) {
            // Let a burst of typing settle before re-reading the verse.
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            analysis = await model.engine.analyze(song.text, languages: model.languages)
        }
        .onChange(of: caret.line) {
            if AnalogyQuery.parse(caret.line) == nil && ChainLine.parse(caret.line, range: caret.lineRange) == nil { analogyOverride = false }
        }
        .task(id: AnalogyKey(line: effectiveMode == .chain ? caret.line : "", mode: effectiveMode, scope: model.scope)) {
            // The next step per direction for a chain being written on the line.
            guard effectiveMode == .chain, let chain = chainLine, !chain.head.isEmpty else {
                chainNodes = []
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let found = await model.engine.orbit(for: chain.head, trail: Array(chain.items.dropLast()), scope: model.scope)
            guard !Task.isCancelled else { return }
            var picked: [OrbitNode] = []
            // Home is where the chain has been; the tray offers where it could go.
            let favourites = model.favouriteDirections
            let order = favourites + OrbitDirection.allCases.filter { !favourites.contains($0) }
            for direction in order where direction != .leap && direction != .home {
                picked += found.nodes(in: direction).prefix(2)
            }
            chainNodes = picked
        }
        .task(id: AnalogyKey(line: caret.line, mode: effectiveMode, scope: model.scope)) {
            guard effectiveMode == .analogy else {
                analogies = []
                analogyQuery = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            let found = await model.engine.analogies(in: caret.line, scope: model.scope)
            guard !Task.isCancelled else { return }
            analogyQuery = found?.query
            analogies = found?.pairs ?? []
        }
        .task(id: TrayKey(query: trayQuery, line: targetLine, mode: trayMode, scope: model.scope)) {
            guard let query = trayQuery else {
                trayHits = []
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let hits = await model.engine.tray(query, context: targetLine, mode: trayMode, scope: model.scope)
            guard !Task.isCancelled else { return }
            trayHits = hits
        }
        .task(id: SignKey(line: signLine, languages: model.languages, shown: model.showSigns)) {
            guard model.showSigns, !signLine.isEmpty else {
                signs = []
                return
            }
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            let tokens = await model.engine.signs(for: signLine, languages: model.languages)
            guard !Task.isCancelled else { return }
            signs = tokens
        }
    }

    /// Play the recording the bars were written out from; the bar being sung lights up.
    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 26, height: 26)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!playback.isLoaded)
            Text("\(Playback.clock(playback.time)) / \(Playback.clock(playback.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let bar = currentBar, let number = sungNumber(of: bar) {
                Text("bar \(number)").font(.caption.monospacedDigit()).foregroundStyle(Theme.accent)
            }
            Spacer()
            if song.delivery != nil {
                Button("Delivery", systemImage: "waveform.path.ecg") { showDelivery = true }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            } else if song.isTranscribed, !song.barTimes.isEmpty {
                // Only timed bars can be read against the recording.
                Button(readingDelivery ? "Reading…" : "Read the delivery", systemImage: "waveform.path.ecg") { readDelivery() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .disabled(readingDelivery)
            }
        }
        .padding(.top, 4)
    }

    /// A line's number as the writer counts bars, blank lines left out; nil for a blank line.
    private func sungNumber(of line: Int) -> Int? {
        let lines = song.text.components(separatedBy: "\n")
        guard lines.indices.contains(line), !lines[line].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return lines[...line].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// Pitch, loudness, pace and warmth for a take written out before this existed.
    private func readDelivery() {
        guard let url = song.audioURL, let last = song.barTimes.last else { return }
        readingDelivery = true
        // One bar per line, blank ones included, so the delivery's bars are the editor's lines;
        // a line written after the times were set shares the last one's.
        let lines = song.text.components(separatedBy: "\n")
        let bars = lines.enumerated().map { ($0.element, $0.offset < song.barTimes.count ? song.barTimes[$0.offset] : last) }
        Task {
            defer { readingDelivery = false }
            if let delivery = try? await model.engine.delivery(audio: url, bars: bars, words: [], languages: model.languages) {
                song.delivery = delivery
            }
        }
    }

    private var tray: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !titled.isEmpty { titleStrip }
            if model.showSigns, !signs.isEmpty {
                SignStrip(tokens: signs, height: 46, background: Color(white: 0.13))
                Divider().overlay(Color.white.opacity(0.08))
            }
            HStack(spacing: 8) {
                Button {
                    preferFocus.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: effectiveMode == .analogy ? "equal" : effectiveMode == .chain ? "link" : hasAlternateTarget ? "arrow.left.arrow.right" : "scope")
                        Text(effectiveMode == .analogy ? analogyQuery.map { "\($0.a) : \($0.b)" } ?? "analogy" : effectiveMode == .chain ? (chainLine?.head ?? "chain") : target ?? "no word")
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background((effectiveMode == .analogy ? analogyQuery == nil : effectiveMode == .chain ? chainLine == nil : target == nil) ? Color.gray : Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!hasAlternateTarget || effectiveMode == .analogy || effectiveMode == .chain)
                .accessibilityLabel("Rhyme target: \(target ?? "none")")

                ScrollViewReader { modes in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(TrayMode.allCases) { mode in
                                Button(mode.rawValue) {
                                    trayMode = mode
                                    analogyOverride = mode != .analogy && mode != .chain
                                }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(effectiveMode == mode ? Color.white : Color.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(effectiveMode == mode ? Color.white.opacity(0.14) : .clear, in: Capsule())
                                    .buttonStyle(.plain)
                                    .id(mode)
                            }
                        }
                    }
                    // When a line turns into an analogy the mode row shows it happening.
                    .onChange(of: effectiveMode) { withAnimation { modes.scrollTo(effectiveMode, anchor: .center) } }
                }
                if isEditing {
                    Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") { controller.dismissKeyboard() }
                        .labelStyle(.iconOnly)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if effectiveMode == .chain {
                        if chainNodes.isEmpty {
                            Text("Write pagal : paa's gal : and the next step in every direction comes up here")
                                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 7)
                        }
                        ForEach(chainNodes) { node in
                            // Hindi and Gujarati carry their Roman spelling, so the scripts are never read alone.
                            let roman = model.scriptDisplay == .native ? "" : node.roman
                            WordChip(title: model.scriptDisplay == .roman && !roman.isEmpty ? roman : node.text,
                                     aside: (model.scriptDisplay == .both && !roman.isEmpty ? roman + " · " : "") + node.direction.label.lowercased(),
                                     strength: 0.5 + 0.5 * node.weight, tint: node.direction.tint) {
                                let line = caret.line.trimmingCharacters(in: .whitespaces)
                                let open = line.hasSuffix(":") || line.hasSuffix("→") || line.hasSuffix("->")
                                // Written the way the line is written: Roman letters on a Roman line.
                                let word = !node.roman.isEmpty && Script.of(caret.line) == .latin ? node.roman : node.text
                                controller.insert(word: (open ? "" : ": ") + word + " :")
                            }
                        }
                    } else if effectiveMode == .analogy {
                        if analogies.isEmpty {
                            Text(analogyQuery == nil ? "Write smoke : fire :: and pairs that hold the same relation come up here" : emptyMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 7)
                        }
                        if let analogyQuery, model.hasAPIKey {
                            // Word vectors give a quick first pass; Claude works the relation out properly.
                            if deepAnalogyQuery == analogyQuery, !deepAnalogies.isEmpty {
                                ForEach(deepAnalogies) { pair in
                                    WordChip(title: pair.text, aside: pair.strictness, strength: 1 - 0.6 * pair.looseness, tint: Color(Theme.highlighter(2))) {
                                        controller.insert(word: analogyQuery.c == nil ? pair.text : pair.right)
                                    }
                                }
                            } else {
                                Button {
                                    askClaude(analogyQuery)
                                } label: {
                                    Label(askingClaude ? "Asking…" : "Ask Claude", systemImage: "sparkles")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Theme.ink)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color(Theme.highlighter(2)), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(askingClaude)
                            }
                        }
                        // Strict pairs sit bright at the front; the lateral ones fade towards the end.
                        ForEach(analogies) { analogy in
                            WordChip(title: analogy.text, strength: 1 - 0.6 * analogy.looseness, tint: Theme.accent) {
                                controller.insert(word: analogyQuery?.c == nil ? analogy.text : analogy.right)
                            }
                        }
                    } else {
                        if trayHits.isEmpty {
                            Text(target == nil ? "Rhymes for the last bar show up here" : emptyMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 7)
                        }
                        ForEach(trayHits) { hit in
                            HitChip(hit: hit, tint: tint(hit.language)) { controller.insert(word: inserted(hit)) }
                        }
                    }
                }
            }
            .frame(height: 34)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// Titles the bar contains: a song, film or book already called this, and how many times it
    /// has been sampled, covered or borrowed from. Tap one for its card.
    private var titleStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(titled, id: \.work.id) { item in
                    Button {
                        openWork = item.work
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.work.kind.symbol).font(.caption2)
                            Text(item.work.title).font(.caption.weight(.semibold)).lineLimit(1)
                            Text([item.work.maker.isEmpty ? nil : item.work.maker, item.work.yearLabel].compactMap { $0 }.joined(separator: " "))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            if item.taken > 0 {
                                Text("taken \(item.taken)×").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                            }
                        }
                        .foregroundStyle(item.work.culture.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A chain written on the line is picked up where it stands; otherwise the sphere opens on
    /// the word under the caret, or carries on where it left off.
    private func openOrbit() {
        if let chain = ChainLine.parse(caret.line, range: caret.lineRange) {
            model.orbit.begin(chain: chain.items, source: (caret.lineRange, caret.line), model: model)
        } else if let word = caret.focus, word != model.orbit.centre {
            // The word under the caret; the chain in hand stays in the history.
            model.orbit.begin(word, origin: .editor, model: model)
        } else if model.orbit.isEmpty, let word = caret.previousLineEnd {
            model.orbit.begin(word, origin: .editor, model: model)
        }
        showOrbit = true
    }

    /// Claude works the relation out and answers in bands, strict to loose.
    private func askClaude(_ query: AnalogyQuery) {
        askingClaude = true
        Task {
            defer { askingClaude = false }
            do {
                let pairs = try await ClaudeClient().analogies(prompt: Prompts.analogies(query, languages: model.languages), depth: model.depth)
                deepAnalogies = pairs
                deepAnalogyQuery = query
            } catch {
                analogyProblem = error.localizedDescription
            }
        }
    }

    /// Hindi and Gujarati go in the way the writer is already writing them on this line.
    private func inserted(_ hit: RhymeHit) -> String {
        let line = caret.line.trimmingCharacters(in: .whitespaces).isEmpty ? targetLine : caret.line
        let writesRoman = Script.of(line) == .latin || (Script.of(line) == .other && model.scriptDisplay == .roman)
        return hit.language.isIndic && writesRoman && !hit.roman.isEmpty ? hit.roman : hit.word
    }

    /// In the tray every language shares one row, so each gets its own colour.
    private func tint(_ language: Language) -> Color {
        switch language {
        case .english: .white
        case .hindi: Color(Theme.highlighter(3))
        case .gujarati: Color(Theme.highlighter(5))
        case .spanish: Color(Theme.highlighter(7))
        case .french: Color(Theme.highlighter(1))
        }
    }

    private var emptyMessage: String {
        switch trayMode {
        case .rhyme: "No perfect rhymes. Try Slant."
        case .slant: "Nothing close. Try a looser setting."
        case .multi: "No single-word multis here. Try Assist."
        case .alike: "No sound-alikes for this one."
        case .related: "No meanings on this device for that word."
        case .analogy: "No pairs hold that relation closely. Try Loose, or plainer words."
        case .chain: "Nothing one step from that yet."
        }
    }
}
