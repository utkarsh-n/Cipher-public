#!/usr/bin/env python3
"""Step 4a: public-domain writing in Hindi and Gujarati, from Wikisource.

Both sites keep each book as scanned pages that volunteers proofread one at a time. An index
page per book carries its title, author and year; the pages carry the text and a quality
mark. This walks every book index, then collects the pages of each book that have actually
been proofread (raw OCR is too garbled to quote).

Writes texts/wikisource-hi.jsonl and texts/wikisource-gu.jsonl, one book per line:
{"index", "title", "author", "year", "pages": [text, ...]}. Restartable: finished books are skipped.
"""
import json
import re
import sys

from common import DATA, log, wiki_api

TEXTS = DATA / "texts"
TEXTS.mkdir(exist_ok=True)
SITES = {"hi": ("hi.wikisource.org", 250, 252), "gu": ("gu.wikisource.org", 104, 106)}  # (host, page namespace, index namespace)
PAGES_PER_BOOK = 100
MAX_BOOKS = 450
DIGITS = str.maketrans("०१२३४५६७८९૦૧૨૩૪૫૬૭૮૯", "01234567890123456789")


def field(text, *names):
    """A value from a book's index form. Gujarati Wikisource names its fields in Gujarati."""
    for name in names:
        match = re.search(r"\|\s*%s\s*=\s*([^\n|]*)" % name, text)
        value = match.group(1).strip() if match else ""
        if value:
            return re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", value)
    return ""


def indexes(host, namespace):
    books = []
    params = {"action": "query", "generator": "allpages", "gapnamespace": str(namespace), "gaplimit": "50",
              "prop": "revisions", "rvprop": "content", "rvslots": "main"}
    while True:
        data = wiki_api(host, params)
        for page in data.get("query", {}).get("pages", []):
            try:
                text = page["revisions"][0]["slots"]["main"]["content"]
            except (KeyError, IndexError):
                continue
            kind = field(text, "Type", "પ્રકાર").lower()
            year = re.search(r"\d{4}", field(text, "Year", "વર્ષ").translate(DIGITS))
            author = field(text, "Author", "સર્જક")
            # Books only: both sites also hold court judgments, gazettes, syllabuses and journals.
            if kind not in ("", "book", "collection", "poem", "પુસ્તક") or "न्यायालय" in author or "Court" in author or "विश्वविद्यालय" in author:
                continue
            if author in ("અજ્ઞાત", "अज्ञात"):
                author = ""
            books.append({"index": page["title"].split(":", 1)[1], "title": field(text, "Title", "શીર્ષક"), "author": author,
                          "year": int(year.group()) if year else None})
        if "continue" not in data:
            break
        params = {**params, **data["continue"]}
    return books


def strip_markup(text):
    quality = re.search(r'<pagequality level="(\d)"', text)
    text = re.sub(r"<noinclude>.*?</noinclude>", "", text, flags=re.S)
    text = re.sub(r"<ref[^>]*>.*?</ref>|<ref[^>]*/>", "", text, flags=re.S)
    for _ in range(3):  # templates nest a couple of levels deep
        text = re.sub(r"\{\{[^{}]*\}\}", " ", text)
    text = re.sub(r"\{\|.*?\|\}", " ", text, flags=re.S)
    text = re.sub(r"\[\[(?:File|चित्र|ચિત્ર|Image)[^\]]*\]\]", " ", text)
    text = re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", text)
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"'{2,}", "", text)
    return int(quality.group(1)) if quality else 0, text.strip()


def book_pages(host, namespace, index):
    pages = []
    params = {"action": "query", "generator": "allpages", "gapnamespace": str(namespace), "gapprefix": index + "/", "gaplimit": "50",
              "prop": "revisions", "rvprop": "content", "rvslots": "main"}
    fetched = 0
    while fetched < PAGES_PER_BOOK:
        data = wiki_api(host, params)
        if not data:
            return None  # the request failed; try this book again next run
        batch = data.get("query", {}).get("pages", [])
        fetched += len(batch)
        for page in batch:
            try:
                quality, text = strip_markup(page["revisions"][0]["slots"]["main"]["content"])
            except (KeyError, IndexError):
                continue
            number = re.search(r"/([^/]+)$", page["title"])
            if quality >= 3 and len(text) > 150:
                pages.append((int(number.group(1).translate(DIGITS)) if number and number.group(1).translate(DIGITS).isdigit() else 0, text))
        if "continue" not in data or not batch:
            break
        params = {**params, **data["continue"]}
    return [text for _, text in sorted(pages)]


def crawl(language):
    host, page_ns, index_ns = SITES[language]
    path = TEXTS / f"wikisource-{language}.jsonl"
    done = set()
    if path.exists():
        for line in open(path, encoding="utf-8"):
            done.add(json.loads(line)["index"])
    books = indexes(host, index_ns)
    log(language, len(books), "books indexed;", len(done), "already fetched")
    books = books[:MAX_BOOKS]
    kept = 0
    with open(path, "a", encoding="utf-8") as out:
        for number, book in enumerate(books):
            if book["index"] in done:
                continue
            book["pages"] = book_pages(host, page_ns, book["index"])
            if book["pages"] is None:
                continue
            out.write(json.dumps(book, ensure_ascii=False) + "\n")
            out.flush()
            kept += bool(book["pages"])
            if number % 50 == 0:
                log(language, number, "/", len(books), "books;", kept, "with proofread text")
    log(language, "finished")


if __name__ == "__main__":
    for language in sys.argv[1:] or ["gu", "hi"]:
        crawl(language)
