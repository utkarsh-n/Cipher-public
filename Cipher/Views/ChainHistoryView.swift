import SwiftData
import SwiftUI

/// Every chain walked, newest first, starred ones on top. Tap one to stand in it again, right
/// where it was left; swipe to star or forget it.
struct ChainHistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ChainRecord.updatedAt, order: .reverse) private var records: [ChainRecord]
    @State private var search = ""
    /// Called when a chain leaves for the editor, so a sheet showing the sphere can close too.
    var onLeave: (() -> Void)?

    private var walked: [ChainRecord] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return records.filter { $0.isWalked && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || $0.pins.contains { $0.localizedCaseInsensitiveContains(query) }) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if walked.isEmpty {
                    ContentUnavailableView {
                        Label(search.isEmpty ? "No chains yet" : "Nothing matches", systemImage: "clock.arrow.circlepath")
                    } description: {
                        Text(search.isEmpty ? "Every chain you walk in the sphere is kept here, step by step, even when the app is closed." : "Try another word from the chain.")
                    }
                } else {
                    List {
                        let starred = walked.filter(\.starred)
                        if !starred.isEmpty {
                            Section("Starred") {
                                ForEach(starred) { row($0) }
                            }
                        }
                        Section(starred.isEmpty ? "" : "Recent") {
                            ForEach(walked.filter { !$0.starred }) { row($0) }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.ink)
            .navigationTitle("Chains")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "A word in the chain")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ record: ChainRecord) -> some View {
        let isCurrent = record.id == model.orbit.record?.id
        return Button {
            model.orbit.resume(record, model: model)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                // The chain as it stands, with the steps stepped back from fainter after it.
                (Text(record.chain.joined(separator: " : ")).foregroundStyle(.primary)
                 + Text(record.cursor < record.steps.count ? " : " + record.steps.dropFirst(record.cursor).joined(separator: " : ") : "").foregroundStyle(.tertiary))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Image(systemName: record.originKind.symbol)
                    Text("\(record.steps.count) steps")
                    if !record.pins.isEmpty {
                        Label(record.pins.joined(separator: ", "), systemImage: "pin.fill").lineLimit(1)
                    }
                    Spacer()
                    if isCurrent {
                        Text("in hand").foregroundStyle(Theme.accent)
                    }
                    Text(record.updatedAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button(record.starred ? "Unstar" : "Star", systemImage: record.starred ? "star.slash" : "star.fill") {
                record.starred.toggle()
                try? context.save()
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing) {
            Button("Forget", systemImage: "trash", role: .destructive) { model.orbit.forget(record) }
        }
        .contextMenu {
            Button("Copy chain", systemImage: "doc.on.doc") { UIPasteboard.general.string = record.chain.joined(separator: " : ") }
            Button("Start a song with it", systemImage: "pencil.line") { sendToEditor(record) }
            Button(record.starred ? "Unstar" : "Star", systemImage: record.starred ? "star.slash" : "star") {
                record.starred.toggle()
                try? context.save()
            }
            Button("Forget", systemImage: "trash", role: .destructive) { model.orbit.forget(record) }
        }
    }

    private func sendToEditor(_ record: ChainRecord) {
        let song = Song(title: record.steps.first ?? "", text: record.chain.joined(separator: " : "))
        context.insert(song)
        model.openSong = song
        model.tab = .write
        dismiss()
        onLeave?()
    }
}
