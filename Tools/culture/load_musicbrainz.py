#!/usr/bin/env python3
"""Songs from MusicBrainz: who sampled, covered, translated and quoted whom.

Reads the MusicBrainz full core dump (CC0), a tar.bz2 of PostgreSQL COPY files, in two steps.

  1. Extract. One streaming pass over the archive keeps only the tables in KEEP, written to
     ~/Developer/cipher-data/musicbrainz/tables/ (outside the project and outside iCloud). The
     track table is not kept: it is counted on the fly into how many releases carry each
     recording, the only popularity signal the core data has.
  2. Build. The relationship tables become song relations in the shared format,
     songs/relations_mb.json, plus songs/mb_index.json with the title, credits and lyric
     language of every work and recording those relations name, and songs/mb_matches.json,
     {gid: [qid, how]}, joining those MusicBrainz ids to catalogued songs: through Wikidata's
     P435 or P4404, or ("title") by title and performer where Wikidata has neither.

Genres, tags, ratings and annotations are CC BY-NC-SA, not CC0. Their members stream past
unread and nothing here ever opens them.

A song here is a MusicBrainz work. A recording that plainly performs one work (not a cover, not
a medley) stands for that work, so the album cut, the single and the remaster of a sampled song
fold into one song. Remixes and covers stay recordings: they are versions in their own right.

Only relations that touch an anchor are kept: at most --per-song of each kind per anchor
(--covers for covers), catalogued partners first, then partners from another of the four
cultures, then (for covers) covers by an artist the catalogue knows, then the most released.
Medley and karaoke performances are neither covers nor originals. Anchors are the catalogued songs of songs/song_details.json
(by P435, P4404, or title and performer) and every song-type work with at least
--min-recordings recordings. Relations between two songs from outside the four cultures are
dropped unless one of them is catalogued.

    load_musicbrainz.py --extract-only        step 1 alone (about 10 minutes, no network)
    load_musicbrainz.py                       both steps (step 2 about 5 minutes); the extract is skipped once done
    load_musicbrainz.py --limit 50            keep only the 50 strongest relations (dry run)
    load_musicbrainz.py --max-rows 2000000    read only the head of each big table (smoke test)

A dry run (--limit or --max-rows) writes dryrun_relations_mb.json, dryrun_mb_index.json and
dryrun_mb_matches.json instead, so it never replaces the full files.
"""
import argparse
import bz2
import json
import re
import shutil
import subprocess
import tarfile
import time
import unicodedata
from array import array
from collections import defaultdict
from itertools import zip_longest
from pathlib import Path

from common import DATA, fetch, log

DUMP = Path.home() / "Developer" / "cipher-data" / "musicbrainz" / "mbdump.tar.bz2"
DUMP_SIZE = 7577615628  # fullexport 20260930-002222; pass --dump-size 0 for another dump
SONGS = DATA / "songs"
# The column order of every table, from the server's own schema. Fetched once through the
# cache; a dump whose rows do not have that many columns stops the run rather than misread.
SCHEMA_URL = "https://raw.githubusercontent.com/metabrainz/musicbrainz-server/master/admin/sql/CreateTables.sql"

KEEP = ["artist", "artist_credit", "artist_credit_name", "iso_3166_1", "l_artist_work", "l_recording_recording",
        "l_recording_work", "l_work_work", "language", "link", "link_attribute", "link_attribute_type", "link_type",
        "recording", "work", "work_language", "work_type"]
# Read on the fly and not kept. The archive is in alphabetical order, so which release each medium
# belongs to and the earliest date of each release are known before the tracks go by; each
# recording then gets its release count and the year it was first released.
REDUCED = ("medium", "release_country", "release_unknown_country", "track")
OUTPUTS = ["recording_tracks.u32", "recording_years.u16"]
NEVER = ("tag", "rating", "annotation", "genre")  # CC BY-NC-SA
assert not any(word in table for table in KEEP + list(REDUCED) for word in NEVER)
TOP_FILES = ("SCHEMA_SEQUENCE", "TIMESTAMP", "REPLICATION_SEQUENCE")

TABLES = DUMP.parent / "tables"
SCHEMA = {}


# ---------------------------------------------------------------- step 1: extract


def load_schema():
    """{table: [column, ...]} in COPY order, read from CreateTables.sql."""
    body = fetch(SCHEMA_URL)
    if body is None:
        raise SystemExit("could not fetch CreateTables.sql")
    code = re.sub(r"--[^\n]*", "", body.decode())
    schema = {}
    for match in re.finditer(r"\bCREATE TABLE (\w+)\s*\(", code):
        # The table's body runs to the matching parenthesis; its items are split at the commas
        # outside any nested CHECK (...), and every item that is not a constraint is a column.
        depth, items, item = 1, [], []
        for char in code[match.end():]:
            depth += (char == "(") - (char == ")")
            if depth == 0:
                break
            if char == "," and depth == 1:
                items.append("".join(item))
                item = []
            else:
                item.append(char)
        items.append("".join(item))
        words = [item.split()[0].strip('"') for item in items if item.split()]
        schema[match.group(1)] = [word for word in words if word.upper() not in ("CONSTRAINT", "CHECK", "PRIMARY", "UNIQUE", "FOREIGN", "EXCLUDE")]
    return schema


def dump_ready(dump, expected):
    """True once the download is whole: the published size, and nothing written for a minute."""
    if not dump.exists():
        return False
    stat = dump.stat()
    if expected and stat.st_size != expected:
        log(f"dump is {stat.st_size:,} of {expected:,} bytes")
        return False
    return time.time() - stat.st_mtime > 60


