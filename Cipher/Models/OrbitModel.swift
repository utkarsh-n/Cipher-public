import Foundation
import Observation
import SwiftData

/// The associative state: one word at the centre, everything a step away around it, and the
/// chain of steps taken to get here. Shared by the Sphere tab, the sphere sheet and the editor.
/// Every chain is kept as a `ChainRecord`, saved after each step, so closing the app or starting
/// another chain never loses one; the one in hand comes back when the app opens.
@MainActor
@Observable
final class OrbitModel {
    /// The steps taken so far, oldest first; the centre is not in it.
    private(set) var trail: [String] = []
    private(set) var centre = ""
    private(set) var orbit: Orbit?
    /// A phrase splits into a sphere per word; index 0 is the whole phrase.
    private(set) var parts: [(word: String, orbit: Orbit)] = []
    var part = 0
    /// Claude's far jumps for the current centre.
    private(set) var leaps: [OrbitNode] = []
    private(set) var isLoading = false
    private(set) var isLeaping = false
    /// How each step of the chain reads, -1...1, for the colour under it.
    private(set) var feel: [String: Double] = [:]
    /// The Roman spelling of each step written in Devanagari or Gujarati.
    private(set) var romans: [String: String] = [:]
    /// The unwritten word between the centre and a node, once asked for.
    private(set) var bridges: [String: [String]] = [:]
    /// Nodes that lead toward one of the pinned words.
    private(set) var attracted: Set<String> = []
    /// The line of the lyric this chain was read from, so it can be written back there.
    private(set) var source: (range: NSRange, text: String)?
    /// The chain as kept on the phone; nil before anything has been walked.
    private(set) var record: ChainRecord?
    var problem: String?
    private var context: ModelContext?
    private var leapCentre = ""
    private var leapTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    /// Counts pin changes, so a slower answer for an earlier set of pins is dropped.
    private var attractGeneration = 0
    /// The family key of a classical word stepped onto (Latin lūx, *lewk-), read as exactly that.
    private var centreFamily: String?

    private static let currentKey = "orbit.currentChain"

    var isEmpty: Bool { centre.isEmpty }

    /// The chain in the writer's own notation.
    var chainText: String { (trail + [centre]).filter { !$0.isEmpty }.joined(separator: " : ") }

    /// Words pinned on this chain: the sphere marks every node that leads toward one.
    var pins: [String] { record?.pins ?? [] }

    /// The step Forward would take: one stepped back from and not yet replaced.
    var forwardStep: String? {
        guard let record, record.cursor < record.steps.count, record.cursor >= 0 else { return nil }
        return record.steps[record.cursor]
    }

    /// The word the sphere is showing: the whole phrase, or one of its words.
    var displayedCentre: String { part > 0 && parts.indices.contains(part - 1) ? parts[part - 1].word : centre }

    /// Its Roman spelling, when it is written in Devanagari or Gujarati.
    var displayedRoman: String {
        part > 0 && parts.indices.contains(part - 1) ? parts[part - 1].orbit.roman : orbit?.roman ?? ""
    }

    /// Every node around what is shown, Claude's leaps included.
    var nodes: [OrbitNode] {
        if part > 0, parts.indices.contains(part - 1) { return parts[part - 1].orbit.nodes }
        return (orbit?.nodes ?? []) + (leapCentre == centre ? leaps : [])
    }

    var echoes: Set<String> {
        part > 0 && parts.indices.contains(part - 1) ? parts[part - 1].orbit.echoes : orbit?.echoes ?? []
    }

    func nodes(in direction: OrbitDirection) -> [OrbitNode] {
        nodes.filter { $0.direction == direction }.sorted { $0.weight > $1.weight }
    }

    // MARK: Keeping

    /// Where chains are saved. Set once, before the app boots.
    func attach(_ context: ModelContext) {
        self.context = context
    }

    /// The chain that was in hand when the app last closed, back where it was left.
    func restore(model: AppModel) {
        guard isEmpty, let context, let raw = UserDefaults.standard.string(forKey: Self.currentKey), let id = UUID(uuidString: raw) else { return }
        var descriptor = FetchDescriptor<ChainRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let found = try? context.fetch(descriptor).first, !found.chain.isEmpty else { return }
        show(found, model: model)
    }

    /// Picks a chain up again from the history.
    func resume(_ chain: ChainRecord, model: AppModel) {
        source = nil
        show(chain, model: model)
    }

    /// Takes a chain out of the history; the one in hand goes with it.
    func forget(_ chain: ChainRecord) {
        if chain.id == record?.id { clear() }
        context?.delete(chain)
        try? context?.save()
    }

    private func show(_ chain: ChainRecord, model: AppModel) {
        record = chain
        remember(chain)
        let steps = chain.chain
        trail = Array(steps.dropLast())
        centre = steps.last ?? ""
        centreFamily = nil
        reload(model: model)
    }

