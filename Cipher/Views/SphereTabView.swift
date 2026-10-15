import SwiftData
import SwiftUI

/// The sphere as a tab of its own. Type, and everything a step away from the word pops up
/// around it as you go; tap a word to step to it, and the chain builds under the field.
struct SphereTabView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    /// The word this tab last put in the sphere: the field only reseeds when it says something else.
    @State private var seeded = ""
    @State private var completions: [Engine.Completion] = []
    /// Whether typing re-seeds the sphere as you go. Off once a chain has been walked, so a
    /// stray edit never replaces the walk; emptying the field (or pressing Return) turns it on.
    @State private var live = true
    @State private var showWeights = false
    @State private var showHistory = false
    @Query(sort: \ChainRecord.updatedAt, order: .reverse) private var records: [ChainRecord]
    @FocusState private var focused: Bool

    private static let starters = ["pagal", "sunshine", "tape", "smoke", "koi mil gaya", "bleeding heart"]

    private var orbit: OrbitModel { model.orbit }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                field
                // Completions finish a word being typed; once the chain moves on they would only
                // be a way to lose it.
                if !completions.isEmpty, focused, orbit.trail.isEmpty { completionRow }
                // While the keyboard is up the action bar would sit under it; the sphere keeps the room.
                // Touching the sphere puts the keyboard away. (A tap gesture laid over the panel
                // would swallow the taps on the words themselves.)
                OrbitPanel(showWeights: showWeights, compact: focused, onTouch: { focused = false }) { hint }
            }
            .background(Theme.ink)
            .navigationTitle(orbit.isEmpty ? "Sphere" : orbit.centre)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("History", systemImage: "clock.arrow.circlepath") { showHistory = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Show weights", systemImage: "number", isOn: $showWeights)
                        if !orbit.isEmpty {
                            Button("Copy chain", systemImage: "doc.on.doc") { UIPasteboard.general.string = orbit.chainText }
                            Button("Start over", systemImage: "arrow.counterclockwise", role: .destructive) { orbit.clear() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showHistory) { ChainHistoryView() }
        .task(id: text) { await follow() }
        .onChange(of: orbit.centre, initial: true) { syncField() }
        .onChange(of: orbit.record?.id) { syncField() }
    }

    /// The seed: what is typed here stands at the centre of the sphere.
    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.hexagonpath").foregroundStyle(Theme.accent)
            TextField("Type a word and watch it open", text: $text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submit)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill", action: clear)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.panelStroke))
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    /// Words the dictionary can finish the last word into; tap one to take it.
    private var completionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(completions, id: \.self) { completion in
                    let roman = model.scriptDisplay == .native ? "" : completion.roman
                    WordChip(title: model.scriptDisplay == .roman && !roman.isEmpty ? roman : completion.word,
                             aside: model.scriptDisplay == .both && !roman.isEmpty ? roman : nil,
                             strength: 0.7, tint: Theme.accent) { complete(with: completion.word) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var hint: some View {
        VStack(spacing: 14) {
            Image(systemName: "circle.hexagonpath").font(.system(size: 40)).foregroundStyle(Theme.accent)
            Text("Start typing").font(.title3.weight(.semibold))
            Text("Everything one step away pops up around the word as you type: sound, recuts, hinges, meaning, culture, your other tongues. Tap a word to step to it; the chain builds as you go and can be sent to the editor.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            FlowLayout {
                ForEach(Self.starters, id: \.self) { word in
                    WordChip(title: word, tint: Theme.accent) { text = word }
                }
            }
            let recent = records.filter(\.isWalked).prefix(5)
            if !recent.isEmpty {
                // Pick up where you left off.
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Recent chains").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("All", action: { showHistory = true }).font(.caption.weight(.semibold))
                    }
                    ForEach(Array(recent)) { record in
                        Button {
                            model.orbit.resume(record, model: model)
                        } label: {
                            HStack {
                                Text(record.chain.joined(separator: " : ")).font(.subheadline).lineLimit(1)
                                Spacer()
                                if record.starred { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                                Text(record.updatedAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The sphere follows the field, a beat behind the typing. Only a change to the field
    /// reseeds it: coming back to the tab, or walking on from the word, leaves the chain alone.
    private func follow() async {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            completions = []
            // An emptied field takes its own one-word sphere away, never a walked chain, and
            // the next word typed starts afresh.
            if !seeded.isEmpty, orbit.trail.isEmpty, orbit.centre == seeded { orbit.clear() }
            seeded = ""
            live = true
            return
        }
        guard typed != seeded, live || orbit.trail.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        orbit.begin(typed, model: model)
        seeded = typed
        let finished = await model.engine.completions(of: typed, languages: model.languages)
        guard !Task.isCancelled else { return }
        completions = finished
    }

    /// The field shows where the chain in hand began: one begun elsewhere (the Lab, the editor,
    /// the history, the last session) shows its first word, without the sphere being seeded
    /// again; one cleared elsewhere clears the field.
    private func syncField() {
        if orbit.isEmpty {
            if !text.isEmpty { text = "" }
            seeded = ""
            completions = []
        } else if orbit.source == nil {
            if !orbit.trail.isEmpty { live = false }
            let origin = orbit.trail.first ?? orbit.centre
            guard origin != seeded else { return }
            // Seeded first, so the field's change reads as already followed.
            seeded = origin
            text = origin
            completions = []
        }
    }

    /// Return starts a new chain from the field, whatever was walked before (it stays in the history).
    private func submit() {
        focused = false
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, typed != orbit.centre || !orbit.trail.isEmpty else { return }
        live = true
        seeded = typed
        orbit.begin(typed, model: model)
    }

    private func complete(with word: String) {
        var words = text.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        if words.isEmpty { words = [word] } else { words[words.count - 1] = word }
        text = words.joined(separator: " ")
    }

    /// The field's own clear: the typed word goes, a chain walked from it stays.
    private func clear() {
        text = ""
        completions = []
        if orbit.trail.isEmpty, orbit.centre == seeded { orbit.clear() }
        seeded = ""
    }
}
