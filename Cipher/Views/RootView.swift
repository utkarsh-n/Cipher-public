import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .loading:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Loading the dictionary").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.ink)
            case .failed(let message):
                ContentUnavailableView("Couldn't start", systemImage: "exclamationmark.triangle", description: Text(message))
            case .ready:
                TabView(selection: $model.tab) {
                    Tab("Write", systemImage: "pencil.line", value: AppTab.write) { SongsView() }
                    Tab("Sphere", systemImage: "circle.hexagonpath", value: AppTab.sphere) { SphereTabView() }
                    Tab("Lab", systemImage: "waveform", value: AppTab.lab) { LabView() }
                    Tab("Bridge", systemImage: "arrow.triangle.merge", value: AppTab.bridge) { BridgeView() }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // iOS gives apps no GPU in the background, and a model in memory there is the first
            // thing the system would end the app for.
            if phase == .background { model.local.suspend() }
            if phase == .active { model.local.resume() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.local.memoryWarning()
        }
        .task {
            // Chains are kept in the app's store, so the one in hand survives a closed app.
            model.orbit.attach(context)
            await model.boot()
            await model.local.runBenchIfAsked()
            await LocalWriterBench.runIfAsked(model: model)
        }
        .sheet(item: Binding(get: { model.defining.map(DefinedTerm.init) }, set: { model.defining = $0?.term })) { item in
            DictionaryView(term: item.term)
        }
    }

    private struct DefinedTerm: Identifiable {
        let term: String
        var id: String { term }
    }
}