    /// A record for a chain just begun. A one-word record nobody walked from is reused rather
    /// than kept: typing a word letter by letter should not leave a record per letter.
    private func start(_ steps: [String], origin: ChainRecord.Origin) {
        if let record, record.steps.count <= 1, !record.starred, record.pins.isEmpty {
            record.steps = steps
            record.cursor = steps.count
            record.origin = origin.rawValue
            record.createdAt = .now
            touch()
            return
        }
        let fresh = ChainRecord(steps: steps, origin: origin)
        context?.insert(fresh)
        record = fresh
        remember(fresh)
        touch()
    }

    private func remember(_ chain: ChainRecord) {
        UserDefaults.standard.set(chain.id.uuidString, forKey: Self.currentKey)
    }

    /// Saves at once: the app may be closed the moment after a step.
    private func touch() {
        record?.updatedAt = .now
        try? context?.save()
    }

    // MARK: Walking

    /// Start a chain afresh from a word. The chain in hand stays in the history.
    func begin(_ text: String, origin: ChainRecord.Origin = .sphere, model: AppModel) {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        trail = []
        source = nil
        centre = word
        centreFamily = nil
        start([word], origin: origin)
        reload(model: model)
    }

    /// Pick up a chain written in the lyric; the last step is the centre.
    func begin(chain items: [String], source line: (range: NSRange, text: String)?, model: AppModel) {
        guard let last = items.last else { return }
        source = line
        // A line the chain in hand began from (the walk went on past it) keeps the walk.
        if let record, record.steps.count >= items.count, Array(record.steps.prefix(items.count)) == items {
            show(record, model: model)
            return
        }
        trail = Array(items.dropLast())
        centre = last
        centreFamily = nil
        start(items, origin: .editor)
        reload(model: model)
    }

    /// Step to a node: the centre joins the chain, the node becomes the centre. Stepping
    /// somewhere new after going back starts a branch; the walk it left stays in the history.
    func go(to text: String, via direction: OrbitDirection? = nil, model: AppModel) {
        // Standing on it already (a pin of the centre, say) is not a step.
        guard !text.isEmpty, text != centre else { return }
        if let direction { model.learn(direction) }
        guard !centre.isEmpty else {
            begin(text, model: model)
            return
        }
        // A classical word from the roots is read as its own family, not as a modern word.
        let family = orbit?.classical[text] ?? parts.lazy.compactMap { $0.orbit.classical[text] }.first
        trail.append(centre)
        centre = text
        centreFamily = family
        if let record {
            if record.cursor < record.steps.count {
                if record.steps[record.cursor] == text {
                    record.cursor += 1
                } else {
                    let branch = ChainRecord(steps: Array(record.steps.prefix(record.cursor)) + [text], origin: record.originKind, pins: record.pins)
                    record.cursor = record.steps.count
                    context?.insert(branch)
                    self.record = branch
                    remember(branch)
                }
            } else {
                record.steps.append(text)
                record.cursor = record.steps.count
            }
            touch()
        } else {
            start(trail + [centre], origin: .sphere)
        }
        reload(model: model)
    }

    func back(model: AppModel) {
        guard let previous = trail.popLast() else { return }
        centre = previous
        centreFamily = nil
        if let record { record.cursor = max(1, record.cursor - 1) }
        touch()
        reload(model: model)
    }

    /// Takes again the step that Back undid.
    func forward(model: AppModel) {
        guard let next = forwardStep, let record else { return }
        trail.append(centre)
        centre = next
        centreFamily = nil
        record.cursor += 1
        touch()
        reload(model: model)
    }

    /// Jump back to an earlier step of the chain; the later steps wait behind Forward.
    func rewind(to index: Int, model: AppModel) {
        guard trail.indices.contains(index) else { return }
        centre = trail[index]
        centreFamily = nil
        trail.removeSubrange(index...)
        if let record { record.cursor = index + 1 }
        touch()
        reload(model: model)
    }

    /// Puts the chain down. It stays in the history if a step was taken; a lone word goes.
    func clear() {
        if let record, !record.isWalked, record.pins.isEmpty {
            context?.delete(record)
            try? context?.save()
        }
        record = nil
        UserDefaults.standard.removeObject(forKey: Self.currentKey)
        generation += 1
        leapTask?.cancel()
        trail = []
        centre = ""
        orbit = nil
        parts = []
        part = 0
        leaps = []
        bridges = [:]
        attracted = []
        source = nil
        isLoading = false
        isLeaping = false
        leapCentre = ""
    }

    // MARK: Pins

    func isPinned(_ word: String) -> Bool { pins.contains(word) }

    /// Keeps a word in view as the chain moves on: every node that leads toward it is marked.
    func pin(_ word: String, roman: String = "", model: AppModel) {
        guard !word.isEmpty, !isPinned(word) else { return }
        if record == nil { start(trail + [centre], origin: .sphere) }
        if !roman.isEmpty { romans[word] = roman }
        record?.pins.append(word)
        touch()
        Task { await attract(model: model) }
    }

