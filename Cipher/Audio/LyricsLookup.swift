import Foundation
import MediaPlayer
import Synchronization

/// One line of a track's words, with when it is sung if the source knew.
struct LyricLine: Sendable, Equatable {
    let text: String
    let start: Double?
}

/// The words of a track found from its name and metadata rather than heard from its audio:
/// the way an Apple Music stream, whose audio apps cannot read, still gets written out.
struct FoundLyrics: Identifiable, Sendable, Equatable {
    enum Source: Sendable, Equatable {
        /// The lyrics tag inside the track's own file.
        case tag
        /// LRCLIB, a community library of plain and line-timed lyrics.
        case lrclib
        /// Pasted in by the writer.
        case pasted
    }

    let id: Int
    var title: String
    var artist: String
    var album: String
    let duration: Double
    let lines: [LyricLine]
    let source: Source

    /// Every line carries its time: the bars can be laid against a recording.
    var synced: Bool { !lines.isEmpty && lines.allSatisfy { $0.start != nil } }

    var text: String { lines.map(\.text).joined(separator: "\n") }

    /// The same words with their times taken off: what is left when the times belong to
    /// another cut of the song.
    var untimed: FoundLyrics {
        FoundLyrics(id: id, title: title, artist: artist, album: album, duration: duration, lines: lines.map { LyricLine(text: $0.text, start: nil) }, source: source)
    }

    var credit: String {
        switch source {
        case .tag: "from the track's own lyrics tag"
        case .lrclib: synced ? "from LRCLIB, timed line by line" : "from LRCLIB"
        case .pasted: synced ? "pasted in, timed line by line" : "pasted in"
        }
    }

    /// Whether these words were timed against a cut of the song as long as one running `length`
    /// seconds, within three seconds; true when either length is unknown.
    func fits(_ length: Double) -> Bool {
        length <= 0 || duration <= 0 || abs(duration - length) <= 3
    }
}

enum LyricsError: LocalizedError {
    case notFound(String)
    case instrumental(String)
    case offline
    case unreachable
    case server(Int)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notFound(let title): "No words were found for “\(title)”. Try finding it by name, with the artist."
        case .instrumental(let title): "“\(title)” is listed as an instrumental, so it has no words to find."
        case .offline: "The phone is offline, so the lyric library could not be reached. Check the connection and try again."
        case .unreachable: "The lyric library did not answer in time. Try again in a moment."
        case .server(let code) where [429, 502, 503, 504].contains(code): "The lyric library is busy right now. Try again in a moment."
        case .server(let code): "The lyric library answered with an error (\(code)). Try again in a moment."
        case .unreadable: "The lyric library answered in a form Cipher could not read. Try again later."
        }
    }
}

