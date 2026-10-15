#!/usr/bin/env python3
"""Songs step 1: the song catalogue, from Wikidata (CC0).

Four passes, one class and one wiki per query, with the planner switched off so each query
walks the class first and reads sitelinks and pages item by item:
  en  singles, songs and song-form compositions with an English Wikipedia article and enough
      sitelinks; the floor is tuned so this pass stays near --en-target items;
  es  songs in Spanish (P407), then any with a Spanish Wikipedia article and 2+ sitelinks;
  fr  the same for French, with "music track with vocals" as a fourth class;
  in  every work "created for" (P9899) an Indian-language film, and each film's soundtrack (P406);
      a soundtrack not typed as a song gets cls Q482994 (album) and is never a song row.
The culture a pass gives is only a candidate: build_culture settles it from the language,
the list a song came from and the performers' countries. No lyrics are read or kept.
Writes songs/song_catalog.json, and songs/song_films.json (language, year and title of the
films the Indian songs belong to).
"""
import argparse
import json
from collections import defaultdict
from pathlib import Path

from common import DATA, SPARQL, cache_path, log, qid, sparql

SONGS = DATA / "songs"

SINGLE, SONG, COMPOSITION, TRACK = "Q134556", "Q7366", "Q105543609", "Q55850593"
# A film's soundtrack release (P406) that is not itself typed as a song is catalogued as an album,
# so fetch_soundtracks can find its "(soundtrack)" article and fetch_song_details can pass it by.
ALBUM = "Q482994"
# Singles first: they are the core, and the largest class, so a dry run with --limit 1 tries
# the query most likely to time out.
CLASSES = {"en": [SINGLE, SONG, COMPOSITION], "es": [SINGLE, SONG, COMPOSITION], "fr": [SINGLE, SONG, COMPOSITION, TRACK]}
# Preferred order when an item has several classes.
CLASS_ORDER = [SONG, SINGLE, COMPOSITION, TRACK]
LANGUAGE = {"es": "Q1321", "fr": "Q150"}
SITE = {lang: f"https://{lang}.wikipedia.org/" for lang in ("en", "es", "fr", "hi")}

# Film language -> the Wikidata item for it.
FILM_LANGUAGES = {"hi": "Q1568", "ur": "Q1617", "pa": "Q58635", "ta": "Q5885", "te": "Q8097",
                  "bn": "Q9610", "mr": "Q1571", "gu": "Q5137", "ml": "Q36236", "kn": "Q33673"}

# Measured 2026-10-03: with an English article, 53,158 singles, 7,954 songs and 35,268
# song-form compositions. A floor of 4 sitelinks keeps 28,464 of them; 3 would keep 38,517.
EN_TARGET = 30000
EN_FLOOR = 4      # used when the sitelink histogram cannot be had
WIKI_FLOOR = 2    # es/fr Wikipedia pass
LANGUAGE_FLOOR = 0  # es/fr language pass: a song tagged Spanish or French is kept however obscure

# When a whole class times out, it is asked again decade by decade, plus once for undated items.
SPANS = [(0, 1899), (1900, 1939), (1940, 1959), (1960, 1969), (1970, 1979), (1980, 1989), (1990, 1999),
         (2000, 2004), (2005, 2009), (2010, 2014), (2015, 2019), (2020, 2035)]
NO_PLAN = 'hint:Query hint:optimizer "None".'


def ask(query):
    """sparql(), but a reply that was cut off mid-stream is dropped from the cache, so that
    a re-run asks again instead of failing on the same broken file forever."""
    rows = sparql(query)
    if rows is None:
        cache_path(SPARQL, {"query": query, "format": "json"})[1].unlink(missing_ok=True)
    return rows


def class_pattern(cls, strict):
    """A composition counts only in the form of a song. `strict` asks for that form outright;
    otherwise a composition with no form at all passes too (the language passes, where being
    in Spanish or French already says it is sung)."""
    pattern = "?item wdt:P31 wd:%s." % cls
    if cls == COMPOSITION:
        pattern += (" ?item wdt:P7937 wd:%s." % SONG if strict else
                    " FILTER(!EXISTS { ?item wdt:P7937 [] } || EXISTS { ?item wdt:P7937 wd:%s })" % SONG)
    return pattern


def date_clause(span):
    if span is None:
        return "OPTIONAL { ?item wdt:P577 ?date }"
    if span == "undated":
        return "FILTER NOT EXISTS { ?item wdt:P577 [] }"
    return "?item wdt:P577 ?date. FILTER(YEAR(?date) >= %d && YEAR(?date) <= %d)" % span


