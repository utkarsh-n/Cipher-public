#!/usr/bin/env python3
"""Songs step 2: what Wikidata knows about each catalogued song.

Titles in the writer's languages, a one-line description, who sang, wrote, composed and
produced it, when, genres, album, film, awards, the MusicBrainz and WhoSampled ids that join it
to other sources, and the links that make two songs relatives (samples, quotes, translation of,
remix of, based on, inspired by, cover version). Facts only: no lyrics are read or kept.

Three passes:
  1. every song in song_catalog.json, 250 to a query, three queries at a time;
  2. the songs at the far end of those links that the catalogue lacks (what a catalogued song
     samples, and the songs that sample it), so the builder can name them; one hop only, and
     only items typed as songs (a film or novel a song is based on is not fetched);
  3. every performer's countries (citizenship, country of origin, where a band was formed).
Has its own property map: fetch_details.PROPERTIES is the cache key of the film crawl and stays
as it is. Reads songs/song_catalog.json, writes songs/song_details.json.
"""
import argparse
import json
import re
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from common import DATA, SPARQL, cache_path, log, qid, sparql

SONGS = DATA / "songs"
BATCH = 250
ENTITY = "http://www.wikidata.org/entity/"

# Values that are people or things with a name worth keeping (English, else multilingual).
CREDITS = {"performers": "P175", "composers": "P86", "lyricists": "P676", "producers": "P162",
           "genres": "P136", "albums": "P361", "awards": "P166", "nominations": "P1411"}
# Values kept as they are: a date, ids of other items, ids in other databases.
PLAIN = {"date": "P577", "languages": "P407", "countries": "P495", "films": "P9899",
         "mb_work": "P435", "mb_recording": "P4404", "whosampled": "P10720"}
# Song-to-song links, read as "this song <property> the target".
RELATIONS = ["P5707", "P6166", "P6670", "P9745", "P9810", "P5059", "P144", "P941", "P4969", "P2550"]
COVER_VERSION = "Q155171"
# Links looked for in reverse too ("which songs sample this one?"). P2550 is left out: it only
# ties a recording to its composition, and a famous song has many recordings.
INCOMING = [prop for prop in RELATIONS if prop != "P2550"]
# What counts as a song at the far end of a link, either way (not a film, book or poem it is
# based on or that is based on it): song, single, musical work/composition, music track with
# vocals, cover version, musical work, composed musical work, audio track, music composition,
# national anthem, audio recording (how some originals are typed, e.g. "Pastime Paradise").
SONG_CLASSES = ["Q7366", "Q134556", "Q105543609", "Q55850593", "Q155171", "Q2188189", "Q207628", "Q7302866",
                "Q105107008", "Q23691", "Q3302947"]
# Catalogue entries that are a film's soundtrack album (fetch_song_catalog's P406 pass), not songs.
ALBUM_CLASSES = {"Q482994", "Q4176708"}
LABELS = ["en", "es", "fr", "hi", "gu"]
WIKIS = ["en", "es", "fr", "hi", "gu", "ta", "te", "mr", "bn", "pa", "ml", "kn", "ur"]
SITES = {f"https://{lang}.wikipedia.org/": lang for lang in WIKIS}

CREDIT_UNIONS = " UNION ".join('{ ?item wdt:%s ?v. BIND("%s" AS ?p) }' % (prop, name) for name, prop in CREDITS.items())
PLAIN_UNIONS = " UNION ".join(['{ ?item wdt:%s ?v. BIND("%s" AS ?p) }' % (prop, name) for name, prop in PLAIN.items()] +
                              ['{ ?item wdt:%s ?v. BIND("%s" AS ?p) }' % (prop, prop) for prop in RELATIONS] +
                              ['{ ?item wdt:P31 wd:%s. BIND(wd:%s AS ?v) BIND("P31" AS ?p) }' % (COVER_VERSION, COVER_VERSION)])
SITE_LIST = ", ".join("<%s>" % site for site in SITES)
LABEL_LIST = ", ".join('"%s"' % lang for lang in LABELS + ["mul"])
INCOMING_LIST = " ".join("wdt:" + prop for prop in INCOMING)
SONG_CLASS_LIST = ", ".join("wd:" + cls for cls in SONG_CLASSES)


def ask(query):
    """sparql(), but a reply that was cut off mid-stream is dropped from the cache, so that
    a re-run asks again instead of failing on the same broken file forever."""
    rows = sparql(query)
    if rows is None:
        cache_path(SPARQL, {"query": query, "format": "json"})[1].unlink(missing_ok=True)
    return rows


