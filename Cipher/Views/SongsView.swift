import SwiftData
import SwiftUI

struct SongsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppModel.self) private var model
    @Query(sort: \Song.updatedAt, order: .reverse) private var songs: [Song]
    @State private var path: [Song] = []
    @State private var showSettings = false
    @State private var showImport = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if songs.isEmpty {
                    ContentUnavailableView {
                        Label("No songs yet", systemImage: "music.note.list")
                    } description: {
                        Text("Start a verse. Rhymes light up as you write.")
                    } actions: {
                        Button("New song", action: newSong).buttonStyle(.borderedProminent).foregroundStyle(Theme.ink)
                        Button("Write out a track", systemImage: "waveform") { showImport = true }
                    }
                } else {
                    List {
                        ForEach(songs) { song in
                            NavigationLink(value: song) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        if song.isTranscribed {
                                            Image(systemName: "waveform").font(.caption).foregroundStyle(Theme.accent)
                                        } else if !song.artist.isEmpty {
                                            // Words looked up by name, with no recording behind them.
                                            Image(systemName: "music.note").font(.caption).foregroundStyle(Theme.accent)
                                        }
                                        Text(song.displayTitle).font(.headline)
                                        if !song.artist.isEmpty {
                                            Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    Text(song.firstLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                    Text(song.updatedAt, format: .relative(presentation: .named))
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { context.delete(songs[index]) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .navigationTitle("Cipher")
            .navigationDestination(for: Song.self) { EditorView(song: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Write out a track", systemImage: "waveform") { showImport = true }
                    Button("New song", systemImage: "square.and.pencil", action: newSong)
                }
            }
            .onChange(of: model.openSong, initial: true) {
                // A song made elsewhere (the sphere's chain) opens here.
                if let song = model.openSong {
                    path.append(song)
                    model.openSong = nil
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showImport) {
                ImportSheet { song in path.append(song) }
            }
        }
    }

    private func newSong() {
        let song = Song()
        context.insert(song)
        path.append(song)
    }
}
