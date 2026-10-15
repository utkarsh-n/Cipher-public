import SwiftData
import SwiftUI

@main
struct CipherApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .modelContainer(for: [Song.self, MeaningNote.self, ChainRecord.self])
    }
}