def decompressed(dump):
    """The archive as a stream. bzip2 runs in its own process (a parallel one if installed), so
    unpacking and writing proceed side by side."""
    tool = shutil.which("lbzip2") or shutil.which("pbzip2") or shutil.which("bzip2")
    if not tool:
        return None, bz2.open(dump, "rb")
    process = subprocess.Popen([tool, "-dc", str(dump)], stdout=subprocess.PIPE, bufsize=1 << 22)
    return process, process.stdout


def ensure(values, index):
    """Grow a bytearray or an array so that values[index] exists."""
    if index >= len(values):
        more = index - len(values) + 1_000_000
        if isinstance(values, bytearray):
            values.extend(bytes(more))
        else:
            values.frombytes(bytes(values.itemsize * more))


def reduce_member(name, handle, state):
    """Fold one streamed table into the arrays kept in `state`."""
    columns = {"medium": ("id", "release"), "release_country": ("release", "date_year"),
               "release_unknown_country": ("release", "date_year"), "track": ("recording", "medium")}[name]
    first, second = (SCHEMA[name].index(column) for column in columns)
    cut = max(first, second) + 1
    releases, release_years = state["releases"], state["release_years"]
    if name == "medium":
        for line in handle:
            fields = line.split(b"\t", cut)
            medium = int(fields[first])
            ensure(releases, medium)
            releases[medium] = int(fields[second])
    elif name.startswith("release"):
        for line in handle:
            fields = line.split(b"\t", cut)
            year = int(fields[second]) if fields[second] != b"\\N" else 0
            if 0 < year < 3000:
                release = int(fields[first])
                ensure(release_years, release)
                if not release_years[release] or year < release_years[release]:
                    release_years[release] = year
    else:
        # How many tracks (releases, compilations included) carry each recording, and the year of
        # the earliest release among them.
        if not releases or not release_years:
            log("  track came before medium and the release dates: years will be empty")
        counts, years = state["tracks"], state["years"]
        for line in handle:
            fields = line.split(b"\t", cut)
            recording, medium = int(fields[first]), int(fields[second])
            if recording >= len(counts):
                ensure(counts, recording)
                ensure(years, recording)
            counts[recording] += 1
            release = releases[medium] if medium < len(releases) else 0
            year = release_years[release] if release < len(release_years) else 0
            if year and (not years[recording] or year < years[recording]):
                years[recording] = year


def extract(dump, expected):
    manifest = TABLES / "manifest.json"
    done = json.loads(manifest.read_text()) if manifest.exists() else {}
    same = not dump.exists() or done.get("dump_size") == dump.stat().st_size  # the archive may be deleted once read
    have = done.get("tables", {}) if same else {}
    if same and all(name in have for name in KEEP + OUTPUTS):
        log("tables already extracted in", TABLES, "- schema", done.get("schema_sequence"))
        return
    if not dump_ready(dump, expected):
        raise SystemExit("the dump is not complete yet")
    TABLES.mkdir(parents=True, exist_ok=True)
    process, stream = decompressed(dump)
    kept, passed = {}, 0
    state = {"releases": array("I"), "release_years": array("H"), "tracks": array("I"), "years": array("H")}
    started = time.time()
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        for member in archive:
            name = member.name.removeprefix("mbdump/")
            if not member.isfile():
                continue
            if member.name in TOP_FILES or (member.name.startswith("mbdump/") and name in KEEP):
                target = TABLES / name
                if have.get(name) == member.size and target.exists() and target.stat().st_size == member.size:
                    kept[name] = member.size  # from an earlier pass
                    continue
                partial = TABLES / (name + ".part")
                with archive.extractfile(member) as source, open(partial, "wb") as out:
                    shutil.copyfileobj(source, out, 1 << 22)
                partial.replace(target)
                kept[name] = member.size
                log(f"  kept {name}: {member.size:,} bytes ({time.time() - started:.0f}s)")
            elif member.name.startswith("mbdump/") and name in REDUCED:
                with archive.extractfile(member) as source:
                    reduce_member(name, source, state)
                log(f"  read {name}: {member.size:,} bytes ({time.time() - started:.0f}s)")
                if name == "track":
                    for output, values in zip(OUTPUTS, (state["tracks"], state["years"])):
                        with open(TABLES / output, "wb") as out:
                            values.tofile(out)
                        kept[output] = len(values) * values.itemsize
            else:
                passed += 1  # streams past unread
    if process:
        process.wait()
    missing = [name for name in KEEP + OUTPUTS if name not in kept]
    if missing:
        raise SystemExit(f"the archive lacks {missing}")
    sequence = (TABLES / "SCHEMA_SEQUENCE").read_text().strip() if (TABLES / "SCHEMA_SEQUENCE").exists() else "?"
    manifest.write_text(json.dumps({"dump": str(dump), "dump_size": dump.stat().st_size, "schema_sequence": sequence,
                                    "tables": kept}, indent=1))
    log(f"extracted {len(kept)} files, {passed} members passed over, schema {sequence}, {time.time() - started:.0f}s")


# ---------------------------------------------------------------- step 2: build