def histogram(cls, wiki):
    """How many items of a class with an article on `wiki` have each sitelink count."""
    rows = ask("""
        SELECT ?links (COUNT(?item) AS ?n) WHERE {
          %s
          %s
          ?page schema:about ?item; schema:isPartOf <%s>.
          ?item wikibase:sitelinks ?links.
        } GROUP BY ?links""" % (NO_PLAN, class_pattern(cls, True), SITE[wiki]))
    return None if rows is None else {int(row["links"]): int(row["n"]) for row in rows}


def tune_floor(target):
    """The lowest sitelink floor at which the English pass stays within `target` items."""
    totals = defaultdict(int)
    for cls in CLASSES["en"]:
        counts = histogram(cls, "en")
        if counts is None:
            log("  no histogram for", cls, "- using the default floor", EN_FLOOR)
            return EN_FLOOR
        log("  en", cls, sum(counts.values()), "items with an article")
        for links, n in counts.items():
            for floor in range(1, min(links, 400) + 1):
                totals[floor] += n
    totals[0] = totals[1]
    for floor in range(1, 401):
        if totals[floor] <= target:
            log("  floor", floor, "gives", totals[floor], "(floor", floor - 1, "would give", totals[floor - 1], ")")
            return floor
    return 400


def wiki_rows(cls, wiki, floor, span=None):
    """Items of a class with an article on `wiki` and at least `floor` sitelinks."""
    return ask("""
        SELECT ?item ?links ?title (MIN(YEAR(?date)) AS ?year) WHERE {
          %s
          %s
          ?item wikibase:sitelinks ?links. FILTER(?links >= %d)
          %s
          ?page schema:about ?item; schema:isPartOf <%s>; schema:name ?title.
        } GROUP BY ?item ?links ?title""" % (NO_PLAN, class_pattern(cls, True), floor, date_clause(span), SITE[wiki]))


def language_rows(cls, lang, floor, span=None):
    """Items of a class in a language, with their article titles there and in English if any."""
    return ask("""
        SELECT ?item ?links ?title ?en (MIN(YEAR(?date)) AS ?year) WHERE {
          %s
          %s
          ?item wdt:P407 wd:%s.
          ?item wikibase:sitelinks ?links. FILTER(?links >= %d)
          %s
          OPTIONAL { ?page schema:about ?item; schema:isPartOf <%s>; schema:name ?title. }
          OPTIONAL { ?enpage schema:about ?item; schema:isPartOf <%s>; schema:name ?en. }
        } GROUP BY ?item ?links ?title ?en""" % (NO_PLAN, class_pattern(cls, False), LANGUAGE[lang], floor,
                                                 date_clause(span), SITE[lang], SITE["en"]))


def film_rows(language, link):
    """Works tied to films in one Indian language: `link` is either the song's P9899
    ("created for") or the film's P406 (soundtrack release)."""
    pattern = "?item wdt:P9899 ?film." if link == "P9899" else "?film wdt:P406 ?item."
    return ask("""
        SELECT ?item ?film ?links ?en ?hi ?filmTitle (GROUP_CONCAT(DISTINCT STRAFTER(STR(?cls), "entity/")) AS ?classes)
               (MIN(YEAR(?date)) AS ?year) (MIN(YEAR(?filmDate)) AS ?filmYear) WHERE {
          %s
          ?film wdt:P364 wd:%s.
          %s
          ?item wikibase:sitelinks ?links.
          OPTIONAL { ?item wdt:P31 ?cls }
          OPTIONAL { ?item wdt:P577 ?date }
          OPTIONAL { ?film wdt:P577 ?filmDate }
          OPTIONAL { ?enpage schema:about ?item; schema:isPartOf <%s>; schema:name ?en. }
          OPTIONAL { ?hipage schema:about ?item; schema:isPartOf <%s>; schema:name ?hi. }
          OPTIONAL { ?filmpage schema:about ?film; schema:isPartOf <%s>; schema:name ?filmTitle. }
        } GROUP BY ?item ?film ?links ?en ?hi ?filmTitle""" % (NO_PLAN, FILM_LANGUAGES[language], pattern,
                                                              SITE["en"], SITE["hi"], SITE["en"]))


def by_decade(question, budget):
    """Run question(span) for the whole class; if that times out, decade by decade (halving any
    span that still times out) and once for items with no date. Returns rows and queries used."""
    rows = question(None)
    used = 1
    if rows is not None:
        return rows, used
    log("   whole class timed out; asking by decade")
    rows, queue = [], list(SPANS) + ["undated"]
    while queue and used < budget:
        span = queue.pop(0)
        result = question(span)
        used += 1
        if result is not None:
            rows += result
        elif span != "undated" and span[0] < span[1]:
            middle = (span[0] + span[1]) // 2
            queue[:0] = [(span[0], middle), (middle + 1, span[1])]
        else:
            log("   gave up on", span)
    return rows, used


