import SwiftUI
import OfflineIntelligence

/// The on-device model's bench: which models are on the phone, what memory iOS allows, and a test
/// bar written with the loaded one, timed. A preview while the writing tools are built on it.
struct LocalModelView: View {
    @Environment(AppModel.self) private var model
    @State private var fragments = "moth to a flame, name in the frame, game never same, city lights"
    @State private var output = ""
    @State private var writing = false
    @State private var problem: String?
    @State private var request: Task<Void, Never>?
    @AppStorage(OfflineModelChoice.preferenceKey) private var modelChoiceRaw = OfflineModelChoice.defaultChoice.rawValue

    private var local: LocalModel { model.local }

    private static func gigabytes(_ bytes: Int64) -> String {
        (Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(2))) + " GB"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Memory iOS allows now", value: Self.gigabytes(LocalModel.availableMemory))
                LabeledContent("Cipher is using", value: Self.gigabytes(LocalModel.footprint))
            } header: {
                Text("This phone")
            } footer: {
                Text("The selected checkpoint must fit within iOS's current memory allowance. The shared runtime checks available headroom before loading.")
            }

            Section {
                Picker("Writing model", selection: $modelChoiceRaw) {
                    ForEach(OfflineModelChoice.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(writing)
                Text((OfflineModelChoice(rawValue: modelChoiceRaw) ?? .defaultChoice).detail)
                    .font(.caption).foregroundStyle(.secondary)
                if local.installed.isEmpty {
                    Text("No verified Qwen checkpoints are installed. Model files can be bundled or copied over from the Mac.").foregroundStyle(.secondary)
                }
                ForEach(local.installed) { info in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.title).foregroundStyle(.primary)
                                Text("\(info.family) · \(Self.gigabytes(info.bytes))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            switch local.state {
                            case .loading(let folder) where folder == info.folder:
                                ProgressView()
                            case .ready(let folder) where folder == info.folder:
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                            default:
                                EmptyView()
                            }
                        }
                }
                Button("Load selected model") {
                    Task {
                        do { try await local.ensureWriter() }
                        catch { problem = error.localizedDescription }
                    }
                }
                .disabled(writing)
                if case .failed(let reason) = local.state {
                    Label(reason, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                if case .ready = local.state {
                    Button("Unload", role: .destructive) { Task { await local.unload() } }
                }
            } header: {
                Text("Models on this phone")
            }

            if case .ready = local.state {
                Section {
                    TextField("Fragments", text: $fragments, axis: .vertical)
                    Button(writing ? "Stop writing" : "Forge a bar") {
                        if writing {
                            request?.cancel()
                            Task { await local.cancel() }
                        } else { request = Task { await forge() } }
                    }
                    .disabled(!writing && fragments.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !output.isEmpty {
                        Text(output).font(.body.italic())
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Try it")
                } footer: {
                    Text("Written on this phone with no network. The rhyme engine does not steer it yet; that comes next.")
                }
            }

            if let run = local.lastRun {
                Section("Last run") {
                    LabeledContent("Load", value: run.loadSeconds.formatted(.number.precision(.fractionLength(1))) + " s")
                    if run.generatedTokens > 0 {
                        LabeledContent("Prompt", value: "\(run.promptTokens) tokens")
                        if let first = run.firstTokenSeconds {
                            LabeledContent("First token, including prompt", value: first.formatted(.number.precision(.fractionLength(2))) + " s")
                        }
                        LabeledContent("Decode", value: "\(run.generatedTokens) tokens, \(run.tokensPerSecond.formatted(.number.precision(.fractionLength(1)))) tok/s")
                        LabeledContent("Finish", value: run.formatStopMatched ? "Closing bar tag reached" : run.finishReason)
                        if let peak = run.peakFootprintBytes { LabeledContent("Sampled peak process", value: Self.gigabytes(peak)) }
                    }
                    LabeledContent("Cipher's memory", value: Self.gigabytes(run.footprintBytes))
                    LabeledContent("Still allowed", value: Self.gigabytes(run.availableBytes))
                }
            }
        }
        .navigationTitle("On-device model")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { local.refresh() }
        .onChange(of: modelChoiceRaw) { _, raw in
            Task { await local.select(OfflineModelChoice(rawValue: raw) ?? .defaultChoice) }
        }
        .onDisappear {
            request?.cancel()
            Task { await local.cancel() }
        }
    }

    private func forge() async {
        writing = true
        output = ""
        problem = nil
        defer { writing = false }
        let system = "You are the lyric engine of a songwriting app. You write raw, vivid bars; profanity and dark imagery are fine when the song calls for it. Never explain. Write only the lyric, inside <bar></bar>."
        let user = "Fragments: \(fragments). Turn them into one tight bar."
        let collected = Collected()
        do {
            try await local.write(system: system, user: user, prefill: "<bar>", maxTokens: 80) { text in
                Task { @MainActor in
                    collected.text += text
                    output = LocalWriter.clean(collected.text) ?? ""
                }
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The text streamed so far, gathered on the main actor.
@MainActor
private final class Collected {
    var text = ""
}