# MusicBrainz relationship -> (kind, which end is the derived song, words its link phrase holds).
# A link phrase reads "entity0 <phrase> entity1", so it settles the direction; should a later
# dump word one differently, the run stops rather than turn its arrows round.
SONG_LINKS = {
    ("recording", "recording", "samples material"): ("samples", 0, "samples"),
    ("recording", "recording", "mashes up"): ("samples", 0, "mash-up of"),
    ("recording", "recording", "remix"): ("remix", 0, "remix of"),
    ("recording", "recording", "edit"): ("remix", 0, "edit of"),
    ("work", "work", "musical quotation"): ("quotes", 0, "quotes music from"),
    ("work", "work", "lyrical quotation"): ("quotes", 0, "quotes lyrics from"),
    ("work", "work", "other version"): ("version", 1, "later"),
    ("work", "work", "adaptation"): ("version", 1, "adaptations"),
    ("work", "work", "based on"): ("version", 1, "is the basis for"),
    ("work", "work", "arrangement"): ("version", 1, "arrangements"),
}
# kind -> (the derived song ... its source, the source ... the derived song, strength)
PHRASES = {
    "samples": ("samples", "sampled by", 0.9),
    "quotes": ("interpolates", "interpolated in", 0.85),
    "cover": ("cover of", "covered as", 0.95),
    "version": ("version of", "other version", 0.8),  # a translation is 0.9
    "remix": ("remix of", "remixed as", 0.7),
}
WRITERS = {"composer": "composers", "lyricist": "lyricists", "writer": "writers"}
COVER, TRANSLATED, MEDLEY, KARAOKE = 1, 2, 4, 8
# A parody stays a plain "version of". A medley or a karaoke track is neither the song as first
# made nor a cover worth a link: it never stands for the work, and is never an original or a cover.
ATTRIBUTES = {"cover": COVER, "translated": TRANSLATED, "medley": MEDLEY, "karaoke": KARAOKE}
NOT_PLAIN = COVER | MEDLEY | KARAOKE
SONG_WORK_TYPES = {"Song", "Soundtrack"}  # and works with no type: arias and symphonies are no anchors
ORIGINALS = 8  # plain recordings looked at per work to find who first released it, and when

LANGUAGE_CULTURE = {"eng": "us", "spa": "es", "fra": "fr", **{code: "in" for code in (
    "hin", "urd", "guj", "tam", "tel", "mar", "ben", "pan", "mal", "kan", "bho", "ory", "asm", "raj", "mai", "awa", "kok")}}
NO_LANGUAGE = {"zxx", "mul", "und", "mis"}
COUNTRY_CULTURE = {"US": "us", "GB": "us", "CA": "us", "AU": "us", "IE": "us", "NZ": "us", "IN": "in", "FR": "fr",
                   **{code: "es" for code in ("ES", "MX", "AR", "CO", "CL", "PE", "VE", "CU", "PR", "DO", "UY", "PY",
                                              "BO", "EC", "GT", "HN", "SV", "NI", "CR", "PA")}}
COUNTRY_CULTURE["PK"] = "in"  # as in build_songs: Pakistan's Urdu and Punjabi music sits with India's
UNDECIDED_COUNTRIES = {"BE", "CH", "LU"}  # French or not, only the language can say
# Where an artist credit names several artists: "Ray Charles & Betty Carter", "X feat. Y", "A, B y C".
CREDIT_JOINS = re.compile(r"\s+(?:&|and|feat\.?|ft\.?|featuring|with|x|vs\.?|y|et|con|avec|und)\s+|,\s+", re.I)
FOUR = {"us", "in", "es", "fr"}
# Wikidata's language of a song (P407) as ISO 639-3, for the commonest ones: a song matched by
# title must not be filed in another language (ABBA's Spanish "Mamma Mia" is not the English one).
WIKIDATA_LANGUAGE = {
    "Q1860": "eng", "Q7976": "eng", "Q7979": "eng", "Q150": "fra", "Q1321": "spa", "Q1568": "hin", "Q1617": "urd",
    "Q5137": "guj", "Q1571": "mar", "Q5885": "tam", "Q8097": "tel", "Q9610": "ben", "Q58635": "pan", "Q36236": "mal",
    "Q33673": "kan", "Q5287": "jpn", "Q9027": "swe", "Q652": "ita", "Q188": "deu", "Q9176": "kor", "Q5146": "por",
    "Q750553": "por", "Q7411": "nld", "Q7737": "rus", "Q9288": "heb", "Q1412": "fin", "Q8798": "ukr", "Q13955": "ara",
    "Q7026": "cat", "Q256": "tur", "Q9035": "dan", "Q9056": "ces", "Q809": "pol", "Q9129": "ell", "Q7850": "zho",
    "Q7913": "ron", "Q9067": "hun", "Q294": "isl", "Q9072": "est", "Q9168": "fas"}


def lines(table, limit=None):
    """Raw rows of an extracted table, once its width has been checked against the schema."""
    width = len(SCHEMA[table])
    with open(TABLES / table, "rb", buffering=1 << 22) as handle:
        for count, line in enumerate(handle):
            if count == 0:
                found = line.count(b"\t") + 1
                if found != width:
                    raise SystemExit(f"{table}: {found} columns in the dump, {width} in CreateTables.sql; the schema has moved on")
            elif limit and count >= limit:
                return
            yield line


def rows(table, *columns, limit=None):
    """The asked columns of every row, as raw bytes (b"\\N" is null)."""
    positions = [SCHEMA[table].index(column) for column in columns]
    cut = max(positions) + 1
    for line in lines(table, limit):
        fields = line.rstrip(b"\n").split(b"\t", cut)
        yield [fields[position] for position in positions]


