#!/usr/bin/env python3
"""Step 2: what Wikidata knows about each catalogued work.

Titles in the writer's languages, a one-line description, genres, subjects, makers, awards,
and the links that make two works relatives (based on, inspired by, derivative work).
Reads catalog_base.json, writes catalog_details.json.
"""
import json
import re
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

from common import DATA, log, qid, sparql

PROPERTIES = {
    "genre": "P136", "subject": "P921", "country": "P495", "language": "P364", "worklang": "P407",
    "director": "P57", "author": "P50", "creator": "P170", "source": "P144", "inspired": "P941",
    "derivative": "P4969", "award": "P166", "winner": "P1346", "place": "P840", "period": "P2408",
    "movement": "P135", "gutenberg": "P2034", "series": "P179", "composer": "P86", "type": "P31",
    "network": "P449",
}
SITES = {
    "https://en.wikipedia.org/": "enwiki", "https://hi.wikipedia.org/": "hiwiki", "https://gu.wikipedia.org/": "guwiki",
    "https://es.wikipedia.org/": "eswiki", "https://fr.wikipedia.org/": "frwiki",
    "https://en.wikisource.org/": "enws", "https://hi.wikisource.org/": "hiws", "https://gu.wikisource.org/": "guws",
    "https://es.wikisource.org/": "esws", "https://fr.wikisource.org/": "frws",
}
BATCH = 250
UNIONS = " UNION ".join('{ ?item wdt:%s ?v. BIND("%s" AS ?p) }' % (prop, name) for name, prop in PROPERTIES.items())
SITE_LIST = ", ".join("<%s>" % site for site in SITES)


def one_batch(batch):
    """Four small queries rather than one large one: joined, the planner times out."""
    values = " ".join("wd:" + item for item in batch)
    found = {item: defaultdict(list) for item in batch}
    rows = sparql("""
        SELECT ?item ?p ?v ?vl WHERE {
          VALUES ?item { %s }
          %s
          OPTIONAL { ?v rdfs:label ?vl FILTER(LANG(?vl) IN ("en", "mul")) }
        }""" % (values, UNIONS))
    complete = rows is not None
    for row in rows or []:
        value = row["v"]
        entry = {"id": qid(value), "label": row.get("vl", "")} if value.startswith("http://www.wikidata.org/entity/") else {"id": "", "label": value}
        bucket = found[qid(row["item"])][row["p"]]
        # An item can come back twice, with an English and a "mul" label; one entry is enough.
        if entry["id"] and any(other["id"] == entry["id"] for other in bucket):
            continue
        bucket.append(entry)
    rows = sparql("""SELECT ?item ?p ?v WHERE { VALUES ?item { %s } ?item rdfs:label ?v.
        FILTER(LANG(?v) IN ("en", "hi", "gu", "es", "fr", "mul")) BIND(CONCAT("label_", LANG(?v)) AS ?p) }""" % values)
    complete = complete and rows is not None
    for row in rows or []:
        found[qid(row["item"])][row["p"]] = row["v"]
    for item in batch:  # a name that is the same in every language stands in for the English one
        if "label_en" not in found[item] and "label_mul" in found[item]:
            found[item]["label_en"] = found[item]["label_mul"]
    rows = sparql("""SELECT ?item ?v WHERE { VALUES ?item { %s } ?item schema:description ?v. FILTER(LANG(?v) = "en") }""" % values)
    for row in rows or []:
        found[qid(row["item"])]["desc"] = row["v"]
    rows = sparql("""SELECT ?item ?site ?v WHERE { VALUES ?item { %s } ?page schema:about ?item; schema:isPartOf ?site; schema:name ?v.
        FILTER(?site IN (%s)) }""" % (values, SITE_LIST))
    complete = complete and rows is not None
    for row in rows or []:
        found[qid(row["item"])][SITES[row["site"]]] = row["v"]
    return found, complete


def main():
    base = json.loads((DATA / "catalog_base.json").read_text())
    ids = [work["id"] for work in base if re.fullmatch(r"Q\d+", work["id"])]
    batches = [ids[start:start + BATCH] for start in range(0, len(ids), BATCH)]
    details = {}
    failed = 0
    # Three at a time: the query service allows five in parallel per client.
    with ThreadPoolExecutor(max_workers=3) as pool:
        for number, (found, complete) in enumerate(pool.map(one_batch, batches)):
            details.update(found)
            failed += 0 if complete else 1
            if number % 20 == 0:
                log("details", number * BATCH, "/", len(ids))
    (DATA / "catalog_details.json").write_text(json.dumps(details, ensure_ascii=False))
    log("done", len(details), "works;", failed, "batches incomplete")


if __name__ == "__main__":
    main()
