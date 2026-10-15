"""Songs for the culture index: rows for build_culture.py and the links between songs.

    from build_songs import song_works
    works, links = song_works(film_rows)

Reads what the song crawl wrote under Tools/data/culture/songs/:
    song_catalog.json, song_details.json   Wikidata songs and their facts (fetch_song_catalog/details)
    song_canon.json                        chart, award and list entries (fetch_song_lists)
    soundtracks.json                       Indian film songs (fetch_soundtracks)
    song_wiki.json                         Wikipedia categories and lead-sentence links (fetch_wikipedia)
    relations_*.json                       samples, covers, versions, borrowing (fetch_samples, fetch_itwofs,
                                           load_musicbrainz)

Every song becomes a work dict shaped like build_culture's own (kind "song"); a song known only
from a chart, a track listing or a relation gets a stable "S" id. Links come back as
(qid, qid, forward, backward, strength, source) for build_culture's link(); a borrowed original
from outside the four cultures (an Arabic or Turkish song a Bollywood number was built on)
becomes a small culture "xx" row that exists only to be linked to. No lyrics are read anywhere.
"""
import hashlib
import json
import re
import unicodedata
from collections import Counter, defaultdict

from common import DATA, log

SONGS = DATA / "songs"
# How many songs each culture keeps, by weight; relation endpoints and canon songs are kept first.
CAPS = {"us": 20000, "in": 15000, "es": 8000, "fr": 6000}
# Rows made for link ends outside the catalogue, per source: Wikipedia's sample credits and
# ItwoFS first, MusicBrainz (whose covers run to six figures) last and only for real borrowing.
STUB_BUDGET = {"w": 1800, "i": 1000, "d": 300, "m": 1200}
RELATION_ORDER = ["relations_wiki.json", "relations_itwofs.json", "relations_song_lists.json", "relations_mb.json"]
MB_STUB_KINDS = {"samples", "interpolates", "version of", "inspired by"}

INDIAN_LANGUAGES = {"Q1568": "Hindi", "Q1617": "Urdu", "Q58635": "Punjabi", "Q5885": "Tamil", "Q8097": "Telugu",
                    "Q9610": "Bengali", "Q1571": "Marathi", "Q5137": "Gujarati", "Q36236": "Malayalam", "Q33673": "Kannada"}
TRACK_LANGUAGE = {"hi": "Hindi", "ur": "Urdu", "pa": "Punjabi", "ta": "Tamil", "te": "Telugu", "bn": "Bengali",
                  "mr": "Marathi", "gu": "Gujarati", "ml": "Malayalam", "kn": "Kannada"}
LANGUAGE_CULTURE = {"Q1860": "us", "Q1321": "es", "Q150": "fr", **{q: "in" for q in INDIAN_LANGUAGES}}
# Where a performer or a song comes from, when the song's own language is not recorded.
COUNTRY_CULTURE = {
    "Q30": "us", "Q145": "us", "Q16": "us", "Q408": "us", "Q27": "us", "Q664": "us", "Q21": "us", "Q22": "us",
    "Q668": "in", "Q843": "in",  # India; Pakistan's Urdu and Punjabi music sits with it
    "Q142": "fr", "Q31": "fr", "Q39": "fr", "Q32": "fr", "Q235": "fr", "Q790": "fr", "Q1041": "fr", "Q1008": "fr",
    "Q1009": "fr", "Q974": "fr", "Q262": "fr", "Q1028": "fr",
    **{q: "es" for q in ("Q29", "Q96", "Q414", "Q739", "Q298", "Q419", "Q717", "Q241", "Q1183", "Q77", "Q786", "Q804",
                         "Q736", "Q750", "Q733", "Q774", "Q783", "Q792", "Q811", "Q800")},
}
# A country whose songs are as often in English as not decides nothing on its own.
MIXED = {"Q31", "Q39", "Q16"}