def text(raw):
    """A COPY text field as a string, its escapes undone; None for null."""
    if raw == b"\\N":
        return None
    value = raw.decode("utf-8", "replace")
    if "\\" in value:
        value = re.sub(r"\\(.)", lambda match: {"t": " ", "n": " ", "r": " "}.get(match.group(1), match.group(1)), value)
    return value


def relationship_types():
    """A small number (a slot) for each link type read, and what each slot means."""
    slots, meaning = {}, [None]
    for type_id, entity0, entity1, name, phrase in rows("link_type", "id", "entity_type0", "entity_type1", "name", "link_phrase"):
        key = (entity0.decode(), entity1.decode(), name.decode())
        if key in SONG_LINKS:
            kind, derived, words = SONG_LINKS[key]
            if words not in phrase.decode():
                raise SystemExit(f"link type {key} now reads {phrase.decode()!r}: check its direction")
            what = (key[0], kind, derived)
        elif key == ("recording", "work", "performance"):
            what = ("performance",)
        elif key[:2] == ("artist", "work") and key[2] in WRITERS:
            what = ("writer", WRITERS[key[2]])
        else:
            continue
        slots[int(type_id)] = len(meaning)
        meaning.append(what)
    if len(meaning) - 1 != len(SONG_LINKS) + 1 + len(WRITERS):
        log("  some link types are missing from this dump:", len(meaning) - 1, "found")
    return slots, meaning


def links(slots):
    """For every link id, the slot of its type (0 when not read) and its cover and translated bits."""
    slot = bytearray()
    for link_id, type_id in rows("link", "id", "link_type"):
        wanted = slots.get(int(type_id))
        if wanted:
            ensure(slot, int(link_id))
            slot[int(link_id)] = wanted
    names = {int(i): ATTRIBUTES[n.decode()] for i, n in rows("link_attribute_type", "id", "name") if n.decode() in ATTRIBUTES}
    bits = bytearray(len(slot))
    for link_id, attribute in rows("link_attribute", "link", "attribute_type"):
        link_id, bit = int(link_id), names.get(int(attribute))
        if bit and link_id < len(slot):
            bits[link_id] |= bit
    return slot, bits


def pairs(table, slot, bits, wanted, limit):
    """(slot, entity0, entity1, attribute bits) for every wanted relationship in an l_ table."""
    found = []
    for link_id, entity0, entity1 in rows(table, "link", "entity0", "entity1", limit=limit):
        link_id = int(link_id)
        if link_id < len(slot) and slot[link_id] in wanted:
            found.append((slot[link_id], int(entity0), int(entity1), bits[link_id]))
    return found


def normal(name):
    """A title or a name reduced for matching: no accents, brackets, punctuation or leading "the"."""
    name = re.sub(r"\([^)]*\)|\[[^\]]*\]", " ", name or "")
    name = "".join(c for c in unicodedata.normalize("NFKD", name) if not unicodedata.combining(c)).lower()
    return re.sub(r"^the ", "", re.sub(r"[\W_]+", " ", name).strip())


def person(name):
    """An artist credit's name, or None for MusicBrainz's placeholders ("[unknown]", "Various Artists")."""
    if not name or (name.startswith("[") and name.endswith("]")) or name == "Various Artists":
        return None
    return name


def catalog_ids(path):
    """What the catalogued songs offer for joining: the MusicBrainz ids Wikidata gives them (P435
    works, P4404 recordings) as {gid: [qid, property]}; {normalised title: [(normalised
    performers, sitelinks, qid, ISO 639-3 languages)]} for matching by name the songs Wikidata
    gives no id (a song that has one is never matched again by name: a same-titled work by the same
    artist is another version of it, a translation or a remix); and every catalogued performer's
    normalised name."""
    if not path.exists():
        log(f"no {path.name} yet: the anchors are the most-recorded works only")
        return {}, {}, set()
    details = json.loads(path.read_text())
    joins, names, artists = {}, defaultdict(list), set()
    for qid, info in details.items():
        for prop, field in (("P435", "mb_work"), ("P4404", "mb_recording")):
            for gid in info.get(field) or []:
                joins[gid.lower()] = [qid, prop]
        performers = [normal(label) for _, label in info.get("performers") or [] if normal(label)]
        artists.update(performers)
        if info.get("mb_work") or info.get("mb_recording"):
            continue
        languages = {WIKIDATA_LANGUAGE[q] for q in info.get("languages") or [] if q in WIKIDATA_LANGUAGE}
        for title in {title for title in (info.get("labels") or {}).values() if title}:
            if performers and normal(title):
                names[normal(title)].append((performers, info.get("sitelinks") or 0, qid, languages))
    log(f"catalogue: {len(details):,} songs, {len(joins):,} MusicBrainz ids, {len(names):,} titles to match by name")
    return joins, names, artists


def recordings(ids, gids=frozenset()):
    """{recording id: (gid, title, artist credit id)} for the ids and gids asked."""
    found = {}
    for rec, gid, name, credit in rows("recording", "id", "gid", "name", "artist_credit"):
        rec = int(rec)
        if rec in ids or gid in gids:
            found[rec] = (gid.decode(), text(name), int(credit))
    return found


def works(ids, gids=frozenset(), types=None, titles=None):
    """{work id: (gid, title)} for the ids and gids asked. Given `types`, also notes each work's
    type; given `titles` (normalised titles), also returns the works that bear one."""
    found, titled = {}, {}
    for work, gid, name, type_id in rows("work", "id", "gid", "name", "type"):
        work = int(work)
        if types is not None and type_id != b"\\N":
            ensure(types, work)
            types[work] = min(int(type_id), 255)
        if work in ids or gid in gids:
            found[work] = (gid.decode(), text(name))
        if titles:
            key = normal(text(name))
            if key in titles:
                titled[work] = (gid.decode(), key)
    return (found, titled) if titles is not None else found


