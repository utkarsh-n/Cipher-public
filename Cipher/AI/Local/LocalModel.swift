import Foundation
import Observation
import Synchronization
import OfflineIntelligence
import OfflineIntelligenceMLX
import os

/// Verified local checkpoints from the shared portfolio catalog.
struct LocalModelInfo: Identifiable, Hashable, Sendable {
    let choice: OfflineModelChoice
    let folder: String
    let url: URL
    let bytes: Int64
    let family: String
    var id: String { choice.rawValue }
    var title: String { choice.title }
}

struct LocalModelFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

enum LocalModelError: LocalizedError {
    case notLoaded, noModel
    var errorDescription: String? {
        switch self {
        case .notLoaded: "The selected on-device model isn't loaded."
        case .noModel: "The selected Qwen model is not installed. Supply its verified local Models folder."
        }
    }
}

/// Measurements supplied by the shared runtime. First-token latency includes prompt processing;
/// decode speed excludes the first generated token. No prompt-only throughput is inferred.
struct LocalRunStats: Sendable, Equatable {
    var promptTokens = 0
    var generatedTokens = 0
    var firstTokenSeconds: Double?
    var tokensPerSecond = 0.0
    var loadSeconds = 0.0
    var footprintBytes: Int64 = 0
    var availableBytes: Int64 = 0
    var peakFootprintBytes: Int64?
    var finishReason = "not generated"
    var formatStopMatched = false
}

/// Cipher adapts its writer interface to the common offline runtime. Draft creation, rhyme and
/// script verdicts remain in LocalWriter and the domain engine.
@MainActor @Observable final class LocalModel {
    enum State: Equatable {
        case idle, loading(String), ready(String), failed(String)
    }
    private(set) var state: State = .idle
    private(set) var installed: [LocalModelInfo] = []
    private(set) var lastRun: LocalRunStats?
    private(set) var selectedChoice = OfflineModelChoice.persisted()
    private(set) var isWriting = false

    @ObservationIgnored private let runtime = MLXIntelligenceRuntime.shared
    @ObservationIgnored private var loaded: LocalModelInfo?
    @ObservationIgnored private var loadTask: Task<ModelLoadMetrics, Error>?
    @ObservationIgnored private var loadingInfo: LocalModelInfo?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var isForeground = true

