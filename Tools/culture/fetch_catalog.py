#!/usr/bin/env python3
"""Step 1: the catalogue. Every work worth knowing, from Wikidata (CC0).

Films, television, channels, sport and literature for four cultures: the United States,
India, and the Spanish- and French-speaking worlds. Writes ../data/culture/catalog.json.
"""
import json
from collections import defaultdict

from common import DATA, log, qid, sparql

# Culture -> how to recognise its films, and how prominent a film has to be (in Wikipedia
# language editions) to count as one of its "top" films. Smaller industries get a lower bar.
FILM_CULTURES = {
    "us": ("?item wdt:P495 wd:Q30.", 14),
    "in": ("{ ?item wdt:P495 wd:Q668 } UNION { VALUES ?l { wd:Q1568 wd:Q5137 wd:Q1617 } ?item wdt:P364 ?l }", 3),
    "es": ("?item wdt:P364 wd:Q1321.", 6),
    "fr": ("?item wdt:P364 wd:Q150.", 8),
}
FILM_CLASSES = "wd:Q11424 wd:Q24869 wd:Q226730 wd:Q93204 wd:Q202866 wd:Q29168811 wd:Q506240"
DECADES = [(1880, 1919), (1920, 1929), (1930, 1939), (1940, 1949), (1950, 1959), (1960, 1969), (1970, 1979),
           (1980, 1989), (1990, 1994), (1995, 1999), (2000, 2004), (2005, 2009), (2010, 2014), (2015, 2019), (2020, 2030)]

TV_COUNTRIES = {
    "us": (["Q30"], 9),
    "in": (["Q668"], 2),
    "es": (["Q29", "Q96", "Q414", "Q739", "Q298", "Q419", "Q717", "Q241", "Q1183", "Q77"], 4),
    "fr": (["Q142", "Q31", "Q39"], 5),
}
TV_CLASSES = ("wd:Q5398426 wd:Q15416 wd:Q1259759 wd:Q581714 wd:Q1358344 wd:Q622812 wd:Q846662 wd:Q182415 "
              "wd:Q23745 wd:Q7724161 wd:Q1366112 wd:Q117467246 wd:Q2431196 wd:Q1407245 wd:Q21188110")
CHANNEL_CLASSES = "wd:Q2001305 wd:Q1254874 wd:Q1616075 wd:Q15265344 wd:Q10689397"
CHANNEL_BAR = {"us": 14, "in": 4, "es": 8, "fr": 8}

LIT_CLASSES = ("wd:Q7725634 wd:Q8261 wd:Q5185279 wd:Q49084 wd:Q25379 wd:Q12106333 wd:Q37484 wd:Q571 wd:Q47461344 "
               "wd:Q1279564 wd:Q149537 wd:Q17991521 wd:Q116476516 wd:Q24723 wd:Q1318295 wd:Q2831984 wd:Q386724")
INDIAN_LANGUAGES = "wd:Q1568 wd:Q5137 wd:Q1617 wd:Q9610 wd:Q11059 wd:Q1571 wd:Q5885 wd:Q8097 wd:Q58635 wd:Q33673 wd:Q36236 wd:Q29919"
LIT_CULTURES = {
    # American authors, plus anything in English famous enough to be one of "the greats".
    "us": ("{ ?item wdt:P50 ?a. ?a wdt:P27 wd:Q30. } UNION { ?item wdt:P407 wd:Q1860. ?item wikibase:sitelinks ?n. FILTER(?n >= 30) }", 8),
    "in": ("{ VALUES ?l { %s } ?item wdt:P407 ?l } UNION { ?item wdt:P50 ?a. VALUES ?c { wd:Q668 wd:Q129286 } ?a wdt:P27 ?c. }" % INDIAN_LANGUAGES, 1),
    "es": ("?item wdt:P407 wd:Q1321.", 4),
    "fr": ("?item wdt:P407 wd:Q150.", 5),
}

# Recurring sporting occasions, each edition of which is an event people remember by its year.
SPORT_SERIES = {
    "us": ["Super Bowl", "World Series", "NBA Finals", "Stanley Cup Finals", "WrestleMania", "Royal Rumble", "SummerSlam",
           "Indianapolis 500", "Daytona 500", "Kentucky Derby", "Masters Tournament", "US Open (tennis)", "Rose Bowl Game",
           "NCAA Division I men's basketball tournament", "Boston Marathon", "Summer Olympic Games", "Winter Olympic Games"],
    "in": ["Cricket World Cup", "ICC Men's T20 World Cup", "Indian Premier League", "Asian Games", "Commonwealth Games",
           "Pro Kabaddi League", "Men's FIH Hockey World Cup", "Asia Cup", "Ranji Trophy", "ICC Champions Trophy",
           "Indian Super League", "Indian Grand Prix"],
    "es": ["FIFA World Cup", "La Liga", "Copa América", "Copa Libertadores", "Vuelta a España", "Spanish Grand Prix",
           "Copa del Rey", "Liga MX", "Triplemanía", "Mexican Grand Prix", "Pan American Games"],
    "fr": ["Tour de France", "French Open", "24 Hours of Le Mans", "Monaco Grand Prix", "Ligue 1", "Paris–Roubaix",
           "French Grand Prix", "Coupe de France", "Dakar Rally", "UEFA European Championship"],
}