def performances(slot, bits, performance, tracks, watch, limit):
    """Per work, how many recordings perform it, how many releases carry them, and its most
    released plain recording. For each watched recording, the one work it plainly performs, or 0
    for a cover or a medley."""
    counts, released, top, plain = array("I"), array("I"), array("I"), {}
    for link_id, rec, work in rows("l_recording_work", "link", "entity0", "entity1", limit=limit):
        link_id = int(link_id)
        if link_id >= len(slot) or slot[link_id] != performance:
            continue
        rec, work = int(rec), int(work)
        for values in (counts, released, top):
            ensure(values, work)
        counts[work] += 1
        released[work] += tracks[rec] if rec < len(tracks) else 0
        odd = bits[link_id] & NOT_PLAIN
        if not odd and (not top[work] or released_count(tracks, rec) > released_count(tracks, top[work])):
            top[work] = rec
        if rec in watch:
            this = 0 if odd else work
            plain[rec] = this if plain.get(rec, this) == this else 0
    return counts, released, top, plain


def released_count(tracks, rec):
    return tracks[rec] if rec < len(tracks) else 0


def match_by_name(titled, top, names):
    """{work: qid} for works whose title is a catalogued song's, whose most released plain
    recording is credited to one of its performers, and whose lyric language, when both sides
    record one, is the song's."""
    facts = recordings({top[work] for work in titled if work < len(top) and top[work]})
    credited = {credit: " %s " % normal(person(name)) for credit, name in credit_names({c for _, _, c in facts.values()}).items()}
    sung = {work: {three for _, three in found if three not in NO_LANGUAGE} for work, found in languages_of(set(titled)).items()}
    matched = {}
    for work, (gid, key) in titled.items():
        rec = top[work] if work < len(top) else 0
        credit = credited.get(facts[rec][2]) if rec in facts else None
        if not credit or not credit.strip():
            continue
        spoken = sung.get(work)
        fits = [(links, qid) for performers, links, qid, languages in names[key]
                if any(" %s " % p in credit for p in performers) and not (spoken and languages and not spoken & languages)]
        if fits:
            matched[work] = (gid, max(fits)[1])
    return matched


def covers_and_originals(slot, bits, performance, anchor_works, anchor_recs, kept_works, tracks, years, limit):
    """Cover recordings of the anchor works (and anchor recordings that are covers), most released
    first. For the works kept, their most released plain recordings, plus the earliest dated one,
    which is the likeliest original."""
    covers, originals, earliest = defaultdict(list), defaultdict(list), {}
    released = lambda rec: tracks[rec] if rec < len(tracks) else 0
    for link_id, rec, work in rows("l_recording_work", "link", "entity0", "entity1", limit=limit):
        link_id = int(link_id)
        if link_id >= len(slot) or slot[link_id] != performance:
            continue
        rec, work = int(rec), int(work)
        if bits[link_id] & (MEDLEY | KARAOKE):
            continue
        if bits[link_id] & COVER:
            if work in anchor_works or rec in anchor_recs:
                covers[work].append(rec)
        elif work in kept_works:
            originals[work].append(rec)
            year = years[rec] if rec < len(years) else 0
            if year and (work not in earliest or (year, -released(rec)) < earliest[work][:2]):
                earliest[work] = (year, -released(rec), rec)
    for recs in covers.values():
        recs.sort(key=released, reverse=True)
    for work, recs in originals.items():
        recs.sort(key=released, reverse=True)
        del recs[ORIGINALS:]
        if work in earliest and earliest[work][2] not in recs:
            recs.append(earliest[work][2])
    return covers, originals


def load_array(name, code):
    values = array(code)
    values.frombytes((TABLES / name).read_bytes())
    return values


def credit_names(ids):
    return {int(i): text(name) for i, name in rows("artist_credit", "id", "name") if int(i) in ids}


def credit_countries(ids):
    """{artist credit: ISO country of its first artist}, where MusicBrainz files the artist under a country."""
    first = {}
    for credit, position, artist in rows("artist_credit_name", "artist_credit", "position", "artist"):
        if position == b"0" and int(credit) in ids:
            first[int(credit)] = int(artist)
    codes = {int(area): code.decode() for area, code in rows("iso_3166_1", "area", "code")}
    wanted = set(first.values())
    country = {int(artist): codes.get(int(area)) for artist, area in rows("artist", "id", "area")
               if area != b"\\N" and int(artist) in wanted}
    return {credit: country.get(artist) for credit, artist in first.items()}


def writers_of(ids, slot, meaning):
    """{work: {"composers": [...], "lyricists": [...], "writers": [...]}} as artist names, in credit order."""
    roles = defaultdict(lambda: defaultdict(list))
    for link_id, artist, work in rows("l_artist_work", "link", "entity0", "entity1"):
        work, link_id = int(work), int(link_id)
        if work in ids and link_id < len(slot) and meaning[slot[link_id]] and meaning[slot[link_id]][0] == "writer":
            roles[work][meaning[slot[link_id]][1]].append(int(artist))
    people = {artist for role in roles.values() for names in role.values() for artist in names}
    names = {int(i): text(name) for i, name in rows("artist", "id", "name") if int(i) in people}
    return {work: {role: list(dict.fromkeys(names[a] for a in artists if a in names)) for role, artists in role_map.items()}
            for work, role_map in roles.items()}


