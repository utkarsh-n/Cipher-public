#!/usr/bin/env python3
"""Step 6: the concordance. Shows a word in use, with who wrote the line and when.

Reads the public-domain texts (Gutenberg in English, French and Spanish; Wikisource in Hindi
and Gujarati), keeps a couple of good lines for every word the lexicon knows, and writes
../../Cipher/Resources/culture-lines.tsv sorted by word so the app can binary-search it:

    word <TAB> year <TAB> language <TAB> title <TAB> author <TAB> line
"""
import json
import re
import struct
import unicodedata
from collections import defaultdict

from common import DATA, ROOT, log

RESOURCES = ROOT.parent / "Cipher" / "Resources"
OUT = RESOURCES / "culture-lines.tsv"
LANGUAGE_INDEX = {"en": 0, "hi": 1, "gu": 2, "es": 3, "fr": 4}
SENTENCE = re.compile(r"(?<=[.!?।॥;:])\s+|\n{2,}")
MIN_LENGTH, MAX_LENGTH = 28, 110


def lexicon_words():
    """word -> (tier, frequency) per language, read straight from the compiled lexicon."""
    blob = (RESOURCES / "lexicon.bin").read_bytes()
    header = struct.unpack_from("<24Q", blob, 0)
    count = header[1]
    languages, tiers, freqs, text_offsets, text = header[4], header[5], header[6], header[9], header[10]
    offsets = struct.unpack_from(f"<{count + 1}I", blob, text_offsets)
    words = [dict() for _ in LANGUAGE_INDEX]
    for entry in range(count):
        language = blob[languages + entry]
        chunk = blob[text + offsets[entry]:text + offsets[entry + 1]]
        word = chunk.split(b"\t", 1)[0].decode("utf-8")
        tier, freq = blob[tiers + entry], blob[freqs + entry]
        known = words[language].get(word)
        if known is None or tier < known[0]:
            words[language][word] = (tier, freq)
    return words


def tokens(line):
    """Words as the app cleans them: letters with their combining marks, apostrophes inside."""
    word = []
    for character in unicodedata.normalize("NFC", line.lower()).replace("’", "'"):
        category = unicodedata.category(character)
        if category[0] in "LM" or (character == "'" and word):
            word.append(character)
        elif word:
            yield "".join(word).strip("'")
            word = []
    if word:
        yield "".join(word).strip("'")


def sentences(text):
    text = re.sub(r"[ \t\r]+", " ", text)
    for piece in SENTENCE.split(text):
        line = " ".join(piece.split())
        if MIN_LENGTH <= len(line) <= MAX_LENGTH and not line.isupper() and sum(c.isdigit() for c in line) < 4:
            yield line


def gutenberg_body(text):
    start = re.search(r"\*\*\* ?START OF (?:THE|THIS) PROJECT GUTENBERG[^\n]*\n", text)
    end = re.search(r"\*\*\* ?END OF (?:THE|THIS) PROJECT GUTENBERG", text)
    return text[start.end() if start else 0:end.start() if end else len(text)]


def sources():
    """(language, title, author, year, prominence, text) for every text on disk."""
    listing = DATA / "texts" / "gutenberg.json"
    if listing.exists():
        for book in json.loads(listing.read_text()):
            path = DATA / "texts" / "gutenberg" / f"{book['id']}.txt"
            if path.exists():
                yield book["language"], book["title"], book["author"], book["year"], book["links"], gutenberg_body(path.read_text(encoding="utf-8", errors="replace"))
    for language in ("hi", "gu"):
        path = DATA / "texts" / f"wikisource-{language}.jsonl"
        if not path.exists():
            continue
        for line in open(path, encoding="utf-8"):
            book = json.loads(line)
            if book["pages"]:
                yield language, book["title"] or book["index"], book["author"], book["year"], 10, "\n\n".join(book["pages"])


def era(year):
    """Which stretch of history a text belongs to; a word's examples are spread across these."""
    if not year:
        return 0
    return 1 + sum(year >= start for start in (1700, 1800, 1850, 1880, 1900, 1915))


def main():
    lexicon = lexicon_words()
    # (word, language) -> era -> the best line of that era. The examples kept for a word come
    # from different eras where they can, so the app can show a word's use over time.
    best = defaultdict(dict)
    seen_lines = 0
    for language, title, author, year, prominence, text in sources():
        known = lexicon[LANGUAGE_INDEX[language]]
        period = era(year)
        for line in sentences(text):
            seen_lines += 1
            # A line that is neither too terse nor too long reads best as an example.
            score = prominence + 8 - abs(len(line) - 70) / 10
            for word in set(tokens(line)):
                info = known.get(word)
                # Everyday words only, but not the few dozen commonest: nobody needs "the" in use.
                if info is None or info[0] > 1 or info[1] >= 130 or len(word) < 3:
                    continue
                entries = best[(word, language)]
                if period not in entries or score > entries[period][0]:
                    entries[period] = (score, title, author, year, line)
        if seen_lines % 200000 < 400:
            log(f"{seen_lines} lines read, {len(best)} words with examples")

    def quota(word, language):
        tier, freq = lexicon[LANGUAGE_INDEX[language]][word]
        return 3 if freq >= 60 else 2 if tier == 0 else 1

    for key, entries in best.items():
        kept = sorted(entries.values(), key=lambda entry: -entry[0])[:quota(*key)]
        best[key] = kept

    def clean(value):
        return str(value or "").replace("\t", " ").replace("\n", " ").strip()

    rows = []
    for (word, language), entries in best.items():
        for _, title, author, year, line in sorted(entries, key=lambda entry: entry[3] or 9999):
            rows.append((word.encode("utf-8"), "\t".join([word, clean(year), language, clean(title), clean(author), clean(line)])))
    rows.sort(key=lambda row: row[0])
    OUT.write_text("\n".join(row for _, row in rows) + "\n", encoding="utf-8")
    per_language = defaultdict(int)
    for (word, language), entries in best.items():
        per_language[language] += len(entries)
    log(f"{len(rows)} lines for {len(best)} words -> {OUT.name} ({OUT.stat().st_size // 1_048_576} MB)", dict(per_language))


if __name__ == "__main__":
    main()
