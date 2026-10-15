#!/usr/bin/env python3
"""Step 2c: labels Wikidata keeps only as "mul" (the same in every language).

Since 2024 an item whose name is the same everywhere may carry a "mul" label and no English
one, so "Toy Story" and "James Cameron" come back nameless from a query for English labels.
Fills those gaps in catalog_details.json, for works and for everything they point at.
"""
import json
import re

from common import DATA, log, qid, sparql

BATCH = 300


def labels_for(ids):
    found = {}
    for start in range(0, len(ids), BATCH):
        values = " ".join("wd:" + item for item in ids[start:start + BATCH])
        rows = sparql('SELECT ?item ?v (LANG(?v) AS ?l) WHERE { VALUES ?item { %s } ?item rdfs:label ?v. FILTER(LANG(?v) IN ("en", "mul")) }' % values) or []
        for row in rows:
            item = qid(row["item"])
            if row["l"] == "en" or item not in found:
                found[item] = row["v"]
    return found


def main():
    details = json.loads((DATA / "catalog_details.json").read_text())
    nameless_works = [item for item, info in details.items() if "label_en" not in info]
    nameless_values = sorted({entry["id"] for info in details.values() for key, value in info.items()
                              if isinstance(value, list) for entry in value if entry.get("id") and not entry.get("label")})
    log("works without an English label:", len(nameless_works), " linked items without one:", len(nameless_values))
    names = labels_for(nameless_works + nameless_values)
    filled = 0
    for item in nameless_works:
        if item in names:
            details[item]["label_en"] = names[item]
            filled += 1
    for info in details.values():
        for value in info.values():
            if isinstance(value, list):
                for entry in value:
                    if entry.get("id") and not entry.get("label") and entry["id"] in names:
                        entry["label"] = names[entry["id"]]
                        filled += 1
    (DATA / "catalog_details.json").write_text(json.dumps(details, ensure_ascii=False))
    log("filled", filled, "labels")


if __name__ == "__main__":
    main()