def languages_of(ids):
    """{work: [(code to show, ISO 639-3 code)]}: ISO 639-1 where there is one."""
    codes = {}
    for language, one, three, two in rows("language", "id", "iso_code_1", "iso_code_3", "iso_code_2t"):
        three = text(three) or text(two) or ""
        codes[int(language)] = (text(one) or three, three)
    found = defaultdict(list)
    for work, language in rows("work_language", "work", "language"):
        if int(work) in ids and int(language) in codes:
            found[int(work)].append(codes[int(language)])
    return found


def country_culture(country):
    if not country or country in UNDECIDED_COUNTRIES:
        return None
    return COUNTRY_CULTURE.get(country, "xx")


def culture_of(languages, country):
    """us, in, es, fr or xx from the lyric language, else from the performer's country; None if neither says."""
    spoken = [three for _, three in languages if three not in NO_LANGUAGE]
    if len(spoken) <= 2:  # a song in three or more languages is filed by who sings it
        cultures = {LANGUAGE_CULTURE.get(three, "xx") for three in spoken}
        for culture in ("in", "es", "fr", "us", "xx"):  # a bilingual song belongs with its other language
            if culture in cultures:
                return culture
    return country_culture(country)


def build(args):
    started = time.time()
    slots, meaning = relationship_types()
    slot, bits = links(slots)
    performance = meaning.index(("performance",))
    recording_slots = {s for s, what in enumerate(meaning) if what and what[0] == "recording"}
    work_slots = {s for s, what in enumerate(meaning) if what and what[0] == "work"}
    recording_pairs = pairs("l_recording_recording", slot, bits, recording_slots, args.max_rows)
    work_pairs = pairs("l_work_work", slot, bits, work_slots, args.max_rows)
    log(f"{len(recording_pairs):,} recording links and {len(work_pairs):,} work links of the kinds read ({time.time() - started:.0f}s)")

    tracks = load_array("recording_tracks.u32", "I")
    years = load_array("recording_years.u16", "H")
    joins, names, artists = catalog_ids(args.catalog)
    work_gids = {gid.encode() for gid, (_, prop) in joins.items() if prop == "P435"}
    recording_gids = {gid.encode() for gid, (_, prop) in joins.items() if prop == "P4404"}
    paired = {rec for _, entity0, entity1, _ in recording_pairs for rec in (entity0, entity1)}
    found = recordings(paired, recording_gids)
    catalog_recs = {rec for rec, facts in found.items() if facts[0].encode() in recording_gids}
    types = bytearray()
    by_id, titled = works(set(), work_gids, types, set(names))
    catalog_works = set(by_id)
    counts, released, top, plain = performances(slot, bits, performance, tracks, paired | catalog_recs, args.max_rows)
    # Most catalogued songs have no MusicBrainz id in Wikidata: find them by title and performer.
    lifted = {plain[rec] for rec in catalog_recs if plain.get(rec)}  # Wikidata's own links win
    matched = match_by_name({work: v for work, v in titled.items() if work not in catalog_works | lifted}, top, names)
    for work, (gid, qid) in matched.items():
        joins.setdefault(gid, [qid, "title"])
    catalog_works |= set(matched)
    log(f"catalogue matched {len(catalog_works):,} works ({len(matched):,} by title and performer) "
        f"and {len(catalog_recs):,} recordings ({time.time() - started:.0f}s)")

    # Anchors: the catalogued songs, and every song-type work recorded at least --min-recordings times.
    song_types = {int(i) for i, name in rows("work_type", "id", "name") if name.decode() in SONG_WORK_TYPES}
    anchor_works = {work for work, count in enumerate(counts) if count >= args.min_recordings
                    and (work >= len(types) or types[work] == 0 or types[work] in song_types)}
    log(f"{len(anchor_works):,} song works recorded {args.min_recordings} times or more")
    anchor_works |= catalog_works
    shown = {}  # a song the catalogue knows only by one of its recordings is printed with that recording's id
    for rec in catalog_recs:
        work = plain.get(rec)
        if work:
            anchor_works.add(work)
            if work not in catalog_works:
                shown[("w", work)] = found[rec][0]
    anchors = {("w", work) for work in anchor_works} | {("r", rec) for rec in catalog_recs}
    known = {("w", work) for work in catalog_works} | {("r", rec) for rec in catalog_recs} | set(shown)

    def song(rec):
        """A recording as a song: the work it plainly performs, when it performs exactly one."""
        work = plain.get(rec)
        return ("w", work) if work else ("r", rec)

    def weight(side):
        values = released if side[0] == "w" else tracks
        return values[side[1]] if side[1] < len(values) else 0

    # (derived song, source song, kind) -> [strength, (entity, id) whose page states it, how to tell
    # whether it crosses cultures: the two artist credits, or True for a translation]
    candidates = {}

    def propose(new, old, kind, strength, origin, credits):
        if new == old or (new not in anchors and old not in anchors):
            return
        key = (new, old, kind)
        if key not in candidates or candidates[key][0] < strength:
            candidates[key] = [strength, origin, credits]

    for s, entity0, entity1, _ in recording_pairs:
        _, kind, derived = meaning[s]
        new, old = (entity0, entity1) if derived == 0 else (entity1, entity0)
        credits = (found[new][2], found[old][2]) if new in found and old in found else None
        if kind == "remix":
            if not credits or credits[0] == credits[1]:
                continue  # an artist's own mixes and edits of a song are the same song
            propose(("r", new), song(old), kind, PHRASES[kind][2], ("recording", new), credits)
        else:
            propose(song(new), song(old), kind, PHRASES[kind][2], ("recording", new), credits)
    for s, entity0, entity1, attributes in work_pairs:
        _, kind, derived = meaning[s]
        new, old = (entity0, entity1) if derived == 0 else (entity1, entity0)
        translated = bool(attributes & TRANSLATED)
        propose(("w", new), ("w", old), kind, 0.9 if translated else PHRASES[kind][2], ("work", new), translated or None)
    log(f"{len(candidates):,} sample, quotation, version and remix links touch an anchor")

    kept_works = anchor_works | {side[1] for key in candidates for side in key[:2] if side[0] == "w"}
    covers, originals = covers_and_originals(slot, bits, performance, anchor_works, catalog_recs, kept_works, tracks, years, args.max_rows)
    wanted = {rec for recs in covers.values() for rec in recs} | {originals[work][0] for work in covers if originals.get(work)}
    found.update(recordings(wanted - found.keys()))
    for work, recs in covers.items():
        original = found[originals[work][0]][2] if originals.get(work) and originals[work][0] in found else None
        seen = {original}
        for rec in recs:
            credit = found[rec][2] if rec in found else None
            if credit is None or credit in seen:
                continue  # one cover per artist, and none by the song's own artist
            seen.add(credit)
            propose(("r", rec), ("w", work), "cover", PHRASES["cover"][2], ("recording", rec), (credit, original))
    log(f"{len(candidates):,} candidate relations with covers ({time.time() - started:.0f}s)")

    # A link between two cultures (by the country of the artists) is what the app is for.
    credit_ids = {c for value in candidates.values() if isinstance(value[2], tuple) for c in value[2] if c}
    cultures = {credit: country_culture(code) for credit, code in credit_countries(credit_ids).items()}

    def crossing(key):
        credits = candidates[key][2]
        if credits is True or not credits:
            return bool(credits)
        a, b = (cultures.get(credit) for credit in credits)
        return bool(a in FOUR and b in FOUR and a != b)

    # The series that release most covers (Kidz Bop, lullaby, string-quartet and 8-bit albums) would
    # take every cover place by release count alone: a cover by an artist the catalogue knows comes first.
    cover_credits = {candidates[key][2][0] for key in candidates if key[2] == "cover"}
    famous = {credit for credit, name in credit_names(cover_credits).items() if person(name)
              and any(normal(part) in artists for part in [name, *CREDIT_JOINS.split(name)])}

    # At most --per-song of each kind per anchor (--covers for covers): catalogued partners first,
    # then those from another culture, then (covers) those by a catalogued artist, then the most released.
    groups = defaultdict(list)
    for key in candidates:
        new, old, kind = key
        cross = crossing(key)
        if new in anchors:
            groups[(new, kind, 0)].append(((old in known, cross, weight(old)), key))
        if old in anchors:
            known_artist = kind == "cover" and candidates[key][2][0] in famous
            groups[(old, kind, 1)].append(((new in known, cross, known_artist, weight(new)), key))
    kept = set()
    for (_, kind, _), entries in groups.items():
        entries.sort(key=lambda entry: entry[0], reverse=True)
        kept.update(key for _, key in entries[:args.covers if kind == "cover" else args.per_song])
    ranked = sorted(kept, key=lambda key: (key[0] in known or key[1] in known, crossing(key), candidates[key][0],
                                           min(weight(key[0]), weight(key[1]))), reverse=True)
    relations, index = describe(ranked, candidates, found, originals, shown, known, years, slot, meaning, started, args.limit)
    used = index["work"].keys() | index["recording"].keys()
    return relations, index, {gid: join for gid, join in joins.items() if gid in used}


