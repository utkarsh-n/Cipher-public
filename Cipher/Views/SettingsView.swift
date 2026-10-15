import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""

    private func weight(_ title: String, _ detail: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2))).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: 0...1)
        }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    ForEach(Array(model.languageOrder.enumerated()), id: \.element) { index, language in
                        HStack(spacing: 12) {
                            Toggle(isOn: Binding(get: { model.enabled.contains(language) }, set: { model.setEnabled(language, $0) })) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(language.name)
                                    if language.nativeName != language.name {
                                        Text(language.nativeName).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Button("Move up", systemImage: "chevron.up") { model.move(language, by: -1) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                            Button("Move down", systemImage: "chevron.down") { model.move(language, by: 1) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .disabled(index == model.languageOrder.count - 1)
                        }
                    }
                    Picker("Hindi and Gujarati shown in", selection: $model.scriptDisplay) {
                        ForEach(ScriptDisplay.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("ASL signs while writing", isOn: $model.showSigns)
                } header: {
                    Text("Languages")
                } footer: {
                    Text("Results come from the languages switched on, listed in this order; the order also settles which language an ambiguous word is read in. Hindi and Gujarati are understood in their own scripts and in Roman letters. Signs are chosen by meaning from a community ASL dictionary written in SignWriting, and words without a sign are fingerspelled.")
                }

                Section {
                    weight("Literal", "the work is named for the word", $model.cultureWeights.literal)
                    weight("Figurative", "the word is a theme, an image, or what it stands for", $model.cultureWeights.figurative)
                    weight("Subjective", "the word is how it feels", $model.cultureWeights.subjective)
                    Picker("Era", selection: $model.cultureWeights.era) {
                        ForEach(CultureWeights.Era.allCases) { Text($0.label).tag($0) }
                    }
                    weight("Kinship", "how alike two works must be to be shown as relatives", $model.cultureWeights.kinship)
                } header: {
                    Text("Culture")
                } footer: {
                    Text("When you look a word up, the Lab ranks films, shows, sport and writing by how the word touches them. These set how much each kind of connection counts, which years to favour, and how strong a link has to be before a work from another culture is listed as its relative.")
                }

                Section {
                    if model.hasAPIKey {
                        Label("API key saved", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                        Button("Remove key", role: .destructive) { model.removeAPIKey() }
                    } else {
                        SecureField("sk-ant-...", text: $keyDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save key") {
                            model.saveAPIKey(keyDraft)
                            keyDraft = ""
                        }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Picker("Depth", selection: $model.depth) {
                        ForEach(AssistDepth.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Claude")
                } footer: {
                    Text("Assist, the Bridge's metaphor writer and the Lab's Deeper card send the verse or word you're working on to Anthropic's API with your key (console.anthropic.com), which is stored in this device's keychain. Deeper thinking writes tighter bars but takes longer and costs more. Everything else in Cipher runs on this phone.")
                }

                Section {
                    NavigationLink("On-device model") { LocalModelView() }
                } header: {
                    Text("Writing model")
                } footer: {
                    Text("A language model that runs on this phone with no network: which models are here, how much memory iOS allows, and a timed test bar.")
                }

                Section {
                    Picker("Default looseness", selection: $model.looseness) {
                        ForEach(Looseness.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Names and rare words", isOn: $model.includeRare)
                } header: {
                    Text("Rhymes")
                } footer: {
                    Text("Strict keeps to true rhymes and close associations. Loose lets vowels drift and reaches for more lateral connections. Names and rare words adds surnames, places, brands and inflections nobody was seen using.")
                }

                Section("About") {
                    Text("English pronunciations: CMU Pronouncing Dictionary (BSD). Hindi and Gujarati words and meanings: Wiktionary via kaikki.org (CC BY-SA). Spanish and French meanings: WikDict (CC BY-SA). French pronunciations: Lexique 3.83 (CC BY-SA). Word frequencies: OpenSubtitles lists by Hermit Dave and the Leipzig Corpora Collection (CC BY). ASL signs: SignPuddle (CC BY-SA), drawn with the Sutton SignWriting fonts (OFL). Culture index: Wikidata (CC0) and Wikipedia (CC BY-SA), with themes for the best-known works written by Claude. Lines in use: Project Gutenberg and Wikisource (public domain). Roots: English Wiktionary (CC BY-SA) via kaikki.org, Tatu Ylonen, \"Wiktextract\", LREC 2022. Songs and the links between them: Wikidata (CC0), Wikipedia (CC BY-SA), MusicBrainz (CC0) and ItwoFS.com, Inspirations in Indian Film Songs (CC BY 2.5, itwofs.com); facts only, no lyrics. Word associations use Apple's on-device language model.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