# How a music genre feels; songs the tagging pass has not reached take their mood from here.
SONG_MOOD = [
    ("drill", "menacing cold"), ("trap", "menacing hypnotic"), ("gangsta", "menacing swaggering"), ("conscious", "defiant reflective"),
    ("hip hop", "swaggering rhythmic"), ("hip-hop", "swaggering rhythmic"), ("rap", "swaggering rhythmic"), ("grime", "aggressive"),
    ("contemporary r&b", "smooth sensual"), ("r&b", "smooth sensual"), ("rhythm and blues", "smooth sensual"), ("neo soul", "smooth warm"),
    ("soul", "soulful warm"), ("funk", "funky strutting"), ("disco", "euphoric glittering"), ("house", "euphoric hypnotic"),
    ("techno", "hypnotic driving"), ("edm", "euphoric driving"), ("electronic", "pulsing"), ("dance", "euphoric"),
    ("blues", "aching weary"), ("gospel", "uplifting devout"), ("jazz", "smoky cool"), ("swing", "jaunty"),
    ("heavy metal", "furious heavy"), ("metal", "furious heavy"), ("punk", "raw defiant"), ("grunge", "brooding raw"),
    ("hard rock", "loud swaggering"), ("rock", "loud driving"), ("country", "homespun earnest"), ("folk", "earnest plain"),
    ("singer-songwriter", "intimate confessional"), ("ballad", "tender aching"), ("power ballad", "soaring aching"),
    ("synth-pop", "glossy wistful"), ("dance-pop", "bright euphoric"), ("teen pop", "bright giddy"), ("pop", "bright catchy"),
    ("reggaeton", "sensual pounding"), ("dembow", "sensual pounding"), ("latin trap", "menacing sensual"), ("bachata", "aching sensual"),
    ("salsa", "fiery festive"), ("merengue", "festive fast"), ("cumbia", "swaying festive"), ("bolero", "romantic aching"),
    ("tango", "passionate brooding"), ("ranchera", "proud heartsore"), ("mariachi", "proud festive"), ("corrido", "outlaw storytelling"),
    ("banda", "brassy festive"), ("flamenco", "fiery anguished"), ("rumba", "festive"), ("bossa nova", "breezy wistful"),
    ("chanson", "wistful poetic"), ("variété", "sentimental"), ("rap français", "swaggering urban"), ("zouk", "sensual swaying"),
    ("raï", "yearning festive"), ("reggae", "laid-back righteous"), ("dancehall", "bouncing brash"), ("afrobeats", "joyous bouncing"),
    ("ghazal", "yearning melancholy"), ("qawwali", "ecstatic devout"), ("sufi", "ecstatic devout"), ("bhajan", "devout serene"),
    ("devotional", "devout serene"), ("bhangra", "jubilant pounding"), ("item number", "seductive brash"), ("cabaret", "seductive brash"),
    ("filmi", "melodramatic"), ("indi-pop", "breezy"), ("indipop", "breezy"), ("lullaby", "tender hushed"), ("patriotic", "proud stirring"),
    ("protest", "defiant"), ("christmas", "festive warm"), ("children", "innocent bright"),
]

# A link found in a Wikidata statement: (this song is ..., the other is ..., strength).
WIKIDATA_RELATION = {
    "P5707": ("samples", "sampled by", 0.9), "P6166": ("interpolates", "interpolated in", 0.85),
    "P6670": ("interpolates", "interpolated in", 0.85), "P9745": ("version of", "other version", 0.9),
    "P9810": ("remix of", "remixed as", 0.7), "P5059": ("version of", "other version", 0.8),
    "P144": ("version of", "other version", 0.8), "P941": ("inspired by", "inspired", 0.6),
    "P4969": ("other version", "version of", 0.8),
}
# Phrases from Wikipedia leads and from the relation crawls, matched on keywords.
PHRASE_RELATION = [
    (r"cover", ("cover of", "covered as", 0.95)), (r"sampled? from|samples|sample of", ("samples", "sampled by", 0.9)),
    (r"interpolat", ("interpolates", "interpolated in", 0.85)), (r"elements of", ("interpolates", "interpolated in", 0.8)),
    (r"recreat|version of|adaptation|adapted|based on", ("version of", "other version", 0.8)), (r"remix", ("remix of", "remixed as", 0.7)),
    (r"answer", ("answer song to", "answered by", 0.8)), (r"written for|from the film|song from", ("written for", "song from", 0.9)),
    (r"inspired|lifted|borrow|plagiar|copied", ("inspired by", "inspired", 0.6)),
]
# Relations specific enough that a title with no link can be trusted to name the other song.
TITLE_JOINS = {"samples", "interpolates", "cover of", "version of", "remix of", "answer song to"}
BACKWARD = {"samples": "sampled by", "interpolates": "interpolated in", "cover of": "covered as", "version of": "other version",
            "remix of": "remixed as", "inspired by": "inspired", "answer song to": "answered by", "written for": "song from",
            "from film": "features song", "counterpart": "counterpart", "kindred": "kindred"}