def describe(ranked, candidates, found, originals, shown, known, year_of, slot, meaning, started, limit):
    """The kept relations in the shared format, and the index of everything they name. Relations
    between two songs from outside the four cultures are dropped unless one is catalogued."""
    if limit:  # a dry run shows every kind: the best of each in turn
        kinds = defaultdict(list)
        for key in ranked:
            kinds[key[2]].append(key)
        ranked = [key for turn in zip_longest(*kinds.values()) for key in turn if key][:limit * 2]
    side_works = {side[1] for key in ranked for side in key[:2] if side[0] == "w"}
    origin_works = {candidates[key][1][1] for key in ranked if candidates[key][1][0] == "work"}
    side_recs = {side[1] for key in ranked for side in key[:2] if side[0] == "r"}
    found.update(recordings({rec for work in side_works for rec in originals.get(work, [])} - found.keys()))
    titles = works(side_works | origin_works)
    recs = side_recs | {rec for work in side_works for rec in originals.get(work, []) if rec in found}
    years = {rec: year_of[rec] for rec in recs if rec < len(year_of) and year_of[rec]}

    # Who first released each song, and when: its earliest plain recording, the most released on a tie.
    first = {}
    for work in side_works:
        plain = [rec for rec in originals.get(work, []) if rec in found]
        if plain:  # already ordered most released first
            first[work] = plain[min(range(len(plain)), key=lambda i: (years.get(plain[i], 9999), i))]
    credits = {found[rec][2] for rec in side_recs if rec in found} | {found[rec][2] for rec in first.values()}
    names = {credit: person(name) for credit, name in credit_names(credits).items()}
    countries = credit_countries(credits)
    writers = writers_of(side_works, slot, meaning)
    languages = languages_of(side_works)
    log(f"names, credits, years and languages read ({time.time() - started:.0f}s)")

    entries = {}  # gid -> (index section, entry), filed only for the relations kept

    def work_side(work):
        gid, title = titles.get(work, ("", None))
        roles = writers.get(work, {})
        composers = roles.get("composers") or roles.get("writers") or []
        lyricists = roles.get("lyricists") or roles.get("writers") or []
        opener = first.get(work)
        artist = names.get(found[opener][2]) if opener else None
        dated = [years[rec] for rec in originals.get(work, []) if rec in years]
        shown_gid = shown.get(("w", work), gid)
        if shown_gid == gid:
            entries[gid] = ("work", {"title": title, "composers": composers, "lyricists": lyricists,
                                     "language": "+".join(code for code, _ in languages.get(work, [])) or None})
        else:
            entries[shown_gid] = ("recording", {"title": title, "artist": artist or ""})
        country = countries.get(found[opener][2]) if opener else None
        # "" when nobody is known, as the other relation files write it: build_songs makes a stub's
        # maker of it and splits it.
        return {"title": title, "artist": artist or " & ".join((composers or lyricists)[:2]),
                "qid": "mb:" + shown_gid, "culture": culture_of(languages.get(work, []), country),
                "year": min(dated) if dated else None}

    def recording_side(rec, work=None):
        gid, title, credit = found[rec]
        if not names.get(credit):
            return None  # credited to "[unknown]" and the like: a bootleg or a mislabelled file
        entries[gid] = ("recording", {"title": title, "artist": names.get(credit)})
        return {"title": title, "artist": names.get(credit), "qid": "mb:" + gid,
                "culture": culture_of(languages.get(work, []) if work else [], countries.get(credit)), "year": years.get(rec)}

    relations, index, catalogued = [], {"work": {}, "recording": {}}, 0
    for key in ranked:
        new, old, kind = key
        strength, (entity, number), _ = candidates[key]
        if any(side[0] == "r" and side[1] not in found for side in (new, old)):
            continue
        b = work_side(old[1]) if old[0] == "w" else recording_side(old[1])
        # A cover or a remix sings in the language of the song it remakes; a recording that samples
        # one does not (Funkdoobiest sampling Los Ángeles Negros stays American).
        remake = old[1] if old[0] == "w" and kind in ("cover", "remix") else None
        a = work_side(new[1]) if new[0] == "w" else recording_side(new[1], remake)
        if a is None or b is None:
            continue
        if new not in known and old not in known and a["culture"] in (None, "xx") and b["culture"] in (None, "xx"):
            continue
        page_gid = found[number][0] if entity == "recording" else titles.get(number, ("",))[0]
        forward, backward, _ = PHRASES[kind]
        relations.append({"a": a, "b": b, "forward": forward, "backward": backward, "strength": strength,
                          "source": "m", "page": f"https://musicbrainz.org/{entity}/{page_gid}"})
        for side in (a, b):
            section, entry = entries[side["qid"][3:]]
            index[section][side["qid"][3:]] = entry
        catalogued += new in known or old in known
        if limit and len(relations) >= limit:
            break
    tally = defaultdict(int)
    for relation in relations:
        tally[relation["forward"]] += 1
    crossing = sum(1 for r in relations if r["a"]["culture"] and r["b"]["culture"] and r["a"]["culture"] != r["b"]["culture"])
    log(f"{len(relations):,} relations ({dict(tally)}), {crossing:,} across cultures, "
        f"{catalogued:,} on catalogued songs")
    return relations, index