def one_batch(batch, incoming=True):
    """Four small queries rather than one large one: credits with their names, plain values and
    links, the item's own names and articles, and (for catalogued songs) who links to it.
    Returns {item: {field: {value: label}}}, the songs linking in, and whether all four answered."""
    values = " ".join("wd:" + item for item in batch)
    found = {item: defaultdict(dict) for item in batch}
    complete = True

    rows = ask("""
        SELECT ?item ?p ?v ?vl (LANG(?vl) AS ?ll) WHERE {
          VALUES ?item { %s }
          %s
          OPTIONAL { ?v rdfs:label ?vl FILTER(LANG(?vl) IN ("en", "mul")) }
        }""" % (values, CREDIT_UNIONS))
    complete &= rows is not None
    for row in rows or []:
        if not row["v"].startswith(ENTITY):
            continue  # "unknown value"
        bucket = found[qid(row["item"])][row["p"]]
        value = qid(row["v"])
        # An item can come back twice, with an English and a "mul" label; English wins.
        if value not in bucket or row.get("ll") == "en":
            bucket[value] = row.get("vl", "")

    rows = ask("""SELECT ?item ?p ?v WHERE { VALUES ?item { %s } %s }""" % (values, PLAIN_UNIONS))
    complete &= rows is not None
    for row in rows or []:
        value = row["v"]
        if value.startswith(ENTITY):
            value = qid(value)
        elif value.startswith("http"):
            continue  # "unknown value"
        found[qid(row["item"])][row["p"]][value] = ""

    rows = ask("""
        SELECT ?item ?p ?v WHERE {
          VALUES ?item { %s }
          { ?item rdfs:label ?v. FILTER(LANG(?v) IN (%s)) BIND(CONCAT("label_", LANG(?v)) AS ?p) }
          UNION { ?item schema:description ?v. FILTER(LANG(?v) = "en") BIND("desc" AS ?p) }
          UNION { ?item wikibase:sitelinks ?v. BIND("sitelinks" AS ?p) }
          UNION { ?page schema:about ?item; schema:isPartOf ?site; schema:name ?v. FILTER(?site IN (%s)) BIND(STR(?site) AS ?p) }
        }""" % (values, LABEL_LIST, SITE_LIST))
    complete &= rows is not None
    for row in rows or []:
        found[qid(row["item"])]["names"][row["p"]] = row["v"]

    sources = set()
    if incoming:
        rows = ask("""
            SELECT DISTINCT ?item ?src WHERE {
              hint:Query hint:optimizer "None".
              VALUES ?item { %s }
              VALUES ?p { %s }
              ?src ?p ?item.
              ?src wdt:P31 ?cls. FILTER(?cls IN (%s))
            }""" % (values, INCOMING_LIST, SONG_CLASS_LIST))
        complete &= rows is not None
        sources = {qid(row["src"]) for row in rows or []}
    return found, sources, complete


def songs_only(items):
    """The items that are songs by class. A forward link (based on, derivative work, inspired by)
    often ends at a film, a novel or a poem, which must not come back as a song."""
    kept = set()
    for start in range(0, len(items), BATCH):
        rows = ask("""
            SELECT DISTINCT ?item WHERE {
              VALUES ?item { %s }
              ?item wdt:P31 ?cls. FILTER(?cls IN (%s))
            }""" % (" ".join("wd:" + item for item in items[start:start + BATCH]), SONG_CLASS_LIST))
        if rows is None:
            log("  class check failed for", len(items[start:start + BATCH]), "items; they are left out")
        kept |= {qid(row["item"]) for row in rows or []}
    return kept


def performer_countries(performers):
    """Each performer's countries: citizenship (P27), country of origin (P495, for bands) and
    the country of the place a band was formed (P740)."""
    countries = defaultdict(list)
    failed = 0
    batches = [performers[start:start + BATCH] for start in range(0, len(performers), BATCH)]

    def one(batch):
        return ask("""
            SELECT ?a ?c WHERE {
              VALUES ?a { %s }
              { ?a wdt:P27 ?c } UNION { ?a wdt:P495 ?c } UNION { ?a wdt:P740 ?place. ?place wdt:P17 ?c }
            }""" % " ".join("wd:" + person for person in batch))

    with ThreadPoolExecutor(max_workers=3) as pool:
        for rows in pool.map(one, batches):
            failed += rows is None
            for row in rows or []:
                if row["c"].startswith(ENTITY) and qid(row["c"]) not in countries[qid(row["a"])]:
                    countries[qid(row["a"])].append(qid(row["c"]))
    log("performers", len(performers), "in", len(batches), "queries;", failed, "failed")
    return countries


def year_of(dates):
    years = [int(match.group(1)) for date in dates if (match := re.match(r"(-?\d+)-", date))]
    years = [year for year in years if year > 0]
    return min(years) if years else None


