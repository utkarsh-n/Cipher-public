import SwiftUI
import OfflineIntelligence

/// Options for the next bar, rewrites of the current one, or one bar forged from a line of
/// fragments: written on this phone by the on-device model and checked by the engine, or by Claude.
struct AssistSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case next = "Next bar", punchUp = "Punch up", forge = "Forge", finish = "Finish"

        var id: String { rawValue }

        /// What the sheet says it is doing with the anchor line.
        var anchorLabel: String {
            switch self {
            case .next: "Following"
            case .punchUp: "Rewriting"
            case .forge: "Forging"
            case .finish: "Finishing after"
            }
        }
    }

    /// Who writes: the model on this phone, or Claude through the writer's API key.
    enum Writer: String, CaseIterable, Identifiable {
        case phone = "On this phone", claude = "Claude"

        var id: String { rawValue }
    }

    let song: Song
    let caret: CaretContext
    let analysis: VerseAnalysis
    let controller: LyricController

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .next
    @AppStorage("assistWriter") private var writer: Writer = .phone
    @State private var direction = ""
    @State private var suggestions: [Suggestion] = []
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var request: Task<Void, Never>?
    @State private var requestIdentity = UUID()
    @State private var isCancelling = false
    @AppStorage(OfflineModelChoice.preferenceKey) private var modelChoiceRaw = OfflineModelChoice.defaultChoice.rawValue

    /// The bar Assist works from: the caret's line, or the one above when the caret sits on an
    /// empty line.
    private var anchor: (text: String, range: NSRange)? {
        if !caret.line.trimmingCharacters(in: .whitespaces).isEmpty { return (caret.line, caret.lineRange) }
        if let line = caret.previousLine, let range = caret.previousLineRange { return (line, range) }
        return nil
    }

    private var caretOnEmptyLine: Bool {
        caret.line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if writer == .phone {
                        Picker("On-device writing model", selection: $modelChoiceRaw) {
                            ForEach(OfflineModelChoice.allCases) { choice in
                                Text(choice.title).tag(choice.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isWorking)
                        Text((OfflineModelChoice(rawValue: modelChoiceRaw) ?? .defaultChoice).detail)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Writer", selection: $writer) {
                        ForEach(Writer.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if let anchor {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.anchorLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(anchor.text).font(.callout.italic())
                        }
                        TextField("Direction (optional)", text: $direction, axis: .vertical)
                            .textFieldStyle(.roundedBorder)

                        if writer == .claude, !model.hasAPIKey {
                            keyPrompt
                        } else {
                            Button(action: generate) {
                                HStack {
                                    if isWorking { ProgressView().tint(Theme.ink) }
                                    Text(isWorking ? (isCancelling ? "Stopping…" : writer == .phone ? "Writing on this phone…" : "Writing…") : suggestions.isEmpty ? "Write options" : "Write more")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .foregroundStyle(Theme.ink)
                            .disabled(isWorking)
                            if isWorking && !isCancelling {
                                Button("Stop writing", systemImage: "stop.fill") { cancelRequest() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    } else {
                        ContentUnavailableView("Write a bar first", systemImage: "text.cursor", description: Text("Assist builds on the line your cursor is on."))
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    ForEach(suggestions) { suggestion in
                        SuggestionCard(suggestion: suggestion) {
                            Button(mode == .next || mode == .finish ? "Add to verse" : "Replace line") { apply(suggestion) }
                                .buttonStyle(.bordered)
                            Button("Copy") { UIPasteboard.general.string = suggestion.text }
                                .buttonStyle(.bordered)
                                .tint(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.ink)
            .navigationTitle("Assist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: writer) {
                cancelRequest()
            }
            .onChange(of: mode) {
                cancelRequest()
                suggestions = []
                errorMessage = nil
            }
            .onChange(of: modelChoiceRaw) { _, raw in
                Task { await model.local.select(OfflineModelChoice(rawValue: raw) ?? .defaultChoice) }
            }
            .onDisappear { cancelRequest() }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .presentationDetents([.medium, .large])
    }

    private var keyPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assist uses Claude through your own Anthropic API key.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Add API key") { showSettings = true }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Theme.ink)
        }
    }

    private func generate() {
        guard let anchor else { return }
        let mode = mode
        let depth = model.depth
        let scope = model.scope
        let engine = model.engine
        let culture = model.culture
        let cultures = Culture.order(for: model.languages)
        // Pace the new bar against the few bars leading up to it.
        let nearby = analysis.lines.filter { $0.scheme != nil && $0.range.location <= anchor.range.location }.suffix(4)
        let syllables = nearby.isEmpty ? nil : nearby.reduce(0) { $0 + $1.syllables } / nearby.count
        var context = Prompts.VerseContext(
            title: song.title, verse: song.text, targetLine: anchor.text, syllables: syllables, palette: [],
            direction: direction, languages: model.languages, mix: analysis.languages
        )
        let rhymeWord = mode == .next || mode == .finish ? LyricTextView.Coordinator.lastWord(anchor.text) : nil

        isWorking = true
        isCancelling = false
        errorMessage = nil
        request?.cancel()
        let identity = UUID()
        requestIdentity = identity
        if writer == .phone {
            generateOnPhone(anchor: anchor, syllables: syllables, scope: scope, identity: identity)
            return
        }
        request = Task {
            defer { finishRequest(identity) }
            do {
                if let rhymeWord {
                    context.palette = await engine.palette(for: rhymeWord, context: anchor.text, scope: scope)
                }
                let ideas = await engine.ideas(in: anchor.text, languages: scope.languages)
                context.references = await culture.references(for: ideas, cultures: cultures)
                let prompt = switch mode {
                case .next: Prompts.nextBar(context)
                case .punchUp: Prompts.punchUp(context)
                case .forge: Prompts.forge(context)
                case .finish: Prompts.finish(context)
                }
                let result = try await ClaudeClient().suggestions(prompt: prompt, depth: depth)
                guard !Task.isCancelled, requestIdentity == identity else { return }
                suggestions = result + suggestions.filter { !result.contains($0) }
            } catch is CancellationError {
                return
            } catch {
                if requestIdentity == identity { errorMessage = error.localizedDescription }
            }
        }
    }

    /// The line a new or rewritten bar should rhyme with: the anchor itself for the next bar, the
    /// earlier line sharing the anchor's rhyme letter for a rewrite, and the line before for a forge.
    private func rhymeTarget(for anchor: (text: String, range: NSRange)) -> String? {
        let text = song.text as NSString
        switch mode {
        case .next, .finish:
            return anchor.text
        case .punchUp, .forge:
            let earlier = analysis.lines.filter { NSMaxRange($0.range) <= anchor.range.location }
            if mode == .punchUp, let mine = analysis.lines.first(where: { $0.range.location == anchor.range.location })?.scheme,
               let partner = earlier.last(where: { $0.scheme == mine }) {
                return text.substring(with: partner.range)
            }
            guard mode == .forge, let previous = earlier.last(where: { !text.substring(with: $0.range).trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            return text.substring(with: previous.range)
        }
    }

    /// Drafts from the on-device model, kept or dropped by the engine; the best appear as they come.
    private func generateOnPhone(anchor: (text: String, range: NSRange), syllables: Int?, scope: Scope, identity: UUID) {
        let engine = model.engine
        let culture = model.culture
        let cultures = Culture.order(for: model.languages)
        let local = model.local
        let target = rhymeTarget(for: anchor)
        let verse = (song.text as NSString).substring(to: min((song.text as NSString).length, NSMaxRange(anchor.range)))
        let job: LocalWriter.Job = switch mode {
        case .next, .finish: .next
        case .punchUp: .punchUp
        case .forge: .forge
        }
        let earlier = suggestions
        if mode == .finish {
            // The verse up to the anchor, with the rhyme letters the editor gave its lines.
            let text = song.text as NSString
            let lines = analysis.lines.filter { $0.range.location <= anchor.range.location }
                .map { (text: text.substring(with: $0.range), scheme: $0.scheme) }
                .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            let languages = model.languages
            let direction = direction
            request = Task {
                defer { finishRequest(identity) }
                do {
                    var bars: [String] = []
                    _ = try await LocalWriter.finish(lines: lines, syllables: syllables, direction: direction, languages: languages,
                                                     model: local, engine: engine) { bar in
                        guard requestIdentity == identity, !Task.isCancelled else { return }
                        bars.append(bar)
                        suggestions = [Suggestion(text: bars.joined(separator: "\n"), note: "\(bars.count) bars in the verse's scheme · written on this phone")] + earlier
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if requestIdentity == identity { errorMessage = error.localizedDescription }
                }
            }
            return
        }
        request = Task {
            defer { finishRequest(identity) }
            do {
                var palette: [String] = []
                if let target { palette = await engine.palette(for: target, context: target, scope: scope) }
                let ideas = await engine.ideas(in: anchor.text, languages: scope.languages)
                let references = await culture.references(for: ideas, cultures: cultures)
                let request = LocalWriter.Request(job: job, verse: verse, anchor: anchor.text, rhymeTarget: target, syllables: syllables,
                                                  palette: palette, references: references, direction: direction, languages: model.languages)
                let result = try await LocalWriter.suggestions(request, model: local, engine: engine) { ranked in
                    guard requestIdentity == identity, !Task.isCancelled else { return }
                    suggestions = ranked + earlier.filter { !ranked.contains($0) }
                }
                guard !Task.isCancelled, requestIdentity == identity else { return }
                suggestions = result + earlier.filter { !result.contains($0) }
            } catch is CancellationError {
                return
            } catch {
                if requestIdentity == identity { errorMessage = error.localizedDescription }
            }
        }
    }

    private func apply(_ suggestion: Suggestion) {
        guard let anchor else { return }
        switch mode {
        case .punchUp, .forge:
            controller.replace(anchor.range, with: suggestion.text)
        case .next, .finish:
            if caretOnEmptyLine {
                controller.replace(caret.lineRange, with: suggestion.text)
            } else {
                controller.insertLine(suggestion.text, after: anchor.range)
            }
        }
        dismiss()
    }

    private func finishRequest(_ identity: UUID) {
        guard requestIdentity == identity else { return }
        isWorking = false
        isCancelling = false
        request = nil
    }

    /// Drain compute before accepting another request; cancelling a SwiftUI task alone is not
    /// sufficient to release an in-flight MLX prefill or decode.
    private func cancelRequest() {
        let previous = request
        previous?.cancel()
        let identity = UUID()
        requestIdentity = identity
        isWorking = previous != nil
        isCancelling = previous != nil
        request = Task {
            await model.local.cancel()
            await previous?.value
            finishRequest(identity)
        }
    }
}
