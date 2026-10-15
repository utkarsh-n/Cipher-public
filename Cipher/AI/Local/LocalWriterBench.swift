import Foundation

/// Launched with "-localwrite", Cipher runs the on-device writer on a few verses, with the same
/// path Assist takes, and leaves the suggestions and timings in Documents/localwrite.json for the
/// Mac to read. A check of the whole loop on the phone, without anyone tapping through it.
@MainActor
enum LocalWriterBench {
    static func runIfAsked(model: AppModel) async {
        guard ProcessInfo.processInfo.arguments.contains("-localwrite") else { return }
        let output = URL.documentsDirectory.appending(path: "localwrite.json")
        let cases: [(String, LocalWriter.Job, String, String, String?)] = [
            ("en next", .next, "Started from the corner with a dream and a flame\nEvery night on the block, they would whisper my name", "Every night on the block, they would whisper my name", "Every night on the block, they would whisper my name"),
            ("en forge", .forge, "I been grinding through the cold with my head to the sky", "moth : flame :: me : spotlight, burn, city lights, fame", "I been grinding through the cold with my head to the sky"),
            ("hinglish next", .next, "Raat bhar jaagta hoon, sapne mere bade\nShehar ki roshni mein, hum akele khade", "Shehar ki roshni mein, hum akele khade", "Shehar ki roshni mein, hum akele khade"),
            ("hindi next", .next, "रात की ख़ामोशी में दिल की बात\nतेरी यादों से रोशन है मेरी हर रात", "तेरी यादों से रोशन है मेरी हर रात", "तेरी यादों से रोशन है मेरी हर रात"),
            ("gujarati next", .next, "વરસાદની રાતે તારી યાદ આવી\nઆંખોમાં સપનાંની ભીની વાત લાવી", "આંખોમાં સપનાંની ભીની વાત લાવી", "આંખોમાં સપનાંની ભીની વાત લાવી"),
            ("spanish next", .next, "Camino solo por la calle del dolor\nbuscando en la noche un poco de calor", "buscando en la noche un poco de calor", "buscando en la noche un poco de calor"),
        ]
        var results: [[String: Any]] = []
        func save() {
            let report: [String: Any] = ["model": model.local.state == .idle ? "" : "\(model.local.state)", "cases": results]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output)
            }
        }
        for (name, job, verse, anchor, target) in cases {
            let started = Date()
            let palette = await model.engine.palette(for: target ?? anchor, context: target ?? anchor, scope: model.scope)
            let request = LocalWriter.Request(job: job, verse: verse, anchor: anchor, rhymeTarget: target, syllables: 11,
                                              palette: palette, references: [], direction: "", languages: model.languages)
            do {
                let suggestions = try await LocalWriter.suggestions(request, model: model.local, engine: model.engine)
                results.append(["case": name, "seconds": Date().timeIntervalSince(started), "palette": Array(palette.prefix(10)),
                                "suggestions": suggestions.map { ["text": $0.text, "note": $0.note] }])
            } catch {
                results.append(["case": name, "error": error.localizedDescription])
            }
            save()
        }
        results.append(["finished": true, "footprint": LocalModel.footprint, "available": LocalModel.availableMemory])
        save()
    }
}