def record(found, countries):
    """One song in the shared song_details schema."""
    names = found["names"]
    labels = {lang: names.get("label_" + lang, "") for lang in LABELS}
    labels["en"] = labels["en"] or names.get("label_mul", "")
    performers = [[person, label] for person, label in found["performers"].items()]
    from_performers = []
    for person, _ in performers:
        from_performers += [country for country in countries.get(person, []) if country not in from_performers]
    relations = [[prop, target] for prop in RELATIONS for target in found[prop]]
    if found["P31"]:
        relations.append(["P31", COVER_VERSION])
    sitelinks = names.get("sitelinks", "0")
    return {
        "labels": labels,
        "description": names.get("desc", ""),
        "performers": performers,
        "composers": [[person, label] for person, label in found["composers"].items()],
        "lyricists": [[person, label] for person, label in found["lyricists"].items()],
        "producers": [[person, label] for person, label in found["producers"].items()],
        "year": year_of(found["date"]),
        # A genre or award with no English name is left out rather than shown as a bare id.
        "genres": [label for label in found["genres"].values() if label],
        "languages": list(found["languages"]),
        "countries": list(found["countries"]),
        "albums": [[album, label] for album, label in found["albums"].items()],
        "films": list(found["films"]),
        "awards": [label for label in found["awards"].values() if label],
        "nominations": [label for label in found["nominations"].values() if label],
        "mb_work": list(found["mb_work"]),
        "mb_recording": list(found["mb_recording"]),
        "whosampled": next(iter(found["whosampled"]), None),
        "relations": relations,
        "performer_countries": from_performers,
        "sitelinks": int(sitelinks) if sitelinks.isdigit() else 0,
        "wikis": {SITES[site]: title for site, title in names.items() if site in SITES},
    }


def sample(catalog, ids, limit):
    """For a dry run: the best-linked songs of each culture in turn, so every kind is tried."""
    groups = defaultdict(list)
    for item in ids:
        groups[catalog[item]["cultures"][0] if catalog[item]["cultures"] else ""].append(item)
    queues = [groups[culture] for culture in sorted(groups, key=lambda c: ("us", "in", "es", "fr").index(c) if c in ("us", "in", "es", "fr") else 9)]
    picked = []
    while len(picked) < limit and any(queues):
        for queue in queues:
            if queue and len(picked) < limit:
                picked.append(queue.pop(0))
    return picked


def run(ids, incoming, label):
    """All batches of a pass, three at a time. Returns found, sources linking in, failures."""
    batches = [ids[start:start + BATCH] for start in range(0, len(ids), BATCH)]
    found, sources, failed = {}, set(), 0
    # Three at a time: the query service allows five in parallel per client.
    with ThreadPoolExecutor(max_workers=3) as pool:
        for number, (batch_found, batch_sources, complete) in enumerate(pool.map(lambda batch: one_batch(batch, incoming), batches)):
            found.update(batch_found)
            sources |= batch_sources
            failed += 0 if complete else 1
            if number % 20 == 0:
                log(label, number * BATCH, "/", len(ids))
    log(label, "done:", len(ids), "items,", len(batches), "batches,", failed, "incomplete")
    return found, sources, failed


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--limit", type=int, default=0, help="dry run: only N catalogued songs, the best-linked of each culture in turn")
    parser.add_argument("--no-endpoints", action="store_true", help="skip pass 2 (songs at the far end of a link)")
    parser.add_argument("--catalog", default=str(SONGS / "song_catalog.json"))
    parser.add_argument("--out", default=str(SONGS / "song_details.json"))
    args = parser.parse_args()

    catalog = json.loads(Path(args.catalog).read_text())
    # Best-linked first, then by id, so the batches (and so the cache keys) are the same every run.
    # Soundtrack albums stay in the catalogue for fetch_soundtracks, but are not songs.
    ids = sorted((item for item in catalog if re.fullmatch(r"Q\d+", item) and catalog[item].get("cls") not in ALBUM_CLASSES),
                 key=lambda item: (-catalog[item]["links"], int(item[1:])))
    if args.limit:
        ids = sample(catalog, ids, args.limit)

    found, sources, failed = run(ids, True, "songs")
    if not args.no_endpoints:
        # Songs that link in were already filtered by class; the ends of forward links are not.
        targets = sorted((item for item in {target for info in found.values() for prop in INCOMING for target in info[prop]}
                          - set(found) - sources if re.fullmatch(r"Q\d+", item)), key=lambda item: int(item[1:]))
        songs = songs_only(targets)
        log("forward link ends not catalogued:", len(targets), "of which songs:", len(songs))
        far = sorted((item for item in (songs | sources) - set(found) if re.fullmatch(r"Q\d+", item)), key=lambda item: int(item[1:]))
        log("songs at the far end of a link, not catalogued:", len(far), "(", len(sources), "link in )")
        more, _, more_failed = run(far, False, "linked")
        found.update(more)
        failed += more_failed

    performers = sorted({person for info in found.values() for person in info["performers"] if re.fullmatch(r"Q\d+", person)},
                        key=lambda item: int(item[1:]))
    countries = performer_countries(performers)

    details = {item: record(info, countries) for item, info in found.items()}
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(details, ensure_ascii=False))
    linked = sum(1 for info in details.values() if any(prop != "P2550" for prop, _ in info["relations"]))
    log("done", len(details), "songs;", linked, "with a song link;", failed, "batches incomplete;",
        "partial (--limit)" if args.limit else "")


if __name__ == "__main__":
    main()