def base_rows(pattern, bar, date_props, years=None, extra=""):
    """Items matching a pattern with at least `bar` sitelinks, with the earliest year on record."""
    dates = " UNION ".join("{ ?item wdt:%s ?date }" % prop for prop in date_props)
    window = "FILTER(YEAR(?date) >= %d && YEAR(?date) <= %d)" % years if years else ""
    date_clause = ("%s %s" % (dates, window)) if years else ("OPTIONAL { %s }" % dates)
    return sparql("""
        SELECT ?item ?links (MIN(YEAR(?date)) AS ?year) WHERE {
          %s
          ?item wikibase:sitelinks ?links. FILTER(?links >= %d)
          %s
          %s
        } GROUP BY ?item ?links""" % (pattern, bar, extra, date_clause))


def chunked(pattern, bar, date_props, spans):
    """Run a dated query decade by decade, halving any span the server times out on."""
    rows = []
    queue = list(spans)
    while queue:
        low, high = queue.pop(0)
        result = base_rows(pattern, bar, date_props, (low, high))
        if result is None:
            if low == high:
                log("   gave up on", low)
                continue
            mid = (low + high) // 2
            queue[:0] = [(low, mid), (mid + 1, high)]
            continue
        rows += result
    return rows


def add(works, rows, kind, culture):
    for row in rows:
        item = qid(row["item"])
        work = works.setdefault(item, {"id": item, "kind": kind, "cultures": [], "links": int(row["links"])})
        if culture not in work["cultures"]:
            work["cultures"].append(culture)
        if row.get("year") and "year" not in work:
            work["year"] = int(row["year"])


def search_series(name):
    rows = sparql("""
        SELECT ?item ?links WHERE {
          SERVICE wikibase:mwapi {
            bd:serviceParam wikibase:endpoint "www.wikidata.org"; wikibase:api "EntitySearch";
                            mwapi:search "%s"; mwapi:language "en".
            ?item wikibase:apiOutputItem mwapi:item.
          }
          ?item wikibase:sitelinks ?links.
        } ORDER BY DESC(?links) LIMIT 1""" % name.replace('"', ""))
    return qid(rows[0]["item"]) if rows else None


def main():
    works = {}

    # One query per class: asking for a single class with an optional date is answered from
    # the index in seconds, where a list of classes or a year window forces a scan.
    for culture, (pattern, bar) in FILM_CULTURES.items():
        total = 0
        for cls in FILM_CLASSES.split():
            rows = base_rows("?item wdt:P31 %s. %s" % (cls, pattern), bar, ["P577"]) or []
            add(works, rows, "film", culture)
            total += len(rows)
        log("films", culture, total)

    for culture, (countries, bar) in TV_COUNTRIES.items():
        values = " ".join("wd:" + c for c in countries)
        total = 0
        for cls in TV_CLASSES.split():
            rows = base_rows("?item wdt:P31 %s. VALUES ?c { %s } ?item wdt:P495 ?c." % (cls, values), bar, ["P580", "P577"]) or []
            add(works, rows, "tv", culture)
            total += len(rows)
        log("tv", culture, total)
        total = 0
        for cls in CHANNEL_CLASSES.split():
            rows = base_rows("?item wdt:P31 %s. VALUES ?c { %s } ?item wdt:P17 ?c." % (cls, values), CHANNEL_BAR[culture], ["P571"]) or []
            add(works, rows, "channel", culture)
            total += len(rows)
        log("channels", culture, total)

    for culture, names in SPORT_SERIES.items():
        total = 0
        for name in names:
            series = search_series(name)
            if not series:
                log("   no entity for", name)
                continue
            add(works, [{"item": series, "links": "99"}], "sport", culture)
            works[series]["series_name"] = name
            rows = base_rows("{ ?item wdt:P31 wd:%s } UNION { ?item wdt:P3450 wd:%s } UNION { ?item wdt:P179 wd:%s }" % (series, series, series),
                             4, ["P585", "P580", "P577"]) or []
            for row in rows:
                add(works, [row], "sport", culture)
                works[qid(row["item"])]["series"] = series
            total += len(rows)
        log("sport", culture, total)

    for culture, (pattern, bar) in LIT_CULTURES.items():
        total = 0
        for cls in LIT_CLASSES.split():
            rows = base_rows("?item wdt:P31 %s. %s" % (cls, pattern), bar, ["P577", "P571"]) or []
            add(works, rows, "book", culture)
            total += len(rows)
        log("literature", culture, total)

    (DATA / "catalog_base.json").write_text(json.dumps(list(works.values()), ensure_ascii=False))
    kinds = defaultdict(int)
    for work in works.values():
        kinds[(work["kind"], work["cultures"][0])] += 1
    log("total", len(works), dict(kinds))


if __name__ == "__main__":
    main()
