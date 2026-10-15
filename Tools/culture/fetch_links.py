#!/usr/bin/env python3
"""Step 2b: prominence and year for works the canon lists added.

The catalogue queries record how many Wikipedia editions write about each work; works that
came in through a list (a prize, a poll, a remake table) arrive without that count or a year.
Updates catalog_base.json in place.
"""
import json
import re

from common import DATA, log, qid, sparql

BATCH = 300


def main():
    base = json.loads((DATA / "catalog_base.json").read_text())
    missing = [work for work in base if work["links"] == 0 and re.fullmatch(r"Q\d+", work["id"])]
    by_id = {work["id"]: work for work in missing}
    for start in range(0, len(missing), BATCH):
        values = " ".join("wd:" + work["id"] for work in missing[start:start + BATCH])
        rows = sparql("""
            SELECT ?item ?links (MIN(YEAR(?date)) AS ?year) WHERE {
              VALUES ?item { %s }
              ?item wikibase:sitelinks ?links.
              OPTIONAL { { ?item wdt:P577 ?date } UNION { ?item wdt:P580 ?date } UNION { ?item wdt:P571 ?date } }
            } GROUP BY ?item ?links""" % values) or []
        for row in rows:
            work = by_id[qid(row["item"])]
            work["links"] = int(row["links"])
            if row.get("year") and "year" not in work:
                work["year"] = int(row["year"])
    (DATA / "catalog_base.json").write_text(json.dumps(base, ensure_ascii=False))
    log("filled in", sum(1 for work in missing if work["links"]), "of", len(missing))


if __name__ == "__main__":
    main()
