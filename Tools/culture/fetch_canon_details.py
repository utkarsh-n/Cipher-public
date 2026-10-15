#!/usr/bin/env python3
"""Wikidata details for songs that a chart or award list names but the song catalogue missed.

    python3 fetch_canon_details.py     after fetch_song_lists.py and fetch_song_details.py

fetch_song_details.py reads only song_catalog.json, so a number one whose item has too few
sitelinks for the catalogue (or a class it does not ask for) would reach the build with no
performer, year or links. This gathers those ids from song_canon.json, runs the same details
crawl on just them, and merges the result into song_details.json.
"""
import json
import subprocess
import sys
from pathlib import Path

from common import DATA, log

SONGS = DATA / "songs"


def main():
    canon = json.loads((SONGS / "song_canon.json").read_text())
    details = json.loads((SONGS / "song_details.json").read_text())
    catalog = json.loads((SONGS / "song_catalog.json").read_text())
    missing = {}
    for row in canon:
        q = row.get("qid")
        if q and q not in details and q not in catalog and q not in missing:
            missing[q] = {"cls": "", "cultures": [row.get("culture")] if row.get("culture") else [], "wikis": {}, "links": 0,
                          "year": row.get("year"), "films": []}
    log(f"canon songs without details: {len(missing)}")
    if not missing:
        return
    extra_catalog = SONGS / "canon_catalog.json"
    extra_out = SONGS / "canon_details.json"
    extra_catalog.write_text(json.dumps(missing, ensure_ascii=False))
    subprocess.run([sys.executable, "fetch_song_details.py", "--catalog", str(extra_catalog), "--out", str(extra_out), "--no-endpoints"],
                   check=True, cwd=Path(__file__).parent)
    found = json.loads(extra_out.read_text())
    added = 0
    for q, detail in found.items():
        if q not in details:
            details[q] = detail
            added += 1
    (SONGS / "song_details.json").write_text(json.dumps(details, ensure_ascii=False))
    log(f"merged {added} canon songs into song_details.json ({len(details)} in all)")


if __name__ == "__main__":
    main()
