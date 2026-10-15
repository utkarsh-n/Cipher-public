import Foundation
import Observation

enum AppTab: String, Hashable { case write, sphere, lab, bridge }

/// How hard Claude thinks before answering; maps onto the API's effort levels.
enum AssistDepth: String, CaseIterable, Identifiable {
    case low, medium, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: "Quick"
        case .medium: "Balanced"
        case .high: "Deep"
        }
    }
}

/// How Hindi and Gujarati words are shown.
enum ScriptDisplay: String, CaseIterable, Identifiable {
    case both, native, roman

    var id: String { rawValue }

    var label: String {
        switch self {
        case .both: "Both"
        case .native: "Native script"
        case .roman: "Roman letters"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case loading, ready, failed(String) }

    let engine = Engine()
    let culture = CultureStore()
    /// The associative state: the chain being walked and the sphere around its last step.
    let orbit = OrbitModel()
    /// The writing model that runs on the phone itself.
    let local = LocalModel()
    var phase: Phase = .loading
    var tab: AppTab = AppTab(rawValue: UserDefaults.standard.string(forKey: "tab") ?? "") ?? .write {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "tab") }
    }
    /// Set to send a word to the Lab from elsewhere in the app.
    var labQuery: LabQuery?
    /// A word to show in the system dictionary.
    var defining: String?
    /// A song another screen wants opened in the editor (a chain sent from the sphere).
    var openSong: Song?

    struct LabQuery: Equatable {
        var text: String
        var language: Language?
    }

    var looseness: Looseness {
        didSet { UserDefaults.standard.set(looseness.rawValue, forKey: "looseness") }
    }
    var includeRare: Bool {
        didSet { UserDefaults.standard.set(includeRare, forKey: "includeRare") }
    }
    var depth: AssistDepth {
        didSet { UserDefaults.standard.set(depth.rawValue, forKey: "assistDepth") }
    }
    /// Every language in the writer's order of preference; `enabled` says which are in play.
    var languageOrder: [Language] {
        didSet { UserDefaults.standard.set(languageOrder.map(\.code), forKey: "languageOrder") }
    }
    var enabled: Set<Language> {
        didSet { UserDefaults.standard.set(enabled.map(\.code), forKey: "languagesEnabled") }
    }
    var scriptDisplay: ScriptDisplay {
        didSet { UserDefaults.standard.set(scriptDisplay.rawValue, forKey: "scriptDisplay") }
    }
    /// Whether the editor shows the bar being written as ASL signs.
    var showSigns: Bool {
        didSet { UserDefaults.standard.set(showSigns, forKey: "showSigns") }
    }
    var hasAPIKey: Bool
    /// How often the writer has stepped in each direction of the sphere. The sphere leans the
    /// way he walks: it opens facing his favourite direction and shows more of his favourites.
    var directionCounts: [String: Int] {
        didSet { UserDefaults.standard.set(directionCounts, forKey: "directionCounts") }
    }
    /// How the culture index ranks works for a word.
    var cultureWeights: CultureWeights {
        didSet {
            let defaults = UserDefaults.standard
            defaults.set(cultureWeights.literal, forKey: "weightLiteral")
            defaults.set(cultureWeights.figurative, forKey: "weightFigurative")
            defaults.set(cultureWeights.subjective, forKey: "weightSubjective")
            defaults.set(cultureWeights.era.rawValue, forKey: "weightEra")
            defaults.set(cultureWeights.kinship, forKey: "weightKinship")
        }
    }

    /// The languages in play, in order.
    var languages: [Language] { languageOrder.filter(enabled.contains) }

    var scope: Scope { Scope(languages: languages, looseness: looseness, includeRare: includeRare) }

    init() {
        let defaults = UserDefaults.standard
        looseness = Looseness(rawValue: defaults.object(forKey: "looseness") as? Int ?? 1) ?? .balanced
        includeRare = defaults.bool(forKey: "includeRare")
        depth = AssistDepth(rawValue: defaults.string(forKey: "assistDepth") ?? "") ?? .medium
        var order = (defaults.stringArray(forKey: "languageOrder") ?? []).compactMap(Language.init(code:))
        // A language added in an update joins the end of a saved order.
        order += Language.allCases.filter { !order.contains($0) }
        languageOrder = order
        let saved = defaults.stringArray(forKey: "languagesEnabled")?.compactMap(Language.init(code:))
        let switchedOn = Set(saved ?? Language.allCases)
        enabled = switchedOn.isEmpty ? [.english] : switchedOn
        scriptDisplay = ScriptDisplay(rawValue: defaults.string(forKey: "scriptDisplay") ?? "") ?? .both
        showSigns = defaults.object(forKey: "showSigns") as? Bool ?? true
        hasAPIKey = Keychain.apiKey != nil
        directionCounts = defaults.dictionary(forKey: "directionCounts") as? [String: Int] ?? [:]
        var weights = CultureWeights()
        if defaults.object(forKey: "weightLiteral") != nil {
            weights.literal = defaults.double(forKey: "weightLiteral")
            weights.figurative = defaults.double(forKey: "weightFigurative")
            weights.subjective = defaults.double(forKey: "weightSubjective")
            weights.era = CultureWeights.Era(rawValue: defaults.string(forKey: "weightEra") ?? "") ?? .any
            weights.kinship = defaults.double(forKey: "weightKinship")
        }
        cultureWeights = weights
    }

    func boot() async {
        guard phase != .ready else { return }
        guard let lexicon = Bundle.main.url(forResource: "lexicon", withExtension: "bin") else {
            phase = .failed("The dictionary is missing from the app bundle.")
            return
        }
        do {
            try await engine.load(lexicon: lexicon, signs: Bundle.main.url(forResource: "signs", withExtension: "tsv"),
                                  hinges: Bundle.main.url(forResource: "hinges", withExtension: "tsv"))
            phase = .ready
            // The chain in hand when the app last closed comes back where it was left.
            orbit.restore(model: self)
            // The culture index is larger and not needed to start writing; it loads behind the UI.
            let store = culture
            let works = Bundle.main.url(forResource: "culture-works", withExtension: "tsv")
            let lines = Bundle.main.url(forResource: "culture-lines", withExtension: "tsv")
            let themes = Bundle.main.url(forResource: "culture-themes", withExtension: "tsv")
            Task.detached(priority: .utility) { await store.load(works: works, lines: lines, themes: themes) }
            let engine = engine
            let roots = Bundle.main.url(forResource: "roots", withExtension: "tsv")
            Task.detached(priority: .utility) { await engine.loadRoots(roots) }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// One more step taken in a direction.
    func learn(_ direction: OrbitDirection) {
        directionCounts[direction.rawValue, default: 0] += 1
    }

    /// The directions the writer steps in most, most used first; empty until he has walked a
    /// little, so a few early taps do not set the sphere's habits.
    var favouriteDirections: [OrbitDirection] {
        guard directionCounts.values.reduce(0, +) >= 8 else { return [] }
        return OrbitDirection.allCases
            .filter { $0 != .home && (directionCounts[$0.rawValue] ?? 0) > 0 }
            .sorted { (directionCounts[$0.rawValue] ?? 0) > (directionCounts[$1.rawValue] ?? 0) }
    }

    func lookUp(_ hit: RhymeHit) {
        labQuery = LabQuery(text: hit.word, language: hit.language)
        tab = .lab
    }

    func setEnabled(_ language: Language, _ on: Bool) {
        if on {
            enabled.insert(language)
        } else if enabled.count > 1 {
            enabled.remove(language)
        }
    }

    func move(_ language: Language, by offset: Int) {
        guard let index = languageOrder.firstIndex(of: language) else { return }
        let target = index + offset
        guard languageOrder.indices.contains(target) else { return }
        languageOrder.swapAt(index, target)
    }

    func saveAPIKey(_ key: String) {
        Keychain.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        hasAPIKey = Keychain.apiKey != nil
    }

    func removeAPIKey() {
        Keychain.apiKey = nil
        hasAPIKey = false
    }
}

extension RhymeHit {
    /// What to show for the word, given how the writer wants Hindi and Gujarati displayed.
    func title(_ display: ScriptDisplay) -> String {
        display == .roman && !roman.isEmpty ? roman : word
    }

    /// The other script, shown small beside the title.
    func aside(_ display: ScriptDisplay) -> String? {
        display == .both && !roman.isEmpty && roman != word ? roman : nil
    }

    /// The first meaning, for a tooltip or caption.
    var shortGloss: String { gloss.split(separator: ";").first.map(String.init) ?? "" }
}