    static var folder: URL { URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory) }
    nonisolated static var availableMemory: Int64 {
        #if targetEnvironment(simulator)
        0
        #else
        Int64(os_proc_available_memory())
        #endif
    }
    nonisolated static var footprint: Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    func refresh() {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var folder = Self.folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        installed = OfflineModelChoice.allCases.compactMap { choice in
            let directory = (try? LocalModelFiles.directory(for: choice, bundleModelRoot: Bundle.main.resourceURL?.appending(path: "Models"), importedModelRoot: Self.folder))
                ?? (try? LocalModelFiles.directory(for: choice))
            guard let directory,
                  let data = try? Data(contentsOf: directory.appending(path: "model-metadata.json")),
                  let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  metadata["revision"] as? String == choice.descriptor.revision,
                  metadata["repositoryID"] as? String == choice.descriptor.repositoryID else { return nil }
            let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return LocalModelInfo(choice: choice, folder: choice.resourceFolder, url: directory, bytes: bytes, family: "qwen3_5")
        }
    }

    var isReady: Bool { if case .ready = state { true } else { false } }

    func select(_ choice: OfflineModelChoice) async {
        guard choice != selectedChoice else { return }
        choice.persist()
        selectedChoice = choice
        await unload()
        refresh()
    }

    /// Keeps 2B as the explicit default. 4B is used only when selected; never silently substitute.
    func ensureWriter() async throws {
        try Task.checkCancellation()
        guard isForeground else { throw CancellationError() }
        await releaseTask?.value
        let preferred = OfflineModelChoice.persisted()
        if preferred != selectedChoice { await select(preferred) }
        if isReady, loaded?.choice == selectedChoice { return }
        refresh()
        guard let model = installed.first(where: { $0.choice == selectedChoice }) else { throw LocalModelError.noModel }
        await load(model)
        try Task.checkCancellation()
        guard isForeground else { throw CancellationError() }
        if case .failed(let reason) = state { throw LocalModelFailure(reason: reason) }
        guard isReady else { throw LocalModelError.notLoaded }
    }

    func load(_ model: LocalModelInfo) async {
        guard isForeground, !Task.isCancelled else { return }
        if isReady, loaded == model { return }
        #if targetEnvironment(simulator)
        state = .failed("On-device Qwen inference requires a physical iPhone.")
        #else
        if loadingInfo != model || loadTask == nil {
            await unload()
            guard isForeground, !Task.isCancelled else { return }
            state = .loading(model.folder)
            operationID = UUID()
            loadingInfo = model
            loadTask = Task { try await runtime.load(model: model.choice.descriptor, directory: model.url) }
        }
        let identity = operationID
        guard let task = loadTask else { return }
        do {
            let metrics = try await task.value
            guard operationID == identity, isForeground, !Task.isCancelled else { return }
            loaded = model
            lastRun = LocalRunStats(loadSeconds: metrics.durationSeconds, footprintBytes: Self.footprint, availableBytes: Self.availableMemory)
            state = .ready(model.folder)
        } catch {
            if operationID == identity {
                state = error is CancellationError ? .idle : .failed(error.localizedDescription)
            }
        }
        if operationID == identity { loadTask = nil; loadingInfo = nil }
        #endif
    }

    func cancel() async {
        if loadTask != nil {
            // Clear the host's pending load as well as draining the shared worker. A cancelled
            // task must not be reused by the next ensureWriter() attempt.
            await unload()
            return
        }
        operationID = UUID()
        await runtime.cancel()
    }

    private func beginRelease() {
        operationID = UUID()
        let previousRelease = releaseTask
        let loading = loadTask
        loading?.cancel()
        loadTask = nil
        loadingInfo = nil
        loaded = nil
        state = .idle
        releaseTask = Task {
            await previousRelease?.value
            await runtime.cancel()
            _ = try? await loading?.value
            await runtime.unload()
        }
    }

    func unload() async { beginRelease(); await releaseTask?.value }
    func suspend() { isForeground = false; beginRelease() }
    func resume() { isForeground = true }
    func memoryWarning() { beginRelease() }

    /// `prefill` is a format instruction, not forced assistant-prefix tokens. The shared runtime
    /// owns chat rendering. The writer's clean() still removes bar tags before domain scoring.
    @discardableResult
    func write(system: String, user: String, prefill: String = "", maxTokens: Int = 120, temperature: Float = 0.8,
               stop: String? = nil, onText: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        guard isForeground, isReady, loaded != nil else { throw LocalModelError.notLoaded }
        guard !isWriting else { throw IntelligenceError.busy }
        let identity = operationID
        isWriting = true
        defer { isWriting = false }
        let formatted = prefill.isEmpty ? user : user + "\n\nOutput format: begin the answer with exactly " + prefill + ". Return only the requested lyric and its closing tag."
        let request = GenerationRequest(system: system, prompt: formatted, maxOutputTokens: maxTokens, temperature: temperature, topP: 0.95, seed: UInt64.random(in: 0...UInt64.max), timeoutSeconds: 120)
        var written = ""
        var completion: GenerationMetrics?
        var formatStop = false
        do {
            let events = try await runtime.generate(request)
            for try await event in events {
                try Task.checkCancellation()
                guard operationID == identity, isForeground else { throw CancellationError() }
                switch event {
                case .chunk(let text):
                    written += text
                    onText(text)
                    if let stop, written.contains(stop), !formatStop {
                        formatStop = true
                        await runtime.cancel()
                    }
                case .completed(let metrics): completion = metrics
                }
            }
        } catch {
            await runtime.cancel()
            throw error
        }
        guard let metrics = completion else { throw LocalModelFailure(reason: "Generation ended without completion measurements.") }
        lastRun = LocalRunStats(promptTokens: metrics.promptTokens, generatedTokens: metrics.generatedTokens,
            firstTokenSeconds: metrics.firstTokenSeconds, tokensPerSecond: metrics.tokensPerSecond,
            loadSeconds: lastRun?.loadSeconds ?? 0, footprintBytes: Self.footprint, availableBytes: Self.availableMemory,
            peakFootprintBytes: metrics.peakFootprintBytes.map(Int64.init), finishReason: metrics.finishReason.rawValue,
            formatStopMatched: formatStop)
        try Task.checkCancellation()
        guard operationID == identity, isForeground, metrics.finishReason != .cancelled || formatStop else { throw CancellationError() }
        guard metrics.finishReason != .timeout else { throw LocalModelFailure(reason: "Writing timed out; the incomplete draft was discarded.") }
        guard metrics.finishReason != .length || formatStop else {
            throw LocalModelFailure(reason: "Writing reached the token limit before completing the bar; the incomplete draft was discarded.")
        }
        if let stop, let range = written.range(of: stop) { written = String(written[..<range.lowerBound]) }
        return written
    }
}