BACKWARD.update({value: key for key, value in list(BACKWARD.items())})


def load(name, default):
    path = SONGS / name
    return json.loads(path.read_text()) if path.exists() else default


def norm(title):
    """A title as titles compare: lowercase, no accents, no "(from X)", "feat." or punctuation."""
    text = unicodedata.normalize("NFKD", str(title or "")).lower()
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = re.sub(r"\(.*?\)|\[.*?\]|\bfeat\..*$|\bft\..*$|\bfeaturing\b.*$", " ", text)
    text = re.sub(r"[^\w\s]", " ", text)
    return " ".join(text.split())


def loose(title):
    """A romanised Hindi title as it is spelt any which way: Dhoom Machaale, Dhoom Machale."""
    text = norm(title).replace("w", "v").replace("ee", "i").replace("oo", "u").replace("aa", "a")
    text = re.sub(r"(?<=[bcdgjkptsr])h", "", text)
    return re.sub(r"(.)\1+", r"\1", text)


def sid(*parts):
    return "S" + hashlib.sha1("|".join(norm(p) for p in parts).encode()).hexdigest()[:10]


def relation_for(phrase):
    lowered = (phrase or "").lower()
    for pattern, relation in PHRASE_RELATION:
        if re.search(pattern, lowered):
            return relation
    return None


def moods(genres):
    found = []
    for genre in genres:
        lowered = genre.lower()
        for key, feel in SONG_MOOD:
            if key in lowered:
                found += [mood for mood in feel.split() if mood not in found]
                break
    return found[:3]


def english_looking(title):
    words = set(norm(title).split())
    return bool(words & {"the", "you", "love", "me", "my", "i", "baby", "your", "it", "girl", "don't", "dont", "night", "heart"}) \
        and all(ord(c) < 128 for c in title)


def culture_of(detail, hints, list_culture=None, indian_film=False):
    languages = detail.get("languages", [])
    for language in languages:
        if language in LANGUAGE_CULTURE:
            return LANGUAGE_CULTURE[language]
    if indian_film:
        return "in"
    # Who sings it says more than which chart it reached: an American hit that topped the
    # French chart is still American.
    for country in detail.get("performer_countries", []) + detail.get("countries", []):
        if country in COUNTRY_CULTURE and country not in MIXED:
            return COUNTRY_CULTURE[country]
    if list_culture in ("es", "fr") and english_looking(detail.get("labels", {}).get("en", "")):
        return "us"
    if list_culture:
        return list_culture
    # Which crawl pass found a song says little for Spanish and French: their Wikipedias cover
    # Finnish metal and Korean pop too. Only the English and Indian passes are trusted here;
    # the rest are kept only as link ends, from elsewhere.
    if "us" in hints:
        return "us"
    if "in" in hints:
        return "in"
    return "xx"


def names(pairs, limit=2):
    return [label for _, label in pairs if label and not re.fullmatch(r"Q\d+", label)][:limit]


