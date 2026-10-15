#!/usr/bin/env python3
"""Step 4c: more public-domain books, found through Gutenberg's own catalogue.

Wikidata links few Spanish-language works to their Gutenberg ebooks, so step 4b came back
with a handful. This matches the catalogued books that lack a link against Gutenberg's
catalogue (pg_catalog.csv on the mirror) by title and author, then tops up the Spanish quota
with Gutenberg's Spanish literature (Library of Congress class PQ), dated roughly from the
author's lifetime. Downloads as in step 4b; extends texts/gutenberg.json.
"""
import csv
import json
import re
import unicodedata

from common import DATA, fetch, log
from fetch_gutenberg import FOLDER, LANGUAGES, MIRROR, QUOTA, download

CATALOG = DATA / "pg_catalog.csv"
ARTICLES = re.compile(r"^(the|a|an|el|la|los|las|un|una|le|les|l'|une|des) ")


def plain(text):
    """Lowercase ASCII letters and spaces: enough to compare titles across spellings."""
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    text = re.sub(r"[^a-z0-9 ]+", " ", text)
    return ARTICLES.sub("", re.sub(r"\s+", " ", text).strip())


def lifetime_year(authors):
    """A rough year for an undated text: forty years after the author's birth."""
    match = re.search(r"(\d{4})\??-", authors)
    return int(match.group(1)) + 40 if match else None


def main():
    if not CATALOG.exists():
        body = fetch(f"{MIRROR}/cache/epub/feeds/pg_catalog.csv", pause=1.0)
        if not body:
            log("no catalogue")
            return
        CATALOG.write_bytes(body)
    rows = [row for row in csv.DictReader(open(CATALOG, encoding="utf-8")) if row["Type"] == "Text" and row["Language"] in ("en", "fr", "es")]
    by_title = {}
    for row in rows:
        for title in row["Title"].split("\n")[:1]:
            by_title.setdefault((row["Language"], plain(title)), []).append(row)
    log("catalogue texts:", len(rows))

    listing = DATA / "texts" / "gutenberg.json"
    saved = json.loads(listing.read_text()) if listing.exists() else []
    have = {book["id"] for book in saved}
    taken = {language: sum(1 for book in saved if book["language"] == language) for language in QUOTA}

    base = {work["id"]: work for work in json.loads((DATA / "catalog_base.json").read_text())}
    details = json.loads((DATA / "catalog_details.json").read_text())
    candidates = []
    for item, detail in details.items():
        work = base.get(item)
        if not work or work["kind"] != "book" or any(e["label"].isdigit() for e in detail.get("gutenberg", [])):
            continue
        language = next((LANGUAGES[e["id"]] for e in detail.get("worklang", []) if e["id"] in LANGUAGES), None)
        if not language:
            continue
        year = work.get("year")
        if year and year > 1928:
            continue
        author = next((e["label"] for e in detail.get("author", []) if e.get("label") and not e["label"].startswith("http")), "")
        surname = plain(author).split()[-1] if author else ""
        titles = [detail.get(key) for key in ("label_en", "label_es", "label_fr") if isinstance(detail.get(key), str)]
        for title in titles:
            for row in by_title.get((language, plain(title)), []):
                if surname and surname not in plain(row["Authors"]):
                    continue
                if not year and (lifetime_year(row["Authors"]) or 2000) > 1890:
                    continue
                candidates.append({"id": int(row["Text#"]), "q": item, "language": language, "title": titles[0], "year": year or lifetime_year(row["Authors"]),
                                   "links": work["links"], "author": author})
                break
            else:
                continue
            break
    log("catalogued books matched by title and author:", len(candidates))

    # Spanish literature Gutenberg holds that the catalogue never named.
    extra = []
    for row in rows:
        if row["Language"] == "es" and "PQ" in row["LoCC"] and "Authors" and row["Authors"] and "Anonymous" not in row["Authors"]:
            year = lifetime_year(row["Authors"])
            if year and year <= 1900:
                author = re.sub(r",\s*\d{4}.*$", "", row["Authors"].split(";")[0]).strip()
                if "," in author:
                    last, first = author.split(",", 1)
                    author = f"{first.strip()} {last.strip()}"
                extra.append({"id": int(row["Text#"]), "q": "", "language": "es", "title": row["Title"].split("\n")[0], "year": year, "links": 3, "author": author})
    log("Spanish literature in the catalogue:", len(extra))

    seen = set()
    for book in sorted(candidates, key=lambda b: -b["links"]) + extra:
        if book["id"] in have or book["id"] in seen or taken[book["language"]] >= QUOTA[book["language"]]:
            continue
        seen.add(book["id"])
        path = FOLDER / f"{book['id']}.txt"
        if not path.exists():
            text = download(book["id"])
            if not text:
                continue
            path.write_text(text, encoding="utf-8")
        taken[book["language"]] += 1
        saved.append(book)
        if len(saved) % 50 == 0:
            log("gutenberg", len(saved), taken)
            listing.write_text(json.dumps(saved, ensure_ascii=False))
    listing.write_text(json.dumps(saved, ensure_ascii=False))
    log("gutenberg done", taken)


if __name__ == "__main__":
    main()
