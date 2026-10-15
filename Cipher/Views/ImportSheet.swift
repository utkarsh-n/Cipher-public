import AVFoundation
import MediaPlayer
import SwiftData
import SwiftUI

/// Brings a track in and writes its words out as bars. The words are found by name when they
/// can be (the track's own lyrics tag, else LRCLIB), which is how an Apple Music stream gets
/// written out at all; a recording the phone may read is listened to as well, so its delivery
/// can be read, or listened to instead when nothing comes up by name.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let onOpen: (Song) -> Void

    private enum Step { case choose, search, recording, finding, words, language, listening, preview }

    @State private var step = Step.choose
    @State private var recording: Recording?
    /// The words found by name, when they were.
    @State private var found: FoundLyrics?
    @State private var finding = ""
    @State private var findingNote = ""
    @State private var query = ""
    @State private var matches: [FoundLyrics] = []
    @State private var searching = false
    @State private var searched = false
    @State private var searchProblem: String?
    /// Why the search was opened for the writer: a track whose words were not found by its name.
    @State private var searchNote: String?
    /// Bumped to ask again with the text unchanged (the Search key, Try again).
    @State private var searchAttempt = 0
    /// The text last sent, so asking again skips the pause that waits out typing.
    @State private var lastSearched = ""
    /// The library track being written out, when there is one: what the search starts from and
    /// how long the words found should run.
    @State private var track: TrackName?
    /// Whether a match picked in the search goes with the track's own recording.
    @State private var searchKeepsRecording = false
    /// Why the words found are shown as they are: untimed, or probably another version.
    @State private var wordsNote: String?
    /// The writer left a library track's lookup for the search before it finished; its audio
    /// copy, when there is one, goes behind whatever is picked there.
    @State private var byNameInstead = false
    /// Which search run is the latest, so an older one finishing does not stop its spinner.
    @State private var searchRun = 0
    @State private var nowPlayingTitle: String?
    /// Why the phone is listening rather than reading: nothing came up by name.
    @State private var note: String?
    @State private var options: [LyricTranscriber.Option] = []
    @State private var choice: LyricTranscriber.Option?
    @State private var stage = TranscriptionStage.preparing
    @State private var bars: [BarBuilder.Bar] = []
    @State private var words: [HeardWord] = []
    /// The delivery read against the bars heard, and the one read against the lines found by name.
    @State private var delivery: SongDelivery?
    @State private var wordsDelivery: SongDelivery?
    /// The recording made it into a song, so its file stays.
    @State private var kept = false
    @State private var recorder: AVAudioRecorder?
    @State private var recordingSince: Date?
    @State private var problem: String?
    @State private var showMusicPicker = false
    @State private var showFilePicker = false
    @FocusState private var searchFocused: Bool
    /// The lookup, copy or transcription under way, cancelled if the sheet goes away.
    @State private var job: Task<Void, Never>?
    private let transcriber = LyricTranscriber()

    private struct TrackName {
        var title: String
        var artist: String
        var length: Double
        /// What the search box starts from.
        var query: String { LyricsLookup.searchText(title: title, artist: artist) }
        /// Whether there is a name to start a search from: a track with no title has none.
        var seedsSearch: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .choose: choose
                case .search: search
                case .recording: recordingStep
                case .finding: findingStep
                case .words: wordsStep
                case .language: language
                case .listening: listening
                case .preview: preview
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.ink)
            .navigationTitle("Write out a track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { job?.cancel(); dismiss() } }
            }
            .onDisappear {
                job?.cancel()
                // A take still being recorded when the sheet goes is stopped and thrown away, and
                // the music it interrupted is told it can play again.
                if let recorder {
                    recorder.stop()
                    recorder.deleteRecording()
                    self.recorder = nil
                    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                }
                // A copy or take that never became a song is not kept on disk.
                if !kept { discardRecording() }
            }
            .task {
                options = await LyricTranscriber.options(for: model.languages)
                choice = options.first
            }
            .sheet(isPresented: $showMusicPicker) {
                MusicPicker { item in
                    showMusicPicker = false
                    if let item { take(item) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showFilePicker) {
                AudioFilePicker { url in
                    showFilePicker = false
                    if let url { take(file: url) }
                }
                .ignoresSafeArea()
            }
            .alert("Couldn't use that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK") {}
            } message: {
                Text(problem ?? "")
            }
        }
    }

    // MARK: Steps

    private var choose: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick a track and its words come up as bars, the rhymes lit up like something you wrote. The words are found by the track's name; a track you own as a file is also listened to on this device, so how it was delivered can be read.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            source("From your music library", "Any track, Apple Music included.", "music.note.list") {
                Task {
                    guard await MediaImport.requestLibraryAccess() else {
                        problem = ImportError.denied.errorDescription
                        return
                    }
                    showMusicPicker = true
                }
            }
            source("Playing now in Music", nowPlayingTitle ?? "Whatever Music has on right now.", "play.circle") {
                Task {
                    guard await MediaImport.requestLibraryAccess() else {
                        problem = ImportError.denied.errorDescription
                        return
                    }
                    guard let item = MediaImport.nowPlaying else {
                        problem = "Nothing is playing in Music right now. Start the track there, then come back."
                        return
                    }
                    take(item)
                }
            }
            source("Find a song by name", "Title and artist; the words come from LRCLIB, a community lyric library.", "text.magnifyingglass") {
                searched = false
                searchNote = nil
                searchProblem = nil
                track = nil
                searchKeepsRecording = false
                step = .search
            }
            source("An audio file", "From Files, iCloud Drive, AirDrop or a recording of your own.", "waveform") { showFilePicker = true }
            source("Record a take", "Say or sing it now; the words and the delivery both get read.", "mic.fill") { Task { await startRecording() } }
            Spacer()
        }
        .padding(16)
        .task { nowPlayingTitle = MediaImport.nowPlaying.map { "Playing now: \($0.title ?? "Untitled")" } }
    }

    private func source(_ title: String, _ detail: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Theme.accent).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    /// A song looked for by name, in LRCLIB; pick one of what comes back.
    private var search: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Title and artist", text: $query)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        // The same search already on its way is not sent twice.
                        guard !(searching && text == lastSearched) else { return }
                        lastSearched = text
                        searchAttempt += 1
                    }
                if searching { ProgressView().tint(Theme.accent) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.panelStroke))
            Text("Words come from LRCLIB, a community library of lyrics, many of them timed line by line. Only what you type here is sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let searchProblem {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(searchProblem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Button("Try again") { searchAttempt += 1 }
                        .font(.footnote.weight(.semibold))
                        .disabled(searching)
                }
            } else if let searchNote {
                Label(searchNote, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
            if searchProblem == nil, searched, matches.isEmpty, !searching, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                if let track, track.seedsSearch, query == track.query {
                    // The artist is already in the search: LRCLIB simply lacks the song.
                    Text("LRCLIB has no words for “\(track.title)”\(track.artist.isEmpty ? "" : " by \(track.artist)"). If you have them, paste them in.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Nothing by that name. Try the artist's name alongside the title.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(matches) { match in
                        Button {
                            use(match)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(match.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                                    Text([match.artist, match.album].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if let track, track.length > 0, match.duration > 0, match.fits(track.length) {
                                    Text("same length").font(.caption2).foregroundStyle(Theme.accent)
                                }
                                if match.synced {
                                    Label("timed", systemImage: "clock").font(.caption2).foregroundStyle(Theme.accent)
                                }
                                if match.duration > 0 {
                                    Text(Playback.clock(match.duration)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                }
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            HStack(spacing: 16) {
                // Words the writer already has (from a booklet, a site, a friend) open the same way.
                PasteButton(payloadType: String.self) { pasted in
                    let text = pasted.joined(separator: "\n")
                    Task { @MainActor in paste(text) }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                Spacer()
                Button("Another source") { step = .choose }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .onAppear { searchFocused = true }
        .task(id: "\(searchAttempt)|\(query)") { await lookForMatches() }
    }

    private var recordingStep: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "mic.fill").font(.system(size: 44)).foregroundStyle(.red).symbolEffect(.pulse, isActive: true)
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(Playback.clock(recordingSince.map { context.date.timeIntervalSince($0) } ?? 0))
                    .font(.title.monospacedDigit())
            }
            Text("Recording. Keep it close to the mic; a dry vocal reads best.").font(.caption).foregroundStyle(.secondary)
            Button {
                stopRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            Spacer()
        }
        .padding(16)
    }

    private var findingStep: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "text.magnifyingglass").font(.system(size: 44)).foregroundStyle(Theme.accent).symbolEffect(.pulse, isActive: true)
            Text("“\(finding)”").font(.headline).multilineTextAlignment(.center)
            Text(findingNote).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 16) {
                if track != nil {
                    Button("Find it by name instead") {
                        if recording == nil {
                            // Still looking: the lookup gives way, but the track's audio, when it
                            // can be read, is still copied to go behind the words picked.
                            byNameInstead = true
                        } else {
                            job?.cancel()
                        }
                        openSearch(note: nil, keepingRecording: true)
                    }
                }
                Button("Another source") {
                    job?.cancel()
                    step = .choose
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    /// The words found by name, timed when they were, before they open in the editor.
    @ViewBuilder
    private var wordsStep: some View {
        if let found {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(found.title).font(.title3.bold())
                    if !found.artist.isEmpty { Text(found.artist).foregroundStyle(.secondary) }
                }
                Text("\(found.lines.filter { !$0.text.isEmpty }.count) lines, \(found.credit)\(recording == nil ? ". No recording to play; the words stand on their own." : found.synced ? "." : ". The recording plays behind them, but the bars are not timed; Listen instead to time them.")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let wordsNote {
                    Label(wordsNote, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                }
                if let wordsDelivery, !wordsDelivery.styleWords.isEmpty {
                    Text("Delivered " + wordsDelivery.styleWords.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.accent)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(found.lines.enumerated()), id: \.offset) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                if let start = line.start, !line.text.isEmpty {
                                    Text(Playback.clock(start))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 34, alignment: .trailing)
                                }
                                if !line.text.isEmpty, let felt = wordsDelivery?.bar(index) {
                                    BarGlyph(bar: felt).frame(width: 34, height: 16)
                                }
                                Text(line.text.isEmpty ? " " : line.text).font(.callout)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                HStack(spacing: 10) {
                    if recording != nil {
                        Button("Listen instead") { note = nil; step = .language }
                            .buttonStyle(.bordered)
                    }
                    Button {
                        open(found)
                    } label: {
                        Label("Open in the editor", systemImage: "pencil.line").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(Theme.ink)
                }
                // The wrong song, or the wrong source: another search, or back to the start.
                HStack(spacing: 16) {
                    if track != nil {
                        Button("Not these words? Search by name") { openSearch(note: nil, keepingRecording: true) }
                    }
                    Button("Another source") { step = .choose }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .padding(16)
        } else {
            choose
        }
    }

    private func startRecording() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = "Cipher was not allowed to use the microphone. You can change that in Settings."
            return
        }
        // A library track's lookup still running must not land on this take.
        job?.cancel()
        discardRecording()
        found = nil
        track = nil
        wordsDelivery = nil
        delivery = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = Song.audioFolder.appendingPathComponent(UUID().uuidString + ".m4a")
            let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.record()
            self.recorder = recorder
            recordingSince = .now
            step = .recording
        } catch {
            problem = error.localizedDescription
        }
    }

    private func stopRecording() {
        guard let recorder else { return }
        recorder.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let stamp = Date.now.formatted(date: .abbreviated, time: .shortened)
        recording = Recording(url: recorder.url, title: "Take \(stamp)", artist: "")
        self.recorder = nil
        recordingSince = nil
        found = nil
        note = nil
        step = .language
    }

    private var language: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let recording {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recording.title).font(.title3.bold())
                    if !recording.artist.isEmpty { Text(recording.artist).foregroundStyle(.secondary) }
                }
            }
            if let note {
                Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(.orange)
            }
            if options.isEmpty {
                Text(TranscriptionError.unavailable.localizedDescription).foregroundStyle(.secondary)
            } else {
                Text("Sung in").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FlowLayout {
                    ForEach(options) { option in
                        Button(option.label) { choice = option }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(choice == option ? Theme.ink : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(choice == option ? Theme.accent : Color.white.opacity(0.08), in: Capsule())
                            .buttonStyle(.plain)
                    }
                }
                Text("A track that switches languages comes out best in the one it is mostly in. The first time a language is used, its speech model is downloaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    step = .listening
                    job = Task { await listen() }
                } label: {
                    Label("Write it out", systemImage: "waveform.and.mic")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(Theme.ink)
                .disabled(choice == nil)
            }
            HStack(spacing: 16) {
                if found != nil {
                    Button("Back to the words found by name") { step = .words }
                } else if track != nil, recording != nil {
                    // The words by name after all, with this recording kept behind them.
                    Button("Find the words by name") { openSearch(note: nil, keepingRecording: true) }
                }
                Button("Another source") { step = .choose }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
    }

    private var listening: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(Theme.accent).symbolEffect(.variableColor.iterative, isActive: true)
            switch stage {
            case .preparing:
                Text("Reading the recording…")
            case .downloading:
                Text("Downloading the speech model for \(choice?.label ?? "this language")…")
                Text("Once per language; it stays on the phone.").font(.caption).foregroundStyle(.secondary)
            case .listening(let fraction):
                Text("Listening…")
                ProgressView(value: fraction).tint(Theme.accent).padding(.horizontal, 40)
            case .done:
                Text("Laying out the bars and reading the delivery…")
            }
            Spacer()
        }
        .padding(16)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let recording {
                Text("\(bars.count) bars heard in “\(recording.title)”").font(.subheadline.weight(.semibold))
                if let delivery, !delivery.styleWords.isEmpty {
                    Text("Delivered " + delivery.styleWords.joined(separator: ", ")).font(.caption).foregroundStyle(Theme.accent)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Playback.clock(bar.start))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 34, alignment: .trailing)
                            if let felt = delivery?.bar(index) {
                                BarGlyph(bar: felt).frame(width: 34, height: 16)
                            }
                            Text(bar.text).font(.callout)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            HStack(spacing: 10) {
                Button("Another language") { step = .language }
                    .buttonStyle(.bordered)
                Button {
                    open()
                } label: {
                    Label("Open in the editor", systemImage: "pencil.line").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .foregroundStyle(Theme.ink)
            }
        }
        .padding(16)
    }

    // MARK: Work

    /// A library track: its words by name and its audio, both at once; whichever came back
    /// decides what happens next.
    private func take(_ item: MPMediaItem) {
        // An earlier track's lookup still running must not land on this one.
        job?.cancel()
        byNameInstead = false
        let title = item.title ?? ""
        let named = TrackName(title: title, artist: item.artist ?? "", length: item.playbackDuration)
        track = named
        finding = title.isEmpty ? "Untitled" : title
        findingNote = "Finding the words…"
        found = nil
        discardRecording()
        wordsDelivery = nil
        delivery = nil
        note = nil
        wordsNote = nil
        searchKeepsRecording = false
        step = .finding
        job = Task {
            async let lyrics = Self.attempt { try await LyricsLookup.lyrics(for: item) }
            async let audio = Self.attempt { try await MediaImport.copy(item) }
            let (byName, nameProblem) = await lyrics
            let (copy, _) = await audio
            guard !Task.isCancelled else {
                if let copy { try? FileManager.default.removeItem(at: copy.url) }
                return
            }
            if byNameInstead {
                // The writer went to the search while this ran: only the audio copy is still
                // wanted, behind the words picked there, if the search is still open.
                if let copy {
                    if step == .search, recording == nil {
                        recording = copy
                        searchKeepsRecording = true
                    } else {
                        try? FileManager.default.removeItem(at: copy.url)
                    }
                }
                return
            }
            if let raw = byName {
                let (byName, why) = fitted(raw, to: item.playbackDuration)
                wordsNote = why
                found = byName
                recording = copy
                if let copy, byName.synced {
                    // The words are timed, so the recording can be read against them.
                    findingNote = "Reading how it was delivered…"
                    wordsDelivery = try? await model.engine.delivery(audio: copy.url, bars: byName.lines.map { ($0.text, $0.start ?? 0) }, words: [], languages: model.languages)
                    guard !Task.isCancelled else { return }
                }
                step = .words
            } else if let copy {
                // Nothing by name, but the phone can still listen.
                recording = copy
                note = (nameProblem ?? "No words were found by name.") + " The phone will listen to the recording instead."
                step = .language
            } else {
                // No words by name and no audio to listen to (an Apple Music stream): the search,
                // started from the track's own name, where another spelling or artist can be tried.
                openSearch(note: nameProblem ?? "No words were found by name.", keepingRecording: false)
            }
        }
    }

    /// Runs the work and hands back what it made, or why it could not.
    private static func attempt<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async -> (T?, String?) {
        do {
            return (try await work(), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func take(file url: URL) {
        job?.cancel()
        do {
            discardRecording()
            recording = try MediaImport.copy(file: url)
            track = nil
            found = nil
            wordsDelivery = nil
            delivery = nil
            note = nil
            step = .language
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The search by name, started from the library track's own name.
    private func openSearch(note: String?, keepingRecording: Bool) {
        if let track, track.seedsSearch { query = track.query }
        searchNote = note
        searchProblem = nil
        matches = []
        searched = false
        searchKeepsRecording = keepingRecording && recording != nil
        step = .search
    }

    /// Words as they should open against a track `length` seconds long. Timed lines from a cut
    /// of another length would sit against the wrong seconds, so they lose their times; words
    /// from a much longer or shorter cut are probably another version's. Either way a note says so.
    private func fitted(_ words: FoundLyrics, to length: Double) -> (FoundLyrics, String?) {
        guard words.source == .lrclib, length > 0, words.duration > 0 else { return (words, nil) }
        let gap = abs(words.duration - length)
        let lengths = "These words run \(Playback.clock(words.duration)) and this track \(Playback.clock(length))"
        if words.synced, gap > 3 { return (words.untimed, lengths + ", so they are probably another version's; the bars are left untimed.") }
        if gap > 10 { return (words, lengths + ", so they may be another version's.") }
        return (words, nil)
    }

    /// Words the writer pasted in, laid out like words found by name.
    private func paste(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = (LyricsLookup.looksTimed(text) ? LyricsLookup.parse(lrc: text) : LyricsLookup.parse(plain: text)).map(LyricsLookup.readable)
        guard !lines.isEmpty else { return }
        let title = track.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? "Pasted words"
        use(FoundLyrics(id: 0, title: title, artist: track?.artist ?? "", album: "", duration: 0, lines: lines, source: .pasted))
    }

    /// Removes the recording's copy from the app's folder, when it is one the sheet made.
    private func discardRecording() {
        if let recording, recording.url.path.hasPrefix(Song.audioFolder.path) {
            try? FileManager.default.removeItem(at: recording.url)
        }
        recording = nil
    }

    private func lookForMatches() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchProblem = nil
        guard !text.isEmpty else {
            matches = []
            searched = false
            return
        }
        // Typing is waited out; the Search key, Try again and a text already sent go at once.
        if text != lastSearched {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
        }
        lastSearched = text
        searchRun += 1
        let run = searchRun
        searching = true
        defer { if run == searchRun { searching = false } }
        do {
            var results: [FoundLyrics]
            if let track, track.seedsSearch, text == track.query {
                // Started from a track: its title with each credited name, closest to it first.
                results = try await LyricsLookup.search(forTitle: track.title, artist: track.artist, duration: track.length)
            } else {
                results = try await LyricsLookup.search(text)
                if let track { results = LyricsLookup.rank(results, title: track.title, artist: track.artist, duration: track.length) }
            }
            guard !Task.isCancelled else { return }
            matches = results
            searched = true
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            // What an earlier search found is not this one's answer.
            matches = []
            searchProblem = error.localizedDescription
        }
    }

    private func use(_ match: FoundLyrics) {
        wordsDelivery = nil
        delivery = nil
        wordsNote = nil
        var words = match
        if let track {
            // Words looked for on a library track's behalf go under its name, checked against
            // its length.
            let fit = fitted(match, to: track.length)
            words = fit.0
            wordsNote = fit.1
            if !track.title.isEmpty { words.title = track.title }
        }
        guard searchKeepsRecording, let recording, let track else {
            found = words
            discardRecording()
            step = .words
            return
        }
        // Words for a track whose recording the phone has: they go with it, and when they are
        // timed for its length the delivery is read against them.
        if !track.artist.isEmpty { words.artist = track.artist }
        found = words
        guard words.synced else {
            step = .words
            return
        }
        finding = words.title
        findingNote = "Reading how it was delivered…"
        step = .finding
        let bars = words.lines.map { ($0.text, $0.start ?? 0) }
        job = Task {
            let read = try? await model.engine.delivery(audio: recording.url, bars: bars, words: [], languages: model.languages)
            guard !Task.isCancelled else { return }
            wordsDelivery = read
            step = .words
        }
    }

    private func listen() async {
        guard let recording, let choice else { return }
        stage = .preparing
        do {
            let heard = try await transcriber.transcribe(recording.url, locale: choice.locale) { stage in
                Task { @MainActor in self.stage = stage }
            }
            words = heard
            bars = BarBuilder.bars(from: heard)
            // Beyond the words: what the voice did on each bar.
            delivery = try? await model.engine.delivery(audio: recording.url, bars: bars.map { ($0.text, $0.start) }, words: heard, languages: model.languages)
            step = .preview
        } catch {
            guard !Task.isCancelled else { return }
            problem = error.localizedDescription
            step = .language
        }
    }

    /// The bars heard in the recording open as a song.
    private func open() {
        guard let recording else { return }
        let song = Song(title: recording.title, text: bars.map(\.text).joined(separator: "\n"))
        song.artist = recording.artist
        song.audioFile = recording.fileName
        song.barTimes = bars.map(\.start)
        song.delivery = delivery
        context.insert(song)
        kept = true
        onOpen(song)
        dismiss()
    }

    /// The words found by name open as a song, timed line by line when they were, with the
    /// recording behind them when the phone could read it.
    private func open(_ found: FoundLyrics) {
        let song = Song(title: found.title, text: found.text)
        song.artist = found.artist
        song.audioFile = recording?.fileName ?? ""
        if found.synced { song.barTimes = found.lines.map { $0.start ?? 0 } }
        song.delivery = wordsDelivery
        context.insert(song)
        kept = true
        onOpen(song)
        dismiss()
    }
}
