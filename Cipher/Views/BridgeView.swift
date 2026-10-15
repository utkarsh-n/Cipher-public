import SwiftUI

/// Two ideas in, and the words that connect them out: rhymes for one that belong to the
/// other, the vocabulary they share, and Claude-written bars that build the metaphor. Either
/// idea can be in any of the writer's languages.
struct BridgeView: View {
    @Environment(AppModel.self) private var model
    @State private var first = ""
    @State private var second = ""
    @State private var forward = Bridge()
    @State private var backward = Bridge()
    @State private var metaphors: [Suggestion] = []
    @State private var isSearching = false
    @State private var isWriting = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var request: Task<Void, Never>?

    private struct Key: Equatable {
        let first: String
        let second: String
        let scope: Scope
    }

    private var a: String { first.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var b: String { second.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var ready: Bool { !a.isEmpty && !b.isEmpty }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    inputs
                    Picker("Looseness", selection: $model.looseness) {
                        ForEach(Looseness.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if ready, isSearching {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                    } else if ready {
                        results
                    } else {
                        Text("Put in the thing you're writing about and the thing you want to compare it to, in any of your languages. Cipher finds rhymes for each that belong to the other, and the words the two share.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.ink)
            .navigationTitle("Bridge")
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .task(id: Key(first: a, second: b, scope: model.scope)) {
            request?.cancel()
            isWriting = false
            metaphors = []
            errorMessage = nil
            guard ready else { return }
            isSearching = true
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let engine = model.engine
            let onward = await engine.bridge(rhyme: a, theme: b, scope: model.scope)
            let back = await engine.bridge(rhyme: b, theme: a, scope: model.scope)
            guard !Task.isCancelled else { return }
            forward = onward
            backward = back
            isSearching = false
        }
    }

    private var inputs: some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                field("One idea", text: $first)
                Divider()
                field("Another idea", text: $second)
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.panelStroke))

            Button("Swap", systemImage: "arrow.up.arrow.down") { swap(&first, &second) }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
    }

    @ViewBuilder
    private var results: some View {
        themed(forward, rhyme: a, theme: b)
        themed(backward, rhyme: b, theme: a)

        if !forward.commonGround.isEmpty {
            SectionCard(title: "Common ground", subtitle: "Words that sit between \(a) and \(b)") {
                LanguageClouds(hits: forward.commonGround, tint: Color(Theme.highlighter(5)), initial: 12, onTap: model.lookUp)
            }
        }

        SectionCard(title: "Metaphors", subtitle: "Bars that describe one through the other, written by Claude") {
            if !model.hasAPIKey {
                Button("Add API key") { showSettings = true }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.ink)
            } else {
                Button(action: write) {
                    HStack {
                        if isWriting { ProgressView().tint(Theme.ink) }
                        Text(isWriting ? "Writing…" : metaphors.isEmpty ? "Write bars" : "Write more").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Theme.ink)
                .disabled(isWriting)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            ForEach(metaphors) { suggestion in
                SuggestionCard(suggestion: suggestion) {
                    Button("Copy") { UIPasteboard.general.string = suggestion.text }.buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private func themed(_ bridge: Bridge, rhyme: String, theme: String) -> some View {
        SectionCard(title: "Rhymes with \(rhyme)", subtitle: "that belong to \(theme)", count: bridge.themedRhymes.isEmpty ? nil : bridge.themedRhymes.count) {
            if bridge.themedRhymes.isEmpty {
                Text(emptyReason(bridge, rhyme: rhyme, theme: theme)).font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(model.languages) { language in
                    let own = bridge.themedRhymes.filter { $0.hit.language == language }
                    if !own.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            LanguageLabel(language: language, count: own.count)
                            FlowLayout {
                                ForEach(own.prefix(24)) { item in
                                    HitChip(hit: RhymeHit(word: item.hit.word, language: item.hit.language, score: item.closeness, syllables: item.hit.syllables, tier: item.hit.tier, roman: item.hit.roman, gloss: item.hit.gloss), tint: tint(item.kind)) {
                                        model.lookUp(item.hit)
                                    }
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 12) {
                    legend("Perfect", .perfect)
                    legend("Slant", .slant)
                    legend("Multi", .multi)
                }
            }
        }
    }

    private func legend(_ label: String, _ kind: BridgeHit.Kind) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint(kind)).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func tint(_ kind: BridgeHit.Kind) -> Color {
        switch kind {
        case .perfect: Theme.accent
        case .slant: Color(Theme.highlighter(1))
        case .multi: Color(Theme.highlighter(2))
        }
    }

    private func emptyReason(_ bridge: Bridge, rhyme: String, theme: String) -> String {
        if !bridge.rhymeFound { return "Couldn't work out how \"\(rhyme)\" sounds." }
        if !bridge.themeFound { return "The phone has no meaning on file for \"\(theme)\", so there is nothing to match against. Claude can still write with it below." }
        return "No rhymes land close enough to \(theme). Try Loose."
    }

    private func write() {
        let first = a, second = b
        let ground = forward.commonGround.filter { $0.language == .english }.prefix(16).map(\.word)
        let depth = model.depth
        let languages = model.languages
        isWriting = true
        errorMessage = nil
        request?.cancel()
        request = Task {
            do {
                let result = try await ClaudeClient().suggestions(
                    prompt: Prompts.metaphors(first, second, commonGround: Array(ground), languages: languages),
                    depth: depth
                )
                guard !Task.isCancelled else { return }
                metaphors = result + metaphors.filter { !result.contains($0) }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isWriting = false
        }
    }
}
