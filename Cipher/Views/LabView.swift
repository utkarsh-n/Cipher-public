import SwiftData
import SwiftUI

/// Take one word or phrase apart by sound and by meaning, across every language in play.
struct LabView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    /// The language to read the text in, when the writer or a tapped chip has said so.
    @State private var forced: Language?
    @State private var keepForced = false
    @State private var lookup: Lookup?
    @State private var culture: CultureView?
    @State private var openWork: Work?
    @State private var showOrbit = false
    @FocusState private var focused: Bool

    private static let starters = ["orange", "yaar", "zindagi", "પ્રેમ", "corazón", "amour", "lyrical miracle", "ice cream"]

    private struct Key: Equatable {
        let text: String
        let forced: Language?
        let scope: Scope
        let weights: CultureWeights
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    searchField
                    Picker("Looseness", selection: $model.looseness) {
                        ForEach(Looseness.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if let lookup {
                        results(lookup)
                    } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
                        starters
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.ink)
            .navigationTitle("Lab")
        }
        .task(id: Key(text: text, forced: forced, scope: model.scope, weights: model.cultureWeights)) {
            let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                lookup = nil
                culture = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let result = await model.engine.lookup(query, as: forced, scope: model.scope)
            guard !Task.isCancelled else { return }
            lookup = result
            culture = nil
            guard let result else { return }
            // Titles are tried with the word as typed and in its own script; themes with its meanings.
            let found = await model.culture.view(ideas: result.ideas + (result.native.isEmpty ? [] : [result.native]), word: result.text,
                                                 language: result.language, cultures: Culture.order(for: model.languages), weights: model.cultureWeights)
            guard !Task.isCancelled else { return }
            culture = found
        }
        .sheet(item: $openWork) { WorkSheet(work: $0) }
        .sheet(isPresented: $showOrbit) { OrbitView() }
        .onChange(of: text) {
            // Typing something new lets the app decide the language again.
            if keepForced { keepForced = false } else { forced = nil }
        }
        .onChange(of: model.labQuery, initial: true) {
            guard let query = model.labQuery else { return }
            open(query.text, as: query.language)
            model.labQuery = nil
        }
    }

    private func open(_ word: String, as language: Language?) {
        keepForced = word != text
        forced = language
        text = word
    }

    private func open(_ hit: RhymeHit) { open(hit.word, as: hit.language) }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("A word or phrase, any language", text: $text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.panelStroke))
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rhymes, sound-alikes, meanings and signs for anything you type, across \(model.languages.map(\.name).formatted(.list(type: .and))). Try one:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            FlowLayout {
                ForEach(Self.starters, id: \.self) { word in
                    WordChip(title: word, tint: Theme.accent) { open(word, as: nil) }
                }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func results(_ lookup: Lookup) -> some View {
        let exact = lookup.homophones.filter { $0.score >= 1 }
        let near = lookup.homophones.filter { $0.score < 1 }

        header(lookup)

        if !lookup.translations.isEmpty {
            SectionCard(title: "Means", subtitle: "The same sense in your other languages") {
                LanguageClouds(hits: lookup.translations, tint: Color(Theme.highlighter(6)), initial: 6, onTap: open)
            }
        }
        if !lookup.roots.isEmpty {
            RootsCard(reading: lookup.roots, onOpen: open)
        }
        if let culture, !culture.isEmpty {
            CultureSection(view: culture, onWork: { openWork = $0 }, onTheme: { theme in
                model.labQuery = AppModel.LabQuery(text: theme, language: .english)
            })
        }
        if !lookup.perfect.isEmpty {
            SectionCard(title: "Perfect rhymes", count: lookup.perfect.count) {
                LanguageClouds(hits: lookup.perfect, tint: Theme.accent, onTap: open)
            }
        }
        if !lookup.slant.isEmpty {
            SectionCard(title: "Slant rhymes", subtitle: "Same vowels, neighbouring consonants", count: lookup.slant.count) {
                LanguageClouds(hits: lookup.slant, tint: Color(Theme.highlighter(1)), onTap: open)
            }
        }
        if !lookup.multis.isEmpty {
            SectionCard(title: "Multis", subtitle: "Matching the last several vowel sounds in a row") {
                ForEach(lookup.multis) { group in
                    Text("\(group.syllables)-syllable match").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    LanguageClouds(hits: group.hits, tint: Color(Theme.highlighter(2)), initial: 8, onTap: open)
                }
            }
        }
        if !lookup.mosaics.isEmpty {
            SectionCard(title: "Mosaic", subtitle: "Build the same sound from two words: one from each row") {
                ForEach(lookup.mosaics) { mosaic in
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(mosaic.slots.enumerated()), id: \.offset) { index, slot in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    Text("\(index + 1)").font(.caption2.monospaced().bold()).foregroundStyle(.secondary)
                                    ForEach(slot) { hit in
                                        HitChip(hit: hit, tint: Color(Theme.highlighter(3))) { open(hit) }
                                    }
                                }
                            }
                        }
                    }
                    if mosaic.id != lookup.mosaics.last?.id { Divider() }
                }
            }
        }
        if !exact.isEmpty {
            SectionCard(title: "Homophones", subtitle: "A different word with the identical sound") {
                LanguageClouds(hits: exact, tint: Color(Theme.highlighter(4)), onTap: open)
            }
        }
        if !lookup.soundAlikes.isEmpty || !near.isEmpty {
            SectionCard(title: "Sound-alikes", subtitle: "The same stream of sound heard another way") {
                if !lookup.soundAlikes.isEmpty {
                    FlowLayout {
                        ForEach(lookup.soundAlikes, id: \.self) { phrase in
                            WordChip(title: phrase, tint: Color(Theme.highlighter(4))) { open(phrase, as: nil) }
                        }
                    }
                }
                if !near.isEmpty {
                    LanguageClouds(hits: near, tint: Color(Theme.highlighter(4)), initial: 8, onTap: open)
                }
            }
        }
        if !lookup.consonance.isEmpty {
            SectionCard(title: "Consonance", subtitle: "Same consonants, different vowels") {
                LanguageClouds(hits: lookup.consonance, tint: Color(Theme.highlighter(5)), initial: 10, onTap: open)
            }
        }
        if !lookup.frontRhymes.isEmpty {
            SectionCard(title: "Front rhymes", subtitle: "Same opening sound, for alliteration") {
                LanguageClouds(hits: lookup.frontRhymes, tint: Color(Theme.highlighter(6)), initial: 10, onTap: open)
            }
        }
        if !lookup.related.isEmpty {
            SectionCard(title: "Associations", subtitle: model.looseness == .loose ? "Close and lateral connections" : "Words that live near this one", count: lookup.related.count) {
                LanguageClouds(hits: lookup.related, tint: Color(Theme.highlighter(7)), onTap: open)
            }
        }
        MeaningsCard(lookup: lookup) { word, language in open(word, as: language) }
    }

    @ViewBuilder
    private func header(_ lookup: Lookup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(lookup.native.isEmpty ? lookup.text : lookup.native).font(.title.bold())
                if !lookup.roman.isEmpty, lookup.roman != lookup.native {
                    Text(lookup.roman).font(.title3).foregroundStyle(.secondary)
                }
            }
            if lookup.readings.count > 1 {
                HStack(spacing: 6) {
                    Text("Read as").font(.caption).foregroundStyle(.secondary)
                    ForEach(lookup.readings) { language in
                        let selected = language == lookup.language
                        Button(language.name) { forced = language }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selected ? Theme.ink : Color.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(selected ? Theme.accent : Color.white.opacity(0.08), in: Capsule())
                            .buttonStyle(.plain)
                    }
                }
            } else {
                Text(lookup.language.name).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            if !lookup.gloss.isEmpty {
                Text(lookup.gloss).font(.subheadline)
            }
            Text(lookup.phonemes).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("\(lookup.syllables) syllable\(lookup.syllables == 1 ? "" : "s")\(lookup.known ? "" : " · pronunciation guessed from spelling")")
                .font(.caption)
                .foregroundStyle(lookup.known ? Color.secondary : Color.orange)
            Button("Stand inside it", systemImage: "circle.hexagonpath") {
                // The walk already begun from this word carries on; anything else starts afresh.
                if model.orbit.record?.steps.first != lookup.text { model.orbit.begin(lookup.text, origin: .lab, model: model) }
                showOrbit = true
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.top, 2)
            if !lookup.signs.isEmpty {
                SignStrip(tokens: lookup.signs, height: 60)
                    .padding(.top, 6)
            }
        }
    }
}

