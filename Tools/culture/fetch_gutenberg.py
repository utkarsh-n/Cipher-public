#!/usr/bin/env python3
"""Step 4b: public-domain books in English, French and Spanish, from Project Gutenberg.

Takes the catalogued books that Wikidata links to a Gutenberg ebook, most prominent first,
and downloads their plain text from a Gutenberg mirror (the main site is for people, not
programs). Writes texts/gutenberg/<id>.txt and texts/gutenberg.json.
"""
import json

from common import DATA, fetch, log

MIRROR = "https://gutenberg.pglaf.org"
LANGUAGES = {"Q1860": "en", "Q150": "fr", "Q1321": "es"}
QUOTA = {"en": 450, "fr": 170, "es": 130}
FOLDER = DATA / "texts" / "gutenberg"
FOLDER.mkdir(parents=True, exist_ok=True)


def download(ebook):
    digits = str(ebook)
    folder = "/".join(digits[:-1]) if len(digits) > 1 else "0"
    for name in (f"{digits}-0.txt", f"{digits}.txt", f"{digits}-8.txt"):
        body = fetch(f"{MIRROR}/{folder}/{digits}/{name}", pause=0.8, tries=2)
        if body and len(body) > 5000:
            return body.decode("utf-8", errors="replace") if name != f"{digits}-8.txt" else body.decode("latin-1")
    return None


def main():
    base = {work["id"]: work for work in json.loads((DATA / "catalog_base.json").read_text())}
    details = json.loads((DATA / "catalog_details.json").read_text())
    candidates = []
    for item, detail in details.items():
        work = base.get(item)
        ebook = next((e["label"] for e in detail.get("gutenberg", []) if e["label"].isdigit()), None)
        language = next((LANGUAGES[e["id"]] for e in detail.get("worklang", []) if e["id"] in LANGUAGES), None)
        if not work or not ebook or not language or not isinstance(detail.get("label_en"), str):
            continue
        year = work.get("year")
        if year and year > 1928:
            continue  # only what is out of copyright in the United States
        candidates.append({"id": int(ebook), "q": item, "language": language, "title": detail["label_en"], "year": year, "links": work["links"],
                           "author": next((e["label"] for e in detail.get("author", []) if e.get("label")), "")})
    candidates.sort(key=lambda book: -book["links"])
    taken = {language: 0 for language in QUOTA}
    saved = []
    for book in candidates:
        if taken[book["language"]] >= QUOTA[book["language"]]:
            continue
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
    (DATA / "texts" / "gutenberg.json").write_text(json.dumps(saved, ensure_ascii=False))
    log("gutenberg done", taken, "of", len(candidates), "candidates")


if __name__ == "__main__":
    main()