/// Finds a track's words by its name. The track's own lyrics tag is read first; failing that
/// LRCLIB (lrclib.net) is asked, by exact title, artist, album and length, then by a looser
/// search. Only the track's name and length ever leave the phone.
enum LyricsLookup {
    static let agent = "CipherLyricsApp/0.2 (personal lyric-writing app for iOS)"
    private static let base = URL(string: "https://lrclib.net/api")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["User-Agent": agent]
        return URLSession(configuration: configuration)
    }()

    #if os(iOS)
    /// The words of a library track: its own lyrics tag when the file carries one, else LRCLIB.
    static func lyrics(for item: MPMediaItem) async throws -> FoundLyrics {
        let title = (item.title ?? "").trimmingCharacters(in: .whitespaces)
        let artist = item.artist ?? ""
        let album = item.albumTitle ?? ""
        let duration = item.playbackDuration
        // A track with no name cannot be looked up; "Untitled" would find somebody else's song.
        guard !title.isEmpty else { throw LyricsError.notFound("this track") }
        if let tagged = item.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !tagged.isEmpty {
            let lines = (looksTimed(tagged) ? parse(lrc: tagged) : parse(plain: tagged)).map(readable)
            if !lines.isEmpty {
                return FoundLyrics(id: 0, title: title, artist: artist, album: album, duration: duration, lines: lines, source: .tag)
            }
        }
        var found = try await find(title: title, artist: artist, album: album, duration: duration)
        // The track keeps the name the writer knows it by; the artist too, unless the words are
        // another artist's recording of the song, which the sheet should then say.
        found.title = title
        if !artist.isEmpty, found.artist.isEmpty || shareArtist(artist, found.artist) { found.artist = artist }
        return found
    }
    #endif

    /// LRCLIB's words for a track: the exact entry when there is one, else the best of a search
    /// whose title is the track's. The exact lookup being turned away (LRCLIB is often busy) does
    /// not end the lookup; a search turned away even after asking again does.
    static func find(title: String, artist: String, album: String, duration: Double) async throws -> FoundLyrics {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { throw LyricsError.notFound(title) }
        // LRCLIB's entries are crowd-sourced, and its verdict that a cut is instrumental is
        // sometimes wrong (Apple's own "Tum Hi Ho" entry carries it). It is not trusted outright:
        // the search goes on, but only the same artist's sung recording of the song will do.
        var saidInstrumental = false
        if !artist.isEmpty, duration > 0 {
            var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist), URLQueryItem(name: "duration", value: String(Int(duration.rounded())))]
            if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
            var exact: Record?
            do {
                // The exact lookup also asks other sources for a track LRCLIB lacks, so it is the
                // first to be turned away when the library is busy; the searches read only its own.
                exact = try await fetch(Record.self, path: "get", query: items, attempts: 2)
            } catch is LyricsError {}
            saidInstrumental = exact?.instrumental == true
            if let found = exact?.lyrics { return found }
        }
        // So does a cut named as one in its tail: shortTitle would cut "(Instrumental)" off and
        // search for the song. A song called "Karaoke" is sung.
        let tail = title.dropFirst(shortTitle(title).count).lowercased()
        if tail.contains("instrumental") || tail.contains("karaoke") { throw LyricsError.instrumental(title) }
        let wanted = fold(title)
        let short = shortTitle(title)
        // A title in Devanagari or Gujarati is looked for in the Latin letters LRCLIB's titles
        // are mostly written in, as well.
        let latin = romanized(short)
        let credited = credits(artist)
        let names = Set(credited.map(compact))
        // Narrowest first: the title with the artist, the plain title ("Pyar Ka Safar" of "Pyar
        // Ka Safar (From …)") with the artist, then with each artist credited on their own
        // (Apple credits a Bollywood song's composer first, LRCLIB often its singer), then with
        // no artist, then free text. All but the first two are loose, so what they find must
        // also share an artist or the length; so must everything when the track names no artist.
        var routes: [(query: [URLQueryItem], loose: Bool)] = []
        func route(_ track: String, _ artist: String?, loose: Bool = false) {
            var items = [URLQueryItem(name: "track_name", value: track)]
            if let artist, !artist.isEmpty { items.append(URLQueryItem(name: "artist_name", value: artist)) }
            routes.append((items, loose || names.isEmpty))
        }
        route(title, artist)
        if short != title { route(short, artist) }
        if let latin { route(latin, artist) }
        if credited.count > 1 {
            for name in credited.prefix(4) {
                route(title, name, loose: true)
                route(short, name, loose: true)
                if let latin { route(latin, name, loose: true) }
            }
        }
        if !artist.isEmpty {
            route(short, nil, loose: true)
            if let latin { route(latin, nil, loose: true) }
        }
        let free = searchText(title: title, artist: artist)
        routes.append(([URLQueryItem(name: "q", value: free)], true))
        // The first route to turn up the song at the track's own length wins. One that turns it
        // up only at another length (an album cut for a remix) is kept while the others are
        // tried, since LRCLIB answers at most twenty rows and the right cut can be crowded out.
        var closest: FoundLyrics?
        var tried = Set<[URLQueryItem]>()
        for route in routes where tried.insert(route.query).inserted {
            // Every search goes to the same library, so one turned away means the rest would be;
            // words already in hand at another length are then better than the error.
            let found: [FoundLyrics]
            do {
                if route.query.first?.name == "q" {
                    found = try await search(free)
                } else {
                    found = (try await fetch([Record].self, path: "search", query: route.query) ?? []).compactMap(\.lyrics)
                }
            } catch let error as LyricsError {
                if let closest { return closest }
                throw error
            }
            // Whatever the search turned up, only a record of the same song will do.
            let candidates = found.filter { candidate in
                let own = fold(candidate.title)
                guard sameSong(own, wanted) || latin.map({ sameSong(own, fold($0)) }) == true else { return false }
                if saidInstrumental { return shareArtist(artist, candidate.artist) }
                return !route.loose || credible(candidate, names: names, duration: duration)
            }
            guard let best = pick(candidates + [closest].compactMap(\.self), names: names, duration: duration) else { continue }
            if best.fits(duration) { return best }
            closest = best
        }
        if let closest { return closest }
        throw saidInstrumental ? LyricsError.instrumental(title) : LyricsError.notFound(title)
    }

    /// What to type to find a track by name: its plain title and the first artist credited.
    static func searchText(title: String, artist: String) -> String {
        [shortTitle(title.trimmingCharacters(in: .whitespaces)), credits(artist).first ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// What the sheet lists when it looks for a track by name: the free-text search for its
    /// plain title with each of its first three credited names, then alone, merged, closest to
    /// the track first. Apple credits a Bollywood song's composer first, and LRCLIB fills a
    /// composer's results with instrumental placeholders, so the title with the composer alone
    /// often finds nothing.
    static func search(forTitle title: String, artist: String, duration: Double) async throws -> [FoundLyrics] {
        let short = shortTitle(title.trimmingCharacters(in: .whitespaces))
        guard !short.isEmpty else { return [] }
        let wanted = fold(title)
        var texts = credits(artist).prefix(3).map { "\(short) \($0)" } + [short]
        if let latin = romanized(short) { texts.append(latin) }
        var seen = Set<Int>(), merged: [FoundLyrics] = []
        var asked = Set<String>()
        for text in texts where asked.insert(text).inserted {
            do {
                for found in try await search(text) where seen.insert(found.id).inserted { merged.append(found) }
            } catch let error as LyricsError {
                if merged.isEmpty { throw error }
                break
            }
            // The track's own cut is already in hand: no need to ask again.
            if merged.contains(where: { sameSong(fold($0.title), wanted) && $0.duration > 0 && duration > 0 && $0.fits(duration) }) { break }
        }
        return rank(merged, title: title, artist: artist, duration: duration)
    }

    /// Search results closest to a track first: the same title, then the same length, then
    /// timed over plain, then the same artist. LRCLIB's own order puts the right cut anywhere
    /// in its twenty rows.
    static func rank(_ found: [FoundLyrics], title: String, artist: String, duration: Double) -> [FoundLyrics] {
        let wanted = fold(title), names = Set(credits(artist).map(compact))
        let scored = found.enumerated().map { (offset: $0.offset, found: $0.element, score: closeness($0.element, wanted: wanted, names: names, duration: duration)) }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }.map(\.found)
    }

    /// A Devanagari or Gujarati title in Latin letters, as LRCLIB's titles mostly are: "प्यार का
    /// सफ़र" is "pyar ka safar". The short a a longer word ends on is not said, so it goes
    /// ("safara" is "safar"); a long ā stays ("merā" is "mera"). Nil for any other title.
    static func romanized(_ title: String) -> String? {
        guard title.unicodeScalars.contains(where: { (0x0900...0x097F).contains($0.value) || (0x0A80...0x0AFF).contains($0.value) }),
              let latin = title.applyingTransform(.toLatin, reverse: false) else { return nil }
        let words = latin.precomposedStringWithCanonicalMapping.split(separator: " ").map { word -> String in
            var word = String(word)
            if word.count >= 3, word.hasSuffix("a") { word.removeLast() }
            return word
        }
        let plain = String(String.UnicodeScalarView(unaccented(words.joined(separator: " ")))).trimmingCharacters(in: .whitespaces)
        return plain.isEmpty ? nil : plain
    }

    /// Gurmukhi, which the rhyme engine cannot read, written in Devanagari, which it can: Punjabi
    /// and Punjabi-tinged songs come back from LRCLIB in either. ICU drops the tippi (ੰ), so it
    /// becomes a bindi first; it drops the addak (ੱ) too, which doubles the consonant after it
    /// (ਬੱਚਾ is बच्चा, not बचा); and it writes ਸ਼ and ਲ਼ as a dotted स and ल where Hindi writes श
    /// and ळ, which the engine reads as they sound.
    static func readable(_ line: LyricLine) -> LyricLine {
        guard line.text.unicodeScalars.contains(where: { (0x0A00...0x0A7F).contains($0.value) }) else { return line }
        let tippi = line.text.replacingOccurrences(of: "\u{0A70}", with: "\u{0A02}")
        let doubled = addak.stringByReplacingMatches(in: tippi, range: NSRange(location: 0, length: (tippi as NSString).length), withTemplate: "$1\u{0A4D}$1")
        guard let devanagari = doubled.applyingTransform(StringTransform("Gurmukhi-Devanagari"), reverse: false) else { return line }
        let text = devanagari
            .replacingOccurrences(of: "\u{0938}\u{093C}", with: "\u{0936}")
            .replacingOccurrences(of: "\u{0932}\u{093C}", with: "\u{0933}")
        return LyricLine(text: text, start: line.start)
    }

    /// The addak and the consonant it doubles.
    private static let addak = try! NSRegularExpression(pattern: #"\x{0A71}([\x{0A15}-\x{0A39}\x{0A59}-\x{0A5E}])"#)

    /// Two folded titles name the same song only word for word: "Tu" is not "Azaad Hai Tu", nor
    /// "Ya" "Yaara". The tails both sides lose in folding ("(From …)", " - Remastered", "feat.")
    /// and a track number left in front ("01 Tum Hi Ho") do not count.
    private static func sameSong(_ own: String, _ wanted: String) -> Bool {
        func words(_ title: String) -> [Substring] {
            var words = title.split(separator: " ")
            if words.count > 1, words[0].hasPrefix("0"), words[0].allSatisfy(\.isNumber) { words.removeFirst() }
            return words
        }
        let mine = words(own)
        return !mine.isEmpty && mine == words(wanted)
    }

    /// Whether two artist credits name someone in common: "Shaan" and "Shaan & Shreya Ghoshal".
    private static func shareArtist(_ one: String, _ other: String) -> Bool {
        !Set(credits(one).map(compact)).isDisjoint(with: credits(other).map(compact))
    }

    /// A loose search's find is believed when it shares an artist with the track or runs the same
    /// length, within the two seconds LRCLIB itself allows; one "Hello" is not another.
    private static func credible(_ candidate: FoundLyrics, names: Set<String>, duration: Double) -> Bool {
        if !names.isEmpty, !names.isDisjoint(with: credits(candidate.artist).map(compact)) { return true }
        if duration > 0, candidate.duration > 0, abs(candidate.duration - duration) <= 2 { return true }
        return names.isEmpty && duration <= 0
    }

    /// The names in an artist credit: "Shaan & Shreya Ghoshal", "Pritam, Arijit Singh feat. X".
    /// "feat" and "ft" break only as whole words, so FTISLAND and Feathers stay whole, and "x"
    /// only between names, so Lil Nas X does.
    private static let creditBreak = try! NSRegularExpression(pattern: #"\s*(?:,|&|/|;|\+|•|\sx(?=\s)|\band\b|\bfeat\b\.?|\bft\b\.?|\bfeaturing\b|\bwith\b)\s*"#, options: .caseInsensitive)

    private static func credits(_ artist: String) -> [String] {
        let marked = creditBreak.stringByReplacingMatches(in: artist, range: NSRange(location: 0, length: (artist as NSString).length), withTemplate: "|")
        return marked.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A name as names compare: letters and digits only, accents off, so "A.R. Rahman" is "AR
    /// Rahman" and "Beyoncé" "Beyonce".
    private static func compact(_ name: String) -> String {
        String(String.UnicodeScalarView(unaccented(name.lowercased()).filter(CharacterSet.alphanumerics.contains)))
    }

    /// A text's scalars with Latin accents taken off ("é" is "e"); the vowel signs and nukta of
    /// Indic scripts are not accents and stay.
    private static func unaccented(_ text: String) -> [Unicode.Scalar] {
        text.decomposedStringWithCanonicalMapping.unicodeScalars.filter { !(0x300...0x36F).contains($0.value) }
    }

    /// A title without its bracketed "(Remastered 2009)", " - From …" or "feat." tail. A title
    /// that opens with a bracket ("(I Can't Get No) Satisfaction") keeps it, and "feat" cuts
    /// only as a word ("Birds of a Feather" is whole).
    private static func shortTitle(_ title: String) -> String {
        var text = title
        for opener in ["(", "[", " - ", " – ", " feat.", " feat ", " ft.", " ft ", " featuring "] {
            // Looked for after the first character, so a bracket the title opens with is kept
            // and a tail after it still goes: "(Sittin' On) The Dock of the Bay (2019 Remaster)".
            guard text.count > 1 else { break }
            if let range = text.range(of: opener, options: .caseInsensitive, range: text.index(after: text.startIndex)..<text.endIndex) {
                text = String(text[..<range.lowerBound])
            }
        }
        // A dash spaced on one side only is a tail too: LRCLIB's "Pal Pal Dil Ke Paas- Title Track".
        if let range = text.range(of: #"\s+[-–—]|[-–—]\s+"#, options: .regularExpression), range.lowerBound > text.startIndex {
            text = String(text[..<range.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// A title as the same song's titles compare: lowercase, accents off, letters and digits
    /// only, "&" read as "and", one space between words, with the bracketed "(Remastered 2009)"
    /// and "feat." tails cut off.
    private static func fold(_ title: String) -> String {
        let text = shortTitle(title).lowercased().replacingOccurrences(of: "&", with: " and ")
        let kept = unaccented(text).map { CharacterSet.alphanumerics.contains($0) ? $0 : " " }
        return String(String.UnicodeScalarView(kept)).split(separator: " ").joined(separator: " ")
    }

    /// Tracks LRCLIB knows by free text ("lose yourself eminem"), best match first.
    static func search(_ text: String) async throws -> [FoundLyrics] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if let kept = recent.withLock({ $0[text] }), Date().timeIntervalSince(kept.at) < 60 { return kept.found }
        let found = (try await fetch([Record].self, path: "search", query: [URLQueryItem(name: "q", value: text)]) ?? []).compactMap(\.lyrics)
        recent.withLock { kept in
            let now = Date()
            kept = kept.filter { now.timeIntervalSince($0.value.at) < 60 }
            kept[text] = (now, found)
        }
        return found
    }

    /// The free-text searches of the last minute. The search the sheet opens with after a miss
    /// is the lookup's own last one, and need not be sent twice.
    private static let recent = Mutex<[String: (at: Date, found: [FoundLyrics])]>([:])

    /// The candidate closest to the track: the same length first of all (timed lines of another
    /// edit would sit against the wrong seconds of the recording), then timed over plain, then
    /// the same artist.
    private static func pick(_ candidates: [FoundLyrics], names: Set<String>, duration: Double) -> FoundLyrics? {
        candidates.max { closeness($0, wanted: nil, names: names, duration: duration) < closeness($1, wanted: nil, names: names, duration: duration) }
    }

    private static func closeness(_ candidate: FoundLyrics, wanted: String?, names: Set<String>, duration: Double) -> Double {
        var score = candidate.synced ? 1.5 : 0
        if let wanted, sameSong(fold(candidate.title), wanted) { score += 3 }
        if duration > 0, candidate.duration > 0 {
            let gap = abs(candidate.duration - duration)
            score += gap <= 3 ? 4 : gap <= 10 ? 2 : gap <= 60 ? 0 : -3
        }
        if !names.isEmpty, !names.isDisjoint(with: credits(candidate.artist).map(compact)) { score += 1 }
        return score
    }

    // MARK: Wire

    private struct Record: Decodable {
        let id: Int
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
        /// LRCLIB's newer form: a YAML document of timed lines, which newer entries carry instead
        /// of the two fields above.
        let lyricsfile: String?

        /// The record as words, or nil for an instrumental or an entry with no text.
        var lyrics: FoundLyrics? {
            guard instrumental != true else { return nil }
            var lines: [LyricLine] = []
            if let synced = syncedLyrics, !synced.isEmpty { lines = LyricsLookup.parse(lrc: synced) }
            if lines.isEmpty, let file = lyricsfile, !file.isEmpty { lines = LyricsLookup.parse(lyricsfile: file) }
            if lines.isEmpty, let plain = plainLyrics { lines = LyricsLookup.parse(plain: plain) }
            guard !lines.isEmpty else { return nil }
            lines = lines.map(LyricsLookup.readable)
            return FoundLyrics(id: id, title: trackName ?? "", artist: artistName ?? "", album: albumName ?? "", duration: duration ?? 0, lines: lines, source: .lrclib)
        }
    }

    /// Everything but letters, digits and a few safe marks is percent-encoded in a query value:
    /// URLComponents leaves "+" alone, and the server would read it as a space.
    private static let queryValue: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?/;:,$@")
        return allowed
    }()

    /// One request, asked again after a pause when the library says it is busy (429, or a 5xx:
    /// LRCLIB answers 503 "ServerOverloaded" and usually serves the same request a second later).
    private static func fetch<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem], attempts: Int = 3) async throws -> T? {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.percentEncodedQueryItems = query.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: queryValue))
        }
        guard let url = components.url else { return nil }
        var attempt = 1
        while true {
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(from: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                switch error.code {
                case .cancelled:
                    // A cancelled task is not a network failure.
                    throw CancellationError()
                case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                    throw LyricsError.offline
                case .networkConnectionLost where attempt < attempts:
                    // A connection dropped mid-answer (common on cellular) is asked again at once.
                    attempt += 1
                    continue
                default:
                    // A timeout is not worth repeating at fifteen seconds a try.
                    throw LyricsError.unreachable
                }
            } catch {
                throw LyricsError.unreachable
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw LyricsError.unreadable }
                return decoded
            case 404:
                return nil
            case _ where (status == 429 || (500...599).contains(status)) && attempt < attempts:
                // Retry-After in seconds when it is given as a number (it may also be a date).
                let asked = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
                try await Task.sleep(for: .seconds(max(0, min(asked ?? 0.8 * Double(attempt), 3))))
                attempt += 1
            default:
                throw LyricsError.server(status)
            }
        }
    }

    // MARK: Parsing

    /// "[mm:ss.xx]" at the head of an LRC line; a line may carry several.
    private static let stamp = try! NSRegularExpression(pattern: #"^\s*\[(\d+):(\d+(?:\.\d+)?)\]"#)
    /// "<mm:ss.xx>" word timings inside an enhanced LRC line.
    private static let wordStamp = try! NSRegularExpression(pattern: #"<\d+:\d+(?:\.\d+)?>"#)

    /// Whether a lyrics text is in LRC form: some line of it starts with a time stamp (the
    /// first lines may be "[ar: …]" headers).
    static func looksTimed(_ text: String) -> Bool {
        guard text.contains("[") else { return false }
        return lines(of: text).contains { stamp.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
    }

    /// The lines of a text, whichever way its line breaks are written (a CRLF is one break).
    private static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
    }

    /// Lines in LRC form, in time order, empty ones dropped. "[ar: …]" header tags are skipped.
    static func parse(lrc text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in Self.lines(of: text) {
            var rest = raw as NSString
            var times: [Double] = []
            while let match = stamp.firstMatch(in: rest as String, range: NSRange(location: 0, length: rest.length)) {
                if let minutes = Double(rest.substring(with: match.range(at: 1))), let seconds = Double(rest.substring(with: match.range(at: 2))) {
                    times.append(minutes * 60 + seconds)
                }
                rest = rest.substring(from: NSMaxRange(match.range)) as NSString
            }
            guard !times.isEmpty else { continue }
            // A stamped line with no words marks a break (an instrumental stretch, the gap
            // between verses): it is kept, so the verses stay apart and the line before it ends
            // where the break begins.
            let plain = wordStamp.stringByReplacingMatches(in: rest as String, range: NSRange(location: 0, length: rest.length), withTemplate: "")
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            for time in times { lines.append(LyricLine(text: plain, start: time)) }
        }
        return tidy(lines.enumerated().sorted { ($0.element.start ?? 0, $0.offset) < ($1.element.start ?? 0, $1.offset) }.map(\.element))
    }

    /// Lines with no blank one first or last and never two blank ones in a row; a run of blanks
    /// keeps the first one's time.
    private static func tidy(_ lines: [LyricLine]) -> [LyricLine] {
        var kept: [LyricLine] = []
        for line in lines where !(line.text.isEmpty && (kept.isEmpty || kept.last?.text.isEmpty == true)) { kept.append(line) }
        while kept.last?.text.isEmpty == true { kept.removeLast() }
        return kept
    }

    /// LRCLIB's lyricsfile: under "lines:", one "- text: …" item per line at the left margin with
    /// its "start_ms:" two spaces in. Word timings sit deeper and are left alone. A text with a
    /// colon or quote in it comes single- or double-quoted the YAML way.
    static func parse(lyricsfile text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var current: String?
        var start: Double?
        var inLines = false
        func flush() {
            // A timed item with no words is a break, kept as a blank line (see parse(lrc:)).
            if let current, !current.isEmpty || start != nil { lines.append(LyricLine(text: current, start: start)) }
            current = nil
            start = nil
        }
        for raw in Self.lines(of: text) {
            if raw.hasPrefix("lines:") { inLines = true; continue }
            guard inLines else { continue }
            if raw.hasPrefix("- ") {
                flush()
                current = ""
                read(String(raw.dropFirst(2)), into: &current, &start)
            } else if raw.hasPrefix("  "), !raw.hasPrefix("   ") {
                read(String(raw.dropFirst(2)), into: &current, &start)
            } else if !raw.hasPrefix(" "), !raw.isEmpty {
                // Another top-level key: the lines are over.
                flush()
                inLines = false
            }
        }
        flush()
        if lines.allSatisfy({ $0.start != nil }) {
            return tidy(lines.enumerated().sorted { ($0.element.start ?? 0, $0.offset) < ($1.element.start ?? 0, $1.offset) }.map(\.element))
        }
        return tidy(lines)
    }

    private static func read(_ field: String, into text: inout String?, _ start: inout Double?) {
        if field.hasPrefix("text:") {
            text = unquote(String(field.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        } else if field.hasPrefix("start_ms:"), let milliseconds = Double(field.dropFirst(9).trimmingCharacters(in: .whitespaces)) {
            start = milliseconds / 1000
        }
    }

    /// A YAML scalar as plain text: 'it''s' and "it\'s" both give it's.
    private static func unquote(_ scalar: String) -> String {
        if scalar.count >= 2, scalar.hasPrefix("'"), scalar.hasSuffix("'") {
            return String(scalar.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if scalar.count >= 2, scalar.hasPrefix("\""), scalar.hasSuffix("\""),
           let data = scalar.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return scalar
    }

    /// Plain words, one line each; blank lines between verses are kept so the song keeps its shape.
    static func parse(plain text: String) -> [LyricLine] {
        var lines = Self.lines(of: text).map { LyricLine(text: $0.trimmingCharacters(in: .whitespaces), start: nil) }
        while lines.first?.text.isEmpty == true { lines.removeFirst() }
        while lines.last?.text.isEmpty == true { lines.removeLast() }
        // Never more than one blank line in a row.
        var kept: [LyricLine] = []
        for line in lines where !(line.text.isEmpty && kept.last?.text.isEmpty == true) { kept.append(line) }
        return kept
    }
}