def main():
    global TABLES, SCHEMA
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--dump", type=Path, default=DUMP)
    parser.add_argument("--dump-size", type=int, default=DUMP_SIZE, help="expected size in bytes, 0 to skip the check")
    parser.add_argument("--tables", type=Path, default=TABLES)
    parser.add_argument("--extract-only", action="store_true")
    parser.add_argument("--catalog", type=Path, default=SONGS / "song_details.json", help="songs whose MusicBrainz ids anchor the relations")
    parser.add_argument("--min-recordings", type=int, default=40, help="a work recorded this often is an anchor too")
    parser.add_argument("--per-song", type=int, default=12, help="relations of each kind kept per anchor")
    parser.add_argument("--covers", type=int, default=8, help="covers kept per anchor")
    parser.add_argument("--limit", type=int, default=0, help="keep only the N strongest relations (dry runs)")
    parser.add_argument("--max-rows", type=int, default=0, help="read only the first N rows of each relationship table")
    parser.add_argument("--out", type=Path, default=SONGS)
    args = parser.parse_args()
    TABLES = args.tables
    SCHEMA = load_schema()
    extract(args.dump, args.dump_size)
    if args.extract_only:
        return
    relations, index, joins = build(args)
    args.out.mkdir(parents=True, exist_ok=True)
    # A dry run never replaces the full files: build_songs reads every songs/relations_*.json.
    prefix = "dryrun_" if args.limit or args.max_rows else ""
    (args.out / f"{prefix}relations_mb.json").write_text(json.dumps(relations, ensure_ascii=False))
    (args.out / f"{prefix}mb_index.json").write_text(json.dumps(index, ensure_ascii=False))
    (args.out / f"{prefix}mb_matches.json").write_text(json.dumps(joins, ensure_ascii=False))
    log(f"wrote {prefix}relations_mb.json, {prefix}mb_index.json ({len(index['work']):,} works, {len(index['recording']):,} "
        f"recordings) and {prefix}mb_matches.json ({len(joins):,} MusicBrainz ids joined to catalogued songs)")


if __name__ == "__main__":
    main()