    func unpin(_ word: String, model: AppModel) {
        record?.pins.removeAll { $0 == word }
        touch()
        Task { await attract(model: model) }
    }

    private func attract(model: AppModel) async {
        let pins = pins
        guard !pins.isEmpty else {
            attractGeneration += 1
            attracted = []
            return
        }
        let all = (orbit?.nodes ?? []) + leaps + parts.flatMap(\.orbit.nodes)
        attractGeneration += 1
        let mine = generation, asked = attractGeneration
        let found = await model.engine.attracted(all, to: pins, languages: model.languages)
        guard mine == generation, asked == attractGeneration else { return }
        attracted = found
    }

    // MARK: Reading

    /// Reads the sphere around the centre again, dropping a reading still under way.
    private func reload(model: AppModel) {
        refreshTask?.cancel()
        refreshTask = Task { await refresh(model: model) }
    }

    private func refresh(model: AppModel) async {
        generation += 1
        let mine = generation
        isLoading = true
        part = 0
        parts = []
        bridges = [:]
        attracted = []
        let scope = model.scope
        let word = centre
        let steps = trail
        let found = await model.engine.orbit(for: word, trail: steps, scope: scope, family: centreFamily)
        guard mine == generation else { return }
        if feel[word] == nil, let warmth = await model.engine.feel(of: word, languages: model.languages) { feel[word] = warmth }
        guard mine == generation else { return }
        if !found.roman.isEmpty { romans[word] = found.roman }
        // The engine's half shows at once; the culture index, which may still be loading
        // behind the UI after launch, adds its nodes when it answers.
        orbit = found
        isLoading = false
        // A phrase gets a sphere per word as well.
        let words = Tokenizer.words(in: word).filter { !VerseAnalyzer.functionWords.contains($0) }
        if words.count >= 2 {
            var split: [(String, Orbit)] = []
            for piece in words.prefix(4) {
                guard !Task.isCancelled else { return }
                let own = await model.engine.orbit(for: piece, trail: steps, scope: scope)
                guard mine == generation else { return }
                split.append((piece, own))
            }
            parts = split
        }
        let view = await model.culture.view(ideas: found.ideas, word: word, language: found.language,
                                            cultures: Culture.order(for: model.languages), weights: model.cultureWeights)
        guard mine == generation, var current = orbit else { return }
        var seen = Set(current.nodes.map(\.id))
        for hit in view.named.prefix(10) + view.about.prefix(14) + view.feeling.prefix(6) {
            var node = OrbitNode(text: hit.work.title, direction: .culture, weight: min(1, hit.score),
                                 why: hit.role == .named ? "named for it" : hit.role == .about ? "about \(hit.via)" : "feels like \(hit.via)",
                                 language: .english, aside: hit.work.yearLabel ?? "")
            node.vector = [0, 0, 0, min(1, hit.score), 0]
            if seen.insert(node.id).inserted { current.nodes.append(node) }
        }
        for neighbour in view.neighbours.prefix(12) {
            var node = OrbitNode(text: neighbour.theme, direction: .meaning, weight: neighbour.weight, why: "runs with", language: .english)
            node.vector = [0, 0, neighbour.weight, 0.5, 0]
            if seen.insert(node.id).inserted { current.nodes.append(node) }
        }
        orbit = current
        await attract(model: model)
    }

    /// The word between the centre and a node, found once and kept.
    func bridge(for node: OrbitNode, model: AppModel) {
        guard bridges[node.id] == nil else { return }
        let from = displayedCentre
        Task {
            let found = await model.engine.bridge(between: from, and: node.text, languages: model.languages)
            bridges[node.id] = found
        }
    }

    /// Claude's far jumps, fetched once per centre.
    func leap(model: AppModel) {
        guard !centre.isEmpty, leapCentre != centre else { return }
        // A new centre supersedes a request still in flight for the old one.
        leapTask?.cancel()
        isLeaping = true
        let word = centre, steps = trail
        leapTask = Task {
            defer { if word == centre { isLeaping = false } }
            do {
                let found = try await ClaudeClient().leaps(prompt: Prompts.leaps(centre: word, trail: steps, languages: model.languages), depth: model.depth)
                guard !Task.isCancelled, word == centre else { return }
                leaps = found.map { step in
                    var node = OrbitNode(text: step.text, direction: .leap, weight: max(0, min(1, step.weight)), why: "\(step.move): \(step.why)", language: .english)
                    node.vector = [0, 0, 0, 0, 0]
                    return node
                }
                if !found.isEmpty { leapCentre = word }
                await attract(model: model)
            } catch {
                if !Task.isCancelled, word == centre { problem = error.localizedDescription }
            }
        }
    }
}