/// Where a word comes from: the Latin, Greek or Sanskrit word behind it, the deeper root under
/// that, and the words in every language that grew from the same place.
struct RootsCard: View {
    let reading: RootReading
    let onOpen: (RhymeHit) -> Void

    var body: some View {
        SectionCard(title: "Roots", subtitle: "What it grew from, and what else grew from there") {
            ForEach(reading.etyma) { step in
                origin(step.family)
                if !step.siblings.isEmpty {
                    LanguageClouds(hits: step.siblings, tint: Color(Theme.highlighter(7)), initial: 8, onTap: onOpen)
                }
            }
            ForEach(reading.roots) { step in
                origin(step.family).padding(.top, reading.etyma.isEmpty ? 0 : 6)
                if !step.siblings.isEmpty {
                    LanguageClouds(hits: step.siblings, tint: Color(Theme.highlighter(7)).opacity(0.8), initial: 8, onTap: onOpen)
                }
            }
        }
    }

    private func origin(_ family: RootIndex.Family) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: family.isRoot ? "tree" : "leaf").font(.caption).foregroundStyle(Color(Theme.highlighter(7)))
                Text(family.form).font(.headline)
                if !family.roman.isEmpty, family.roman != family.form {
                    Text(family.roman).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(family.isRoot ? "\(family.source.short) root" : family.source.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if !family.gloss.isEmpty {
                Text(family.gloss).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Claude's reading of a word: its equivalents elsewhere, what it symbolises, and the words in
/// other languages it could be mistaken for. Answers are saved, so each word is asked once.
struct MeaningsCard: View {
    let lookup: Lookup
    let onOpen: (String, Language?) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @State private var meanings: Meanings?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var request: Task<Void, Never>?

    private var word: String { lookup.native.isEmpty ? lookup.text : lookup.native }
    private var key: String { "\(lookup.language.code):\(word)" }

    var body: some View {
        SectionCard(title: "Deeper", subtitle: "What it stands for, how your other languages say it, and what it can be mistaken for. Written by Claude.") {
            if let meanings {
                answer(meanings)
            }
            if !model.hasAPIKey {
                Button("Add API key") { showSettings = true }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.ink)
            } else {
                Button(action: ask) {
                    HStack {
                        if isWorking { ProgressView().tint(Theme.ink) }
                        Text(isWorking ? "Thinking…" : meanings == nil ? "Unpack \(word)" : "Ask again").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Theme.ink)
                .disabled(isWorking)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
        .task(id: key) {
            request?.cancel()
            isWorking = false
            errorMessage = nil
            meanings = saved()
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    @ViewBuilder
    private func answer(_ meanings: Meanings) -> some View {
        if !meanings.symbolic.isEmpty {
            Text("Stands for").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(meanings.symbolic) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.image).font(.subheadline.weight(.semibold))
                    Text(item.note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if !meanings.literal.isEmpty {
            Text("In other words").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(meanings.literal) { row($0) }
        }
        if !meanings.wordplay.isEmpty {
            Text("Sounds like").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(meanings.wordplay) { row($0) }
        }
    }

    private func row(_ item: Meanings.Word) -> some View {
        Button {
            onOpen(item.word, Language.allCases.first { $0.name.caseInsensitiveCompare(item.language) == .orderedSame })
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.word).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    if !item.roman.isEmpty { Text(item.roman).font(.caption).foregroundStyle(.secondary) }
                    Text(item.language).font(.caption2).foregroundStyle(.tertiary)
                }
                Text(item.note).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func saved() -> Meanings? {
        let key = key
        var descriptor = FetchDescriptor<MeaningNote>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let note = try? context.fetch(descriptor).first else { return nil }
        return try? JSONDecoder().decode(Meanings.self, from: note.payload)
    }

    private func ask() {
        let key = key
        let word = word
        let lookup = lookup
        let languages = model.languages
        let culture = model.culture
        let depth = model.depth
        isWorking = true
        errorMessage = nil
        request?.cancel()
        request = Task {
            do {
                let references = await culture.references(for: lookup.ideas, cultures: Culture.order(for: languages))
                let prompt = Prompts.meanings(word: word, roman: lookup.roman, gloss: lookup.gloss, language: lookup.language, languages: languages, references: references)
                let (answer, data) = try await ClaudeClient().meanings(prompt: prompt, depth: depth)
                guard !Task.isCancelled else { return }
                var descriptor = FetchDescriptor<MeaningNote>(predicate: #Predicate { $0.key == key })
                descriptor.fetchLimit = 1
                if let existing = try? context.fetch(descriptor).first {
                    existing.payload = data
                    existing.createdAt = .now
                } else {
                    context.insert(MeaningNote(key: key, payload: data))
                }
                meanings = answer
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