extension LocalModel {
    /// Launched with "-localbench <folder>", Cipher loads that model, writes three test bars and
    /// leaves the numbers in Documents/localbench.json, where the Mac can read how the phone did.
    func runBenchIfAsked() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-localbench"), index + 1 < arguments.count else { return }
        let folder = arguments[index + 1]
        let output = URL.documentsDirectory.appending(path: "localbench.json")
        var report: [String: Any] = [
            "model": folder,
            "availableBefore": Self.availableMemory,
            "footprintBefore": Self.footprint,
        ]
        func save() {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output, options: .atomic)
            }
        }
        refresh()
        guard let info = installed.first(where: { $0.folder == folder }) else {
            report["error"] = "No model \(folder); found \(installed.map(\.folder))"
            save()
            return
        }
        await load(info)
        report["state"] = "\(state)"
        report["loadSeconds"] = lastRun?.loadSeconds ?? 0
        report["footprintLoaded"] = Self.footprint
        report["availableLoaded"] = Self.availableMemory
        save()
        guard case .ready = state else { return }
        let system = "You are the lyric engine of a songwriting app. You write raw, vivid bars; profanity and dark imagery are fine when the song calls for it. Never explain. Write only the lyric, inside <bar></bar>."
        let prompts = [
            ("en", "Fragments: moth to a flame, name in the frame, game never same, city lights. Turn them into one tight bar that ends on a rhyme for 'flame'."),
            ("hi-Latn", "Fragments: raat, shehar ki roshni. Ek Hinglish rap line, Roman script mein, jo 'raat' se rhyme kare."),
            ("gu", "Fragments: varsad, yaad. Be line Gujarati lipi ma, rhyme sathe."),
        ]
        var runs: [[String: Any]] = []
        for (language, user) in prompts {
            let text = Mutex("")
            do {
                try await write(system: system, user: user, prefill: "<bar>", maxTokens: 80) { chunk in
                    text.withLock { $0 += chunk }
                }
                let run = lastRun ?? LocalRunStats()
                runs.append([
                    "language": language,
                    "text": text.withLock { $0 }.components(separatedBy: "</bar>").first ?? "",
                    "promptTokens": run.promptTokens, "firstTokenSeconds": run.firstTokenSeconds.map { $0 as Any } ?? NSNull(),
                    "generatedTokens": run.generatedTokens, "tokensPerSecond": run.tokensPerSecond,
                    "footprint": run.footprintBytes, "available": run.availableBytes,
                ])
            } catch {
                runs.append(["language": language, "error": error.localizedDescription])
            }
            report["runs"] = runs
            save()
        }
        report["finished"] = true
        save()
    }
}