def song_works(film_rows):
    """The song works and their links. `film_rows` maps a film's qid to its work dict (for the
    film's title, year, links and themes), as build_culture has already built them."""
    catalog = load("song_catalog.json", {})
    song_films = load("song_films.json", {})    # film qid -> {language, year, title}, for films not in the index
    details = load("song_details.json", {})
    canon_rows = load("song_canon.json", [])
    tracks = load("soundtracks.json", [])
    wiki = load("song_wiki.json", {})
    relations = []
    files = [p for p in SONGS.glob("relations_*.json") if p.name != "relations_songs.json"] if SONGS.exists() else []
    for path in sorted(files, key=lambda p: (RELATION_ORDER.index(p.name) if p.name in RELATION_ORDER else 9, p.name)):
        relations += json.loads(path.read_text())
    mb_matches = load("mb_matches.json", {})
    if not (details or canon_rows or tracks):
        return [], []

    works = {}          # qid -> work
    links = []          # (qid, qid, forward, backward, strength, source)
    by_title = defaultdict(list)    # norm(title) -> [qid]
    by_loose = defaultdict(list)    # loose(title) of Indian songs -> [qid]
    by_mb = {}          # "mb:<gid>" -> qid
    people = defaultdict(set)       # qid -> normalised names of singers, composers, lyricists

    def add(work, credited=()):
        works[work["q"]] = work
        by_title[norm(work["title"])].append(work["q"])
        if work["culture"] == "in":
            by_loose[loose(work["title"])].append(work["q"])
        for name in [*work["maker"].split(", "), *credited]:
            if name:
                people[work["q"]].add(norm(name))
        return work

    # Performers ranked by how many songs they have: a song Wikidata credits to its singer and to
    # every act that covered it is shown under the singer.
    performer_songs = Counter(qid for detail in details.values() for qid, _ in detail.get("performers", []))

    def performers_of(detail):
        ranked = sorted(detail.get("performers", []), key=lambda pair: -performer_songs[pair[0]])
        return names(ranked)

    # 1. Wikidata songs.
    canon_by_q = defaultdict(list)
    for row in canon_rows:
        if row.get("qid"):
            canon_by_q[row["qid"]].append(row)
    for q, detail in details.items():
        hints = catalog.get(q, {}).get("cultures", [])
        listed = canon_by_q.get(q, [])
        # Not every item a list linked is a song: a disambiguation page, a person or an element
        # has no performer, writer or film, and is left to the list's own row.
        if q not in catalog and not (detail.get("performers") or detail.get("composers") or detail.get("lyricists") or detail.get("films")):
            continue
        indian_film = any(film_rows.get(f, {}).get("culture") == "in" or song_films.get(f, {}).get("language") in TRACK_LANGUAGE
                          for f in detail.get("films", []))
        culture = culture_of(detail, hints, listed[0]["culture"] if listed else None, indian_film)
        if culture not in CAPS and culture != "xx":
            continue
        labels = detail.get("labels", {})
        title = labels.get({"us": "en", "in": "en", "es": "es", "fr": "fr", "xx": "en"}[culture]) or labels.get("en") or next((v for v in labels.values() if v), "")
        if not title or re.fullmatch(r"Q\d+", title):
            continue
        native = (labels.get("hi") or labels.get("gu") or "") if culture == "in" else ""
        writers = names(detail.get("lyricists", [])) or names(detail.get("composers", []))
        summary = detail.get("description", "")
        if writers and "written by" not in summary:
            summary = (summary + "; " if summary else "") + "written by " + ", ".join(writers)
        films = [f for f in detail.get("films", []) if f in film_rows]
        if films and "film" not in summary:
            film = film_rows[films[0]]
            summary = f"song from {film['title']}" + (f" ({film['year']})" if film.get("year") else "") + (f"; {summary}" if summary else "")
        canon_labels = list(dict.fromkeys(row["label"] for row in listed))
        canon_labels += [a for a in detail.get("awards", []) if a not in canon_labels][:2]
        film_year = next((film_rows[f].get("year") for f in films if film_rows[f].get("year")), None) \
            or next((song_films.get(f, {}).get("year") for f in detail.get("films", []) if song_films.get(f, {}).get("year")), None)
        add({
            "q": q, "kind": "song", "culture": culture,
            "year": detail.get("year") or next((r.get("year") for r in listed if r.get("year")), None) or film_year,
            "links": detail.get("sitelinks", 0), "awards": len(detail.get("awards", [])) + 0.5 * len(detail.get("nominations", [])),
            "canon": canon_labels, "title": title, "native": native if native != title else "",
            "maker": ", ".join(performers_of(detail) or writers), "summary": summary,
            "genres": detail.get("genres", []), "films": films, "wiki": wiki.get(q, {}),
            "enwiki": detail.get("wikis", {}).get("en", ""),
        }, credited=names(detail.get("composers", []), 6) + names(detail.get("lyricists", []), 6))
        for gid in detail.get("mb_work", []) + detail.get("mb_recording", []):
            by_mb["mb:" + gid.lower()] = q
        for pid, target in detail.get("relations", []):
            if pid in WIKIDATA_RELATION:
                forward, backward, strength = WIKIDATA_RELATION[pid]
                links.append((q, target, forward, backward, strength, "d"))
        for film in films:
            links.append((q, film, "from film", "features song", 1.0, "d"))

    # 2. Songs on a chart or award list with no Wikidata item of their own.
    grouped = defaultdict(list)
    for row in canon_rows:
        if row.get("qid") in works:
            continue
        grouped[(row.get("culture"), norm(row.get("title")), norm(row.get("artist")))].append(row)
    for (culture, _, _), rows in grouped.items():
        first = rows[0]
        culture = "us" if culture in ("es", "fr") and english_looking(first["title"]) else culture
        if culture not in CAPS or not first.get("title"):
            continue
        # The same song already in from Wikidata (the list linked a redirect or a section):
        # its chart labels go to that row instead of making a second one.
        artist = norm(first.get("artist", ""))
        same = next((c for c in by_title.get(norm(first["title"]), [])
                     if artist and any(artist in name or name in artist for name in people[c] if name)), None)
        if same:
            for label in dict.fromkeys(r["label"] for r in rows):
                if label not in works[same]["canon"]:
                    works[same]["canon"].append(label)
            continue
        q = sid(culture, first["title"], first.get("artist", ""))
        if q in works:
            continue
        labels = list(dict.fromkeys(r["label"] for r in rows))
        year = min((r["year"] for r in rows if r.get("year")), default=None)
        add({"q": q, "kind": "song", "culture": culture, "year": year, "links": 0, "awards": 0, "canon": labels,
             "title": first["title"], "native": "", "maker": first.get("artist", ""),
             "summary": f"{labels[0].lower()} by {first['artist']}" if first.get("artist") else labels[0].lower(),
             "genres": [], "films": [], "wiki": {}, "enwiki": ""})

    # 3. Indian film songs from track listings and singer pages.
    for track in tracks:
        film = film_rows.get(track.get("film") or "")
        q = track.get("qid") if track.get("qid") in works else None
        if q is None:
            q = sid("in", track.get("film") or track.get("film_title", ""), track.get("title", ""))
        work = works.get(q)
        if work is None:
            if not track.get("title"):
                continue
            language = TRACK_LANGUAGE.get(track.get("language", ""), "")
            year = track.get("year") or (film or {}).get("year")
            credits = [f"music by {track['composer']}" if track.get("composer") else "", f"lyrics by {track['lyricist']}" if track.get("lyricist") else "", language]
            film_title = (film or {}).get("title") or track.get("film_title", "")
            summary = "; ".join([f"song from {film_title}" + (f" ({year})" if year else "")] + [c for c in credits if c]) if film_title else "; ".join(c for c in credits if c)
            work = add({"q": q, "kind": "song", "culture": "in", "year": year, "links": 0, "awards": 0, "canon": [],
                        "title": track["title"], "native": track.get("native_title", ""), "maker": ", ".join(track.get("singers", [])[:2]),
                        "summary": summary, "genres": [], "films": [track["film"]] if track.get("film") in film_rows else [],
                        "wiki": {}, "enwiki": "", "film_links": (film or {}).get("links", 0)},
                       credited=[track.get("composer", ""), track.get("lyricist", "")])
        else:
            for name in [track.get("composer", ""), track.get("lyricist", "")] + track.get("singers", []):
                if name:
                    people[q].add(norm(name))
            if not work["maker"] and track.get("singers"):
                work["maker"] = ", ".join(track["singers"][:2])
            if not work["native"] and track.get("native_title"):
                work["native"] = track["native_title"]
        for label in track.get("labels", []):
            if label not in work["canon"]:
                work["canon"].append(label)
        if track.get("raga"):
            work.setdefault("ragas", []).append(track["raga"])
        if track.get("film") in film_rows:
            links.append((q, track["film"], "from film", "features song", 1.0, "w"))
            work.setdefault("film_links", film_rows[track["film"]].get("links", 0))

    # 4. Wikipedia lead-sentence links between songs, and from a song to the film it was written for.
    for q, entry in wiki.items():
        for phrase, target_title, target_q in entry.get("relations", []):
            if target_q in film_rows:
                links.append((q, target_q, "from film", "features song", 1.0, "w"))
                continue
            relation = relation_for(phrase)
            if not relation:
                continue
            if target_q:
                links.append((q, target_q, *relation, "w"))
            elif relation[0] in TITLE_JOINS:
                # Joined on title alone only where the phrase names a recording ("samples X").
                links.append((q, "title:" + norm(target_title), *relation, "w"))

    # 5. Samples, covers, versions and borrowing from the relation crawls. An end not in the
    # catalogue becomes a small row of its own so the link survives, in its artist's culture
    # when the artist has other songs in the index (Dean Martin is American wherever he is named).
    for gid, (q, _how) in mb_matches.items():
        by_mb.setdefault("mb:" + gid.lower(), q)
    stubs = Counter()
    artist_culture = defaultdict(Counter)
    for work in list(works.values()):
        if work["culture"] in CAPS:
            for name in work["maker"].split(", "):
                if name:
                    artist_culture[norm(name)][work["culture"]] += 1

    def resolve(side, source="w", stub=True):
        q = side.get("qid") or ""
        if q in works:
            return q
        if q.startswith("mb:") and q.lower() in by_mb and by_mb[q.lower()] in works:
            return by_mb[q.lower()]
        title = side.get("title", "")
        artist = norm(side.get("artist", ""))

        def credited(candidate):
            """The side's artist is among the song's singers, composers or lyricists."""
            return any(artist == name or (artist.split()[:1] == name.split()[:1] and len(artist) > 3) or artist in name or name in artist
                       for name in people[candidate] if name)

        def plausible(candidate):
            # With no artist to go on, the culture and the year have to agree.
            work = works[candidate]
            if side.get("culture") in CAPS and work["culture"] != side["culture"]:
                return False
            return not (side.get("year") and work.get("year") and abs(side["year"] - work["year"]) > 1)

        candidates = by_title.get(norm(title), [])
        if side.get("culture") == "in" or not candidates:
            # Indian titles are romanised freely; the loose spelling finds the same song.
            candidates = candidates + [c for c in by_loose.get(loose(title), []) if c not in candidates]
        for candidate in candidates:
            if (artist and credited(candidate)) or (not artist and plausible(candidate)):
                return candidate
        if artist:
            # A credit that matches nobody (a composer where the song lists its singers) still
            # joins an Indian song with the same title in the same culture and year.
            for candidate in candidates:
                if works[candidate]["culture"] == "in" and side.get("culture") == "in" and plausible(candidate):
                    return candidate
        if not title or not stub or stubs[source] >= STUB_BUDGET.get(source, 300):
            return None
        culture = side.get("culture") if side.get("culture") in CAPS else None
        if culture is None and artist in artist_culture:
            culture = artist_culture[artist].most_common(1)[0][0]
        culture = culture or "xx"
        q = sid(culture, title, side.get("artist", ""))
        if q not in works:
            stubs[source] += 1
            add({"q": q, "kind": "song", "culture": culture, "year": side.get("year"), "links": 0, "awards": 0, "canon": [],
                 "title": title, "native": "", "maker": side.get("artist", ""), "summary": "", "genres": [], "films": [],
                 "wiki": {}, "enwiki": "", "stub": True})
        return q

    for relation in relations:
        source = relation.get("source", "w")
        if relation.get("forward") in ("written for", "from film"):
            # The far end is a film (fetch_song_lists' Oscar songs): linked when the index has
            # it, never turned into a stub song named after the film.
            a = resolve(relation.get("a", {}), source)
            b = relation.get("b", {}).get("qid")
            b = b if b in film_rows else None
        elif source == "m":
            # MusicBrainz: both ends known, or a sample, interpolation or version whose other
            # end is a known song; never a stub for a cover by an artist nobody here knows.
            a = resolve(relation.get("a", {}), source, stub=False)
            b = resolve(relation.get("b", {}), source, stub=False)
            if (a is None) != (b is None) and relation.get("forward") in MB_STUB_KINDS:
                a = a or resolve(relation.get("a", {}), source)
                b = b or resolve(relation.get("b", {}), source)
        else:
            a = resolve(relation.get("a", {}), source)
            b = resolve(relation.get("b", {}), source)
        if a and b and a != b:
            links.append((a, b, relation["forward"], relation.get("backward") or BACKWARD.get(relation["forward"], relation["forward"]),
                          float(relation.get("strength", 0.6)), relation.get("source", "w")))

    # Titles named in a lead resolve now that every song is in.
    resolved = []
    for a, b, forward, backward, strength, source in links:
        if b.startswith("title:"):
            matches = by_title.get(b[6:], [])
            if not matches:
                continue
            b = matches[0]
        resolved.append((a, b, forward, backward, strength, source))
    links = resolved

    # Themes and moods: Wikipedia categories, genres, ragas, and for a film song half its film's themes.
    for work in works.values():
        themes = {}
        for phrase, weight in work["wiki"].get("themes", []):
            themes[phrase.lower()] = max(themes.get(phrase.lower(), 0), float(weight))
        for genre in work["genres"]:
            themes.setdefault(genre.lower(), 0.55)
        for raga in work.get("ragas", []):
            themes.setdefault(f"raga {raga.lower()}", 0.6)
        for film in work["films"][:1]:
            # A little of the film's world, not its plot devices.
            for phrase, weight in film_rows[film].get("themes", [])[:3]:
                themes.setdefault(phrase, round(0.35 * weight, 2))
        work["themes"] = sorted(themes.items(), key=lambda item: (-item[1], item[0]))[:14]
        work["genre_moods"] = moods(work["genres"] + work.get("ragas", []) + [c for c in work["wiki"].get("categories", []) if "songs" in c.lower()][:6])
        # A soundtrack song with no article of its own stands on its film's renown.
        if not work["links"] and work.get("film_links"):
            work["links"] = max(1, work["film_links"] // 3)

    # Caps: the best-known songs of each culture, always keeping canon songs and link ends.
    linked = Counter(q for a, b, *_ in links for q in (a, b))
    kept = []
    for culture, cap in CAPS.items():
        pool = [w for w in works.values() if w["culture"] == culture]
        pool.sort(key=lambda w: -(w["links"] + 25 * len(w["canon"]) + 10 * min(3, linked[w["q"]]) + 4 * w["awards"]))
        kept += pool[:cap]
    kept_ids = {w["q"] for w in kept}
    kept += [w for w in works.values() if w["culture"] == "xx" and linked[w["q"]]]
    kept_ids |= {w["q"] for w in kept}
    links = [link for link in links if link[0] in kept_ids and (link[1] in kept_ids or link[1] in film_rows)]
    for work in kept:
        work.setdefault("is_remake", False)
        work.setdefault("detail", {})
        work.setdefault("gutenberg", "")
        work.pop("wiki", None)

    counts = Counter((w["culture"]) for w in kept)
    log(f"songs: {len(kept)} kept of {len(works)} ({dict(counts)}); {dict(stubs)} stubs for link ends; {len(links)} links "
        f"({dict(Counter(l[2] for l in links).most_common(8))})")
    return kept, links