def rank(cls):
    return CLASS_ORDER.index(cls) if cls in CLASS_ORDER else len(CLASS_ORDER)


def add(songs, row, cls, culture, wikis):
    """Merge one result row into the catalogue."""
    item = qid(row["item"])
    song = songs.setdefault(item, {"cls": cls, "cultures": [], "wikis": {}, "links": int(row["links"]), "year": None, "films": []})
    if rank(cls) < rank(song["cls"]):
        song["cls"] = cls
    if culture not in song["cultures"]:
        song["cultures"].append(culture)
    for wiki, key in wikis.items():
        if row.get(key):
            song["wikis"][wiki] = row[key]
    if row.get("year"):
        year = int(row["year"])
        song["year"] = year if song["year"] is None else min(song["year"], year)
    return song


def class_pass(songs, label, classes, question, culture, wikis, budget):
    """One query per class (or one per decade, if the class is too big), merged into songs."""
    used = 0
    for cls in classes:
        if used >= budget:
            break
        rows, spent = by_decade(lambda span: question(cls, span), budget - used)
        used += spent
        for row in rows:
            add(songs, row, cls, culture, wikis)
        log("", label, cls, len(rows))


def pick_class(classes):
    found = classes.split()
    for cls in CLASS_ORDER:
        if cls in found:
            return cls
    return found[0] if found else ""


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--limit", type=int, default=0, help="dry run: at most N queries in each pass (en, es language, es wiki, fr language, fr wiki, in); answers stay cached for the full run")
    parser.add_argument("--only", default="en,es,fr,in", help="passes to run, from en,es,fr,in")
    parser.add_argument("--en-floor", type=int, default=0, help="sitelink floor for the English pass (default: tuned to --en-target)")
    parser.add_argument("--en-target", type=int, default=EN_TARGET, help="items the English pass should stay within")
    parser.add_argument("--measure", action="store_true", help="only print the English sitelink histogram and the floor it gives")
    parser.add_argument("--out", default=str(SONGS / "song_catalog.json"))
    args = parser.parse_args()
    passes = args.only.split(",")
    budget = args.limit or 10 ** 6

    if args.measure:
        tune_floor(args.en_target)
        return

    songs, films = {}, {}
    if "en" in passes:
        floor = args.en_floor or tune_floor(args.en_target)
        log("en pass, sitelink floor", floor)
        class_pass(songs, "en", CLASSES["en"], lambda cls, span: wiki_rows(cls, "en", floor, span), "us", {"en": "title"}, budget)
    for lang in ("es", "fr"):
        if lang in passes:
            class_pass(songs, lang + " language", CLASSES[lang], lambda cls, span: language_rows(cls, lang, LANGUAGE_FLOOR, span),
                       lang, {lang: "title", "en": "en"}, budget)
            class_pass(songs, lang + " wiki", CLASSES[lang], lambda cls, span: wiki_rows(cls, lang, WIKI_FLOOR, span),
                       lang, {lang: "title"}, budget)

    if "in" in passes:
        jobs = [(language, link) for language in FILM_LANGUAGES for link in ("P9899", "P406")]
        for language, link in jobs[:budget]:
            rows = film_rows(language, link)
            if rows is None:
                log("   timed out:", language, link)
                continue
            for row in rows:
                cls = pick_class(row.get("classes", ""))
                if link == "P406" and cls not in CLASS_ORDER:
                    cls = ALBUM
                song = add(songs, row, cls, "in", {"en": "en", "hi": "hi"})
                film = qid(row["film"])
                if film not in song["films"]:
                    song["films"].append(film)
                films.setdefault(film, {"language": language, "year": int(row["filmYear"]) if row.get("filmYear") else None,
                                        "title": row.get("filmTitle", "")})
            log(" in", language, link, len(rows), "rows")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(songs, ensure_ascii=False))
    if films:
        (out.parent / "song_films.json").write_text(json.dumps(films, ensure_ascii=False))
    cultures = defaultdict(int)
    for song in songs.values():
        for culture in song["cultures"]:
            cultures[culture] += 1
    log("total", len(songs), "items", dict(cultures), "from", len(films), "Indian films;", "partial (--limit)" if args.limit else "")


if __name__ == "__main__":
    main()
