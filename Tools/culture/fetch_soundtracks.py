#!/usr/bin/env python3
"""Indian film songs: the film each is from, who sang, wrote and composed it, and its raga.

Reads, from English Wikipedia unless noted:
  1. the soundtrack sections of the Indian films in the catalogue ({{Track listing}} and song
     tables), and the film's "(soundtrack)" article, {{Main}} target or Wikidata soundtrack
     (P406) where the tracks live instead. The film's composer (P86) is the default composer;
  2. every "List of [Hindi |Tamil |...]songs recorded by <singer>" page of an Indian singer;
  3. the Binaca Geetmala number one of each year, 1953-2000;
  4. the Filmfare, National Film Award and IIFA lyricist and playback-singer categories,
     winners and nominees;
  5. the list of film songs based on ragas;
  6. Hindi Wikipedia's soundtrack sections, for each track's title in Devanagari;
  7. a look, in at most five calls, at what Gujarati Wikipedia holds (songs/gujarati_probe.json).
Songs are deduplicated on (film, title as romanised). Titles, people, films, years, awards and
ragas only: no lyrics are read, kept or printed. Writes songs/soundtracks.json.

    fetch_soundtracks.py                         the full crawl
    fetch_soundtracks.py --limit 50 --pages 3    a dry run: the 50 best-known films, 3 pages of each list
    fetch_soundtracks.py --stages films,hindi    some sources only (films, hindi, singers, binaca,
                                                 awards, raga, gujarati)
"""
import argparse
import difflib
import html
import json
import re
import unicodedata
import urllib.parse
from collections import Counter, defaultdict, namedtuple

import common
from common import DATA, log, qid, sparql, wiki_api
from fetch_lists import NOISE, split_attributes
from fetch_wikipedia import categories

SONGS = DATA / "songs"
EN, HI, GU = "en.wikipedia.org", "hi.wikipedia.org", "gu.wikipedia.org"
STAGES = ["films", "hindi", "singers", "binaca", "awards", "raga", "gujarati"]

# Film language (P364) -> the code soundtracks.json uses. Hindustani counts as Hindi.
LANGUAGE = {"Q1568": "hi", "Q11051": "hi", "Q5885": "ta", "Q8097": "te", "Q36236": "ml", "Q33673": "kn",
            "Q9610": "bn", "Q1571": "mr", "Q58635": "pa", "Q5137": "gu", "Q1617": "ur"}
# A film in two of them takes the first it has: older Hindi films are often tagged Urdu too.
PREFERENCE = ["hi", "ta", "te", "ml", "kn", "bn", "mr", "pa", "gu", "ur"]
NAMED = {"hindi": "hi", "hindustani": "hi", "tamil": "ta", "telugu": "te", "malayalam": "ml", "kannada": "kn",
         "bengali": "bn", "bangla": "bn", "marathi": "mr", "punjabi": "pa", "gujarati": "gu", "urdu": "ur"}
# Languages a heading or column can name that soundtracks.json has no code for: those songs are left out.
OTHER = ("bhojpuri", "odia", "oriya", "assamese", "konkani", "sindhi", "nepali", "sinhala", "sinhalese", "english",
         "tulu", "maithili", "rajasthani", "haryanvi", "chhattisgarhi", "dogri", "kashmiri", "manipuri", "meitei",
         "santali", "persian", "arabic", "pashto", "magahi", "garhwali", "kumaoni", "badaga", "saurashtra")
NAMED_RE = re.compile(r"\b(" + "|".join(list(NAMED) + list(OTHER)) + r")\b", re.I)

SINGER_PREFIXES = ["List of songs recorded by"] + [f"List of {name} songs recorded by" for name in (
    "Hindi", "Tamil", "Telugu", "Malayalam", "Kannada", "Marathi", "Bengali", "Punjabi", "Urdu", "Gujarati", "non-Hindi")]
# The category a list of an Indian singer's songs sits in ("Lists of songs recorded by Indian singers").
INDIAN = re.compile(r"\b(India|Indian|Hindi|Bollywood|Tamil|Telugu|Malayalam|Kannada|Bengali|Bangla|Marathi|Punjabi|"
                    r"Gujarati|Urdu|Pakistani|Bangladeshi|Filmi|playback)\b", re.I)

BINACA = "Binaca Geetmala"
RAGAS = "List of film songs based on ragas"
# (article, canon label, whom the person column names, the language when the film does not say)
AWARDS = [
    ("Filmfare Award for Best Lyricist", "Filmfare Best Lyricist", "lyricist", "hi"),
    ("Filmfare Award for Best Male Playback Singer", "Filmfare Best Male Playback", "singer", "hi"),
    ("Filmfare Award for Best Female Playback Singer", "Filmfare Best Female Playback", "singer", "hi"),
    ("National Film Award for Best Lyrics", "National Film Award Best Lyrics", "lyricist", None),
    ("National Film Award for Best Male Playback Singer", "National Film Award Best Male Playback", "singer", None),
    ("National Film Award for Best Female Playback Singer", "National Film Award Best Female Playback", "singer", None),
    ("IIFA Award for Best Lyricist", "IIFA Best Lyricist", "lyricist", "hi"),
    ("IIFA Award for Best Male Playback Singer", "IIFA Best Male Playback", "singer", "hi"),
    ("IIFA Award for Best Female Playback Singer", "IIFA Best Female Playback", "singer", "hi"),
] + [(f"Filmfare Award for Best {what} – {language}", f"Filmfare Best {label} ({language})", role, NAMED[language.lower()])
     for language in ("Tamil", "Telugu", "Malayalam", "Kannada")
     for what, label, role in (("Lyricist", "Lyricist", "lyricist"), ("Male Playback Singer", "Male Playback", "singer"),
                               ("Female Playback Singer", "Female Playback", "singer"))]

TRACK_TEMPLATES = {"track listing", "tracklist", "track list", "tracklisting", "track listing2", "ट्रैक सूची",
                   "ट्रैकसूची", "ट्रैक लिस्टिंग", "गीत सूची", "ટ્રેક યાદી", "ટ્રેક સૂચિ"}
MAIN_TEMPLATES = {"main", "main article", "further", "further information", "see also", "details"}
MUSIC = re.compile(r"music|soundtrack|song|track|album|संगीत|गीत|गाने|गाना|साउंडट्रैक|સંગીત|ગીત", re.I)
HEADING = re.compile(r"^(={2,6})\s*(.+?)\s*\1\s*$")
# A listing of the background score, not of songs ("Original score", "The Love Legend Themes").
SCORE = re.compile(r"\b(score|bgm|background music|instrumentals?|themes)\b|पार्श्व संगीत", re.I)
LINK = re.compile(r"\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]*))?\]\]")
QUOTED = re.compile(r'["“”]\s*([^"“”\n]{1,120}?)\s*["“”]')
# Words that put a quotation forward as a line of the song rather than its title.
LYRIC_CUE = re.compile(r"\b(?:lines?|lyrics?|words|chorus|hook|refrain|verses?|couplets?|mukhda|antara|phrase|quote|"
                       r"bol|पंक्ति|बोल|मुखड़ा)\s*[:,–—-]?\s*$", re.I)
INDIC = re.compile(r"[ऀ-෿]")
SCRIPT = {"hi": re.compile(r"[ऀ-ॿ]"), "gu": re.compile(r"[઀-૿]")}
YEAR = re.compile(r"\b(19[0-9]{2}|20[0-9]{2})\b")
NOT_NAMES = {"", "-", "—", "–", "n/a", "na", "none", "solo", "instrumental", "chorus", "various", "various artists",
             "others", "unknown", "?", "tba", "tbd", "traditional", "duet", "male", "female", "background"}
NOT_A_NAME = re.compile(r"\b(?:awards?|won|winners?|nominees?|nominated|singers?|channel|official|title|songs?|tracks?|"
                        r"versions?|noted|uncredited)\b", re.I)
SOURCE_ORDER = {"track listing": 0, "singer page": 1, "binaca": 2, "award": 3, "raga": 4}

Cell = namedtuple("Cell", "text attrs header rowspan colspan")
Row = namedtuple("Row", "attrs cells group")

# Every call that misses the cache is counted, so a dry run can say what the full crawl will cost.
REQUESTS = Counter()
_fetch = common.fetch


OFFLINE = False  # --offline: answer from the cache only, as though every other page were missing


def counted_fetch(url, params=None, **options):
    if not common.cache_path(url, params)[1].exists():
        REQUESTS[("not cached: " if OFFLINE else "") + urllib.parse.urlparse(url).hostname] += 1
        if OFFLINE:
            return None
    return _fetch(url, params, **options)


common.fetch = counted_fetch


# ---------------------------------------------------------------- wikitext to plain text

def split_top(text, separators):
    """Split at separators that are not inside a [[link]] or {{template}}."""
    parts, depth, start, index = [], 0, 0, 0
    while index < len(text):
        pair = text[index:index + 2]
        if pair in ("[[", "{{"):
            depth, index = depth + 1, index + 2
        elif pair in ("]]", "}}"):
            depth, index = max(0, depth - 1), index + 2
        elif depth == 0 and any(text.startswith(sep, index) for sep in separators):
            sep = next(sep for sep in separators if text.startswith(sep, index))
            parts.append(text[start:index])
            index = start = index + len(sep)
        else:
            index += 1
    parts.append(text[start:])
    return parts


def template_text(match):
    """What a template shows, for the few that show their argument; the rest are dropped."""
    parts = split_top(match.group(1), ["|"])
    name = parts[0].strip().lower().replace("_", " ")
    values = [part.strip() for part in parts[1:] if not re.match(r"\s*[\w ]+\s*=", part)]
    if not values:
        return ""
    if name in ("hlist", "ubl", "unbulleted list", "plainlist", "flatlist", "bulleted list", "plain list", "flat list",
                "br separated entries", "comma separated entries", "unbulleted"):
        return "\n".join(values)
    if name in ("ill", "interlanguage link", "abbr", "nobold", "noitalic", "sic"):
        return values[0]
    if name == "sortname":
        return " ".join(values[:2])
    if name in ("nowrap", "small", "smaller", "big", "lang", "transl", "transliteration", "sort", "resize", "nobr", "font",
                "script", "noflag"):
        return values[-1]
    return ""


def clean(text):
    """Wikitext to plain text: links unwrapped, templates read or dropped, <br> as a new line."""
    text = NOISE.sub("", text or "")
    text = re.sub(r"<br\s*/?\s*>|<br\s[^>]*>", "\n", text, flags=re.I)
    for _ in range(6):
        inner = re.sub(r"\{\{([^{}]*)\}\}", template_text, text)
        if inner == text:
            break
        text = inner
    text = re.sub(r"\[\[(?:File|Image|Category):[^\[\]]*\]\]", "", text, flags=re.I)
    text = re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", text)
    text = re.sub(r"\[(?:https?:)?//\S+\s*([^\]]*)\]", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = html.unescape(text.replace("'''", "").replace("''", ""))
    return re.sub(r"[ \t ]+", " ", text).strip()


def tidy_title(title):
    """A title without the notes some listings put after it: '(Lyrics :- Kumaar)', '(Not
    included in the album)', '(Raga Pilu)', or a quoted translation in brackets."""
    return re.sub(r"\s*\((?=[^()]*(?::|[\"“”]|\blyric|\bcompos|\bnot (?:included|in|used|part)\b|\bra+ga?m?\b|\braag\b|"
                  r"\btitle (?:track|song)\b|\benglish song\b|\bonly\b|\bpart \d+ of\b))[^()]*\)", "", title, flags=re.I).strip()


def titles_in(raw):
    """The song titles a cell names: the quoted ones, else its first line. A quotation in
    brackets is a translation, and one after "line", "lyrics" or the like would be a quoted
    lyric: neither is taken."""
    text = clean(raw)
    bare = re.sub(r"\([^()]*\)", lambda m: " " * len(m.group()), text)
    quoted, previous, spans = [], 0, 0
    for match in QUOTED.finditer(bare):
        spans += 1
        title = tidy_title(text[match.start(1):match.end(1)])
        if title and not LYRIC_CUE.search(bare[previous:match.start()]):
            quoted.append(title)
        previous = match.end()
    if spans:
        return quoted  # never the cell's first line when a quotation in it was turned down
    first = tidy_title(text.split("\n")[0].strip(" \"'“”‘’-–—*"))
    return [first] if first else []


def link_for(raw, title, only=False):
    """The article a title links to: the link whose text is the title (or, with `only`, the
    only link there is: a film cell links nothing but its film)."""
    links = [(target.strip(), clean(shown or target)) for target, shown in LINK.findall(raw or "")
             if not target.lower().startswith(("file:", "image:", "category:", ":"))]
    for target, shown in links:
        if shown.strip(" \"'“”").lower() == title.lower() or key(shown) == key(title):
            return target
    return links[0][0] if only and len(links) == 1 else None


def names(raw):
    """The people a cell names, one per line, comma, ampersand or 'and'. A credit note ("X,
    except where noted", 'Y for "Song"'), an award's note ("Award was won by a female singer")
    and the winner's dagger are not names."""
    text = re.sub(r"\([^)]*\)", "", clean(raw))
    text = re.sub(r"[,;]?\s*\bexcept\b.*", "", text, flags=re.I | re.S)
    found = []
    for part in re.split(r"\n|,|;|&|/|•|·|\+|\band\b|\bwith\b|\bfeat\.|\bft\.|\bfeaturing\b| और ", text, flags=re.I):
        name = re.sub(r"[†‡§¶@^]", "", part).strip(" *#:-–—'\".")
        if name.lower() in NOT_NAMES or len(name) > 50 or re.search(r"\d|https?:|[\"“”«»]", name) or NOT_A_NAME.search(name):
            continue
        if not any(same_person(name, other) for other in found):
            found.append(name)
    return found


def credit(raw):
    return ", ".join(names(raw))


def language_named(text):
    """The language a heading or headline names, if it names exactly one ('xx' for one we do not keep)."""
    found = {NAMED.get(word.lower(), "xx") for word in NAMED_RE.findall(text or "")}
    return found.pop() if len(found) == 1 else None


def film_name(title):
    return re.sub(r"\s*\((?:\d{4} )?(?:[\w.-]+ )*film\)$", "", title or "", flags=re.I).strip()


# ---------------------------------------------------------------- matching titles across sources

def ascii_fold(text):
    return "".join(c for c in unicodedata.normalize("NFKD", text) if not unicodedata.combining(c))


def strip_notes(title):
    return re.sub(r"\s*[\(\[][^)\]]*[\)\]]", "", title or "").strip()


def key(title):
    """A romanised title folded so that spelling variants meet: 'Tujhe Dekha Toh' = 'Tujhe Dekha To'."""
    text = re.sub(r"[^a-z0-9]", "", ascii_fold(strip_notes(title)).lower())
    for old, new in (("ee", "i"), ("oo", "u"), ("w", "v"), ("z", "j"), ("q", "k"), ("ph", "f")):
        text = text.replace(old, new)
    text = re.sub(r"(.)\1+", r"\1", text.replace("h", ""))
    return text or "raw:" + (title or "").strip().lower()


DEVANAGARI = dict(zip("कखगघङ" "चछजझञ" "टठडढण" "तथदधन" "पफबभम" "यरलव" "शषस" "ळ" "ंँ",
                      "kkggn" "ccjjn" "ttddn" "ttddn" "ppbbm" "yrlv" "sss" "l" "nn"))


def bones(title):
    """The consonants of a title, in Roman or Indian script, for matching one against the other."""
    text = strip_notes(title)
    if INDIC.search(text):
        text = "".join(chr(ord(c) - 0x180) if "઀" <= c <= "૿" else c for c in text)  # Gujarati -> Devanagari
        letters = "".join(DEVANAGARI.get(c, "") for c in unicodedata.normalize("NFD", text))
    else:
        letters = re.sub(r"[^a-z]", "", ascii_fold(text).lower())
        # 'ch' is च; a 'c' on its own is the English k ("Criminal", "Disco").
        for old, new in (("ch", "\0"), ("c", "k"), ("\0", "c"), ("x", "ks"), ("q", "k"), ("z", "j"), ("f", "p"), ("w", "v")):
            letters = letters.replace(old, new)
        letters = re.sub(r"[aeiouh]", "", letters)
    return re.sub(r"(.)\1+", r"\1", letters)


def same_person(a, b):
    if a.lower() == b.lower():
        return True
    x, y = bones(a), bones(b)
    return len(x) >= 4 and x == y


def similar(a, b):
    return difflib.SequenceMatcher(None, a, b).ratio() if a and b else 0.0


# ---------------------------------------------------------------- templates, sections and tables

def template_params(body):
    named, positional = {}, []
    for part in split_top(body, ["|"]):
        match = re.match(r"\s*([^=\[\]{}|\n]+?)\s*=(.*)$", part, re.S)
        if match:
            named[match.group(1).strip().lower()] = match.group(2).strip()
        elif part.strip():
            positional.append(part.strip())
    return named, positional


def templates(text, wanted):
    """(position, named, positional) for every {{name|...}} in the text whose name is wanted."""
    found = []
    for match in re.finditer(r"\{\{\s*([^{}|\n]+?)\s*(?=[|}\n])", text):
        if match.group(1).strip().lower().replace("_", " ") not in wanted:
            continue
        depth, index = 0, match.start()
        while index < len(text):
            if text.startswith("{{", index):
                depth, index = depth + 1, index + 2
            elif text.startswith("}}", index):
                depth, index = depth - 1, index + 2
                if depth == 0:
                    break
            else:
                index += 1
        found.append((match.start(), *template_params(text[match.end():index - 2])))
    return found


def heading_paths(text):
    """position -> the headings above it, outermost first, as a sorted list of (position, path)."""
    marks, stack, position = [(0, [])], [], 0
    for line in text.split("\n"):
        match = HEADING.match(line.strip())
        if match:
            level = len(match.group(1))
            stack = [entry for entry in stack if entry[0] < level] + [(level, clean(match.group(2)))]
            marks.append((position, [name for _, name in stack]))
        position += len(line) + 1
    return marks


def path_at(marks, position):
    found = marks[0][1]
    for start, path in marks:
        if start > position:
            break
        found = path
    return found


def span(attrs, name):
    match = re.search(name + r"\s*=\s*[\"']?\s*(\d+)", attrs or "")
    return max(1, min(int(match.group(1)), 300)) if match else 1


def table_blocks(text):
    """(start position, rows) for every top-level table; a row is (row attributes, [Cell])."""
    blocks, current, depth, position = [], None, 0, 0
    for line in text.split("\n"):
        line_start, position = position, position + len(line) + 1
        stripped = line.strip()
        if current is None:
            if re.match(r":*\{\|", stripped):
                current, depth = {"start": line_start, "rows": [], "attrs": "", "cells": []}, 1
            continue
        cells = current["cells"]
        if cells and cells[-1].text.count("{{") > cells[-1].text.count("}}"):  # a template running over lines
            cells[-1] = cells[-1]._replace(text=cells[-1].text + "\n" + line)
            continue
        if re.match(r":*\{\|", stripped):
            depth += 1
        if depth > 1:  # a table inside a cell is kept as that cell's text
            depth -= 1 if stripped.startswith("|}") else 0
            if cells:
                cells[-1] = cells[-1]._replace(text=cells[-1].text + "\n" + line)
            continue
        if stripped.startswith("|}"):
            if cells:
                current["rows"].append((current["attrs"], cells))
            blocks.append((current["start"], current["rows"]))
            current = None
        elif stripped.startswith("|-"):
            if cells:
                current["rows"].append((current["attrs"], cells))
            current["attrs"], current["cells"] = stripped[2:], []
        elif stripped.startswith("|+"):
            continue
        elif stripped.startswith(("|", "!")):
            header = stripped.startswith("!")
            for part in split_top(stripped[1:], ["!!", "||"] if header else ["||"]):
                attrs, content = split_attributes(part)
                cells.append(Cell(content.strip(), attrs, header, span(attrs, "rowspan"), span(attrs, "colspan")))
        elif cells:
            cells[-1] = cells[-1]._replace(text=(cells[-1].text + "\n" + line).strip())
    return blocks


def header_names(rows):
    """Column names from the header row(s): a second row names the columns its parents span."""
    names_, parent = [], []
    for cell in rows[0]:
        names_ += [clean(cell.text)] * cell.colspan
        parent += [cell.colspan > 1 and cell.rowspan < 2] * cell.colspan
    if len(rows) > 1:
        subs = [clean(cell.text) for cell in rows[1] for _ in range(cell.colspan)]
        for slot, name in zip([i for i, flag in enumerate(parent) if flag], subs):
            names_[slot] = name
    return names_


def expand(rows, width):
    """Data rows with rowspans and colspans filled in. A lone full-width row is a group label
    ('1950s', a raga's name) and is passed on to the rows below it."""
    out, pending, group = [], {}, ""
    for attrs, cells in rows:
        if len(cells) == 1 and not pending and (cells[0].header or cells[0].colspan >= max(2, width)):
            group = clean(cells[0].text)
            continue
        line, queue, column = [], list(cells), 0
        while queue or any(c >= column for c in pending):
            if column in pending:
                left, cell = pending[column]
                line.append(cell)
                if left <= 1:
                    del pending[column]
                else:
                    pending[column] = (left - 1, cell)
                column += 1
            elif queue:
                cell = queue.pop(0)
                for _ in range(cell.colspan):
                    line.append(cell)
                    if cell.rowspan > 1:
                        pending[column] = (cell.rowspan - 1, cell)
                    column += 1
            else:
                line.append(Cell("", "", False, 1, 1))
                column += 1
        out.append(Row(attrs, line, group))
    return out


ROLE_TESTS = [(role, re.compile(unicodedata.normalize("NFKD", pattern))) for role, pattern in [
    ("lyricist", r"lyric|writer|गीतकार|ગીતકાર"),
    ("composer", r"music|compos|संगीत|સંગીત"),
    (None, r"director|picturi|cast|length|duration|notes?$|^refs?$|label|(^| )no$|number|^#$|^sr|^s no|^sl"),
    ("singers", r"singer|artist|vocal|perform|playback|^with$|गायक|गायिका|गायन|ગાયક|ગાયિકા"),
    ("raga", r"^ra+ga?m?s?$|^raag"),
    ("title", r"song|title|track|गीत|गाना|शीर्षक|ગીત"),
    ("film", r"film|movie|album|फ़िल्म|फिल्म|चलचित्र|ફિલ્મ"),
    ("year", r"year|वर्ष|साल"),
    ("language", r"lang|भाषा"),
    ("person", r"recipient|nominee|winner|awardee|name"),
]]


def role(header):
    text = unicodedata.normalize("NFKD", header or "").lower()
    text = "".join(c for c in text if not "̀" <= c <= "ͯ").replace("(s)", "")
    text = re.sub(r"[\s\-–—_/,.:;!?()\[\]'\"*|]+", " ", text).strip()
    if not text:
        return None
    for name, pattern in ROLE_TESTS:
        if pattern.search(text):
            return name
    return None


def tables(text, film_songs=False):
    """(headings above, column roles, rows) for every table with a song column in the text. With
    `film_songs` (award pages), also a table whose film column names the song: 'Film – "Song"'."""
    marks = heading_paths(text)
    found = []
    for start, rows in table_blocks(text):
        heads = []
        while rows and all(cell.header for cell in rows[0][1]):
            heads.append(rows.pop(0)[1])
        if not heads:
            continue
        roles = [role(name) for name in header_names(heads[:2])]
        if ("title" in roles and set(roles) & {"singers", "lyricist", "composer", "film", "raga", "person"}) or \
                (film_songs and "title" not in roles and "film" in roles and set(roles) & {"singers", "lyricist", "person"}):
            found.append((start, path_at(marks, start), roles, expand(rows, len(roles))))
    return found


def row_facts(roles, row):
    """What one table row says, by column role."""
    facts = {"titles": [], "links": [], "singers": [], "person": [], "raw": {}}
    for name, cell in zip(roles, row.cells):
        if name is None or name in facts["raw"] and name != "singers":
            continue
        facts["raw"].setdefault(name, cell)
        if name == "title":
            facts["titles"] = titles_in(cell.text)
            facts["links"] = [link_for(cell.text, title) for title in facts["titles"]]
        elif name == "singers":
            facts["singers"] += [n for n in names(cell.text) if not any(same_person(n, o) for o in facts["singers"])]
        elif name == "person":
            facts["person"] = names(cell.text)
        elif name == "film":
            text = clean(cell.text).split("\n")[0]
            song = QUOTED.search(text) if "title" not in roles else None
            if song:  # 'Laapataa Ladies – "Sajni"', 'Theevandi ("Jeevamshamayi")': no song column on the page
                facts["titles"] = [tidy_title(song.group(1))]
                facts["links"] = [link_for(cell.text, facts["titles"][0])]
                text = re.sub(r"[\s(–—-]+$", "", text[:song.start()])
            facts["film_title"] = film_name(text.strip(" \"'“”"))
            facts["film_link"] = link_for(cell.text, facts["film_title"], only=True) or next(
                (target for target, _ in LINK.findall(cell.text)), None)
        elif name == "year":
            match = YEAR.search(clean(cell.text))
            facts["year"] = int(match.group(1)) if match else None
        elif name in ("lyricist", "composer"):
            facts[name] = credit(cell.text)
        elif name == "raga":
            facts["raga"] = clean(cell.text).split("\n")[0].strip() or None
        elif name == "language":
            facts["language"] = language_named(clean(cell.text))
    # One cell across the song column and a people column ("Award was won by a female singer"):
    # a note, not a song. (A title track's cell may span the film column; that one stays.)
    title_cell = facts["raw"].get("title")
    if title_cell and any(cell is title_cell for name, cell in zip(roles, row.cells)
                          if name in ("singers", "person", "lyricist", "composer")):
        facts["titles"], facts["links"] = [], []
    return facts


def marked(row, roles, dagger=True):
    """Whether an award row is the winner's: highlighted or bold, in the row or its name cells.
    '‡' counts only where the page does not use it for something else (`dagger`): on the IIFA
    pages it means "also nominated for the Filmfare Award"."""
    if re.search(r"background", row.attrs or "", re.I):
        return True
    for name, cell in zip(roles, row.cells):
        if name in ("title", "person", "lyricist", "singers") and cell.rowspan == 1:
            if "'''" in cell.text or re.search(r"background|\{\{won" + ("|‡" if dagger else ""), cell.attrs + cell.text, re.I):
                return True
    return False


# ---------------------------------------------------------------- fetching

def contents(site, titles, batch=50):
    """Requested title -> wikitext, following redirects, for every page that exists."""
    result = {}
    for start in range(0, len(titles), batch):
        params = {"action": "query", "prop": "revisions", "rvprop": "content", "rvslots": "main", "redirects": "1",
                  "titles": "|".join(titles[start:start + batch])}
        while True:
            data = wiki_api(site, params)
            for title, content in pages_by_request(data, lambda page: page["revisions"][0]["slots"]["main"]["content"]).items():
                result[title] = content
            if "continue" not in data:
                break
            params = {**params, **data["continue"]}
        if start and start % 2500 == 0:
            log(" ", site, start, "/", len(titles))
    return result


def pages_by_request(data, read):
    """Requested title -> read(page), for every title asked for that leads to a page (two
    spellings of one title, or a redirect and its target, both get it). The page's own title
    always gets it too: it may have been asked for directly as well as through a redirect."""
    origins = defaultdict(list)
    for step in data.get("query", {}).get("normalized", []) + data.get("query", {}).get("redirects", []):
        origins[step["to"]] += origins.pop(step["from"], [step["from"]])
    found = {}
    for page in data.get("query", {}).get("pages", []):
        try:
            value = read(page)
        except (KeyError, IndexError):
            continue
        for title in [page["title"]] + origins.get(page["title"], []):
            found[title] = value
    return found


def article_ids(titles):
    """Requested title -> (qid, the article's own title), following redirects. The request is
    the one fetch_lists.wikidata_ids makes, so the two share a cache."""
    found = {}
    for start in range(0, len(titles), 50):
        data = wiki_api(EN, {"action": "query", "prop": "pageprops", "ppprop": "wikibase_item", "redirects": "1",
                             "titles": "|".join(titles[start:start + 50])})
        for title, value in pages_by_request(data, lambda page: (page["pageprops"]["wikibase_item"], page["title"])).items():
            found[title] = value
    return found


def film_language(languages, countries):
    """The film's language code; 'xx' when it has only languages we keep no code for, or is a
    foreign film with an Indian language in passing; None when Wikidata gives none."""
    if not languages:
        return None
    codes = {LANGUAGE[l] for l in languages if l in LANGUAGE}
    if not codes or ("Q1860" in languages and not {"Q668", "Q843"} & set(countries)):
        return "xx"
    return next(code for code in PREFERENCE if code in codes)


def labels_of(entries):
    return [e["label"] for e in entries if e.get("label") and not e["label"].startswith("http")]


def film_table():
    """qid -> {title, name, hiwiki, guwiki, language, composers, year, links} for every Indian film
    in the catalogue, plus the films only the song catalogue knows (facts filled in later)."""
    base = json.loads((DATA / "catalog_base.json").read_text())
    details = json.loads((DATA / "catalog_details.json").read_text())
    films = {}
    for work in base:
        if work.get("kind") != "film" or "in" not in work.get("cultures", []):
            continue
        info = details.get(work["id"], {})
        title = info.get("enwiki") if isinstance(info.get("enwiki"), str) else None
        films[work["id"]] = {
            "title": title, "name": info.get("label_en") or film_name(title) or "", "hiwiki": info.get("hiwiki"),
            "guwiki": info.get("guwiki"), "language": film_language([e["id"] for e in info.get("language", [])],
                                                                     [e["id"] for e in info.get("country", [])]),
            "composers": labels_of(info.get("composer", [])), "year": work.get("year"), "links": work.get("links", 0),
            "catalogue": True}
    extra = SONGS / "song_films.json"
    for item, info in (json.loads(extra.read_text()) if extra.exists() else {}).items():
        if item not in films:
            films[item] = {"title": info.get("title") or None, "name": film_name(info.get("title")), "hiwiki": None,
                           "guwiki": None, "language": info.get("language"), "composers": None, "year": info.get("year"),
                           "links": 0}
    return films


def catalog_films(films, limited):
    """Films the song catalogue ties songs to that neither the catalogue nor song_films.json
    describes: looked up on Wikidata so their articles are read too."""
    path = SONGS / "song_catalog.json"
    catalog = json.loads(path.read_text()) if path.exists() else {}
    missing = sorted({film for song in catalog.values() for film in song.get("films", []) if film not in films})
    if missing:
        log("films from the song catalogue to look up:", len(missing))
        films.update(film_facts(missing[:200] if limited else missing))


def film_facts(items):
    """The same facts, from Wikidata, for films the catalogue lacks (200 to a query)."""
    facts = {}
    for start in range(0, len(items), 200):
        values = " ".join("wd:" + item for item in items[start:start + 200])
        rows = sparql("""SELECT ?item ?p ?v ?vl WHERE { VALUES ?item { %s }
          { ?item wdt:P364 ?v. BIND("language" AS ?p) } UNION { ?item wdt:P495 ?v. BIND("country" AS ?p) }
          UNION { ?item wdt:P86 ?v. BIND("composer" AS ?p) OPTIONAL { ?v rdfs:label ?vl FILTER(LANG(?vl) IN ("en", "mul")) } }
          UNION { ?item wdt:P577 ?d. BIND(STR(YEAR(?d)) AS ?v) BIND("year" AS ?p) }
          UNION { ?page schema:about ?item; schema:isPartOf <https://en.wikipedia.org/>; schema:name ?v. BIND("enwiki" AS ?p) }
          UNION { ?page schema:about ?item; schema:isPartOf <https://hi.wikipedia.org/>; schema:name ?v. BIND("hiwiki" AS ?p) }
          UNION { ?item rdfs:label ?v. FILTER(LANG(?v) = "en") BIND("label" AS ?p) } }""" % values)
        found = defaultdict(lambda: defaultdict(dict))
        for row in rows or []:
            if "v" not in row or "p" not in row:
                continue  # a date Wikidata holds as "unknown" leaves the year unbound
            value = qid(row["v"]) if row["v"].startswith("http://www.wikidata.org/entity/") else row["v"]
            found[qid(row["item"])][row["p"]][value] = row.get("vl", "")
        for item, info in found.items():
            years = [int(y) for y in info.get("year", {}) if y.isdigit()]
            title = next(iter(info.get("enwiki", {})), None)
            facts[item] = {"title": title, "name": next(iter(info.get("label", {})), "") or film_name(title),
                           "hiwiki": next(iter(info.get("hiwiki", {})), None), "guwiki": None,
                           "language": film_language(list(info.get("language", {})), list(info.get("country", {}))),
                           "composers": [label for label in info.get("composer", {}).values() if label],
                           "year": min(years) if years else None, "links": 0}
    return facts


def soundtrack_items():
    """Film qid -> English articles of its soundtrack album (P406), for films in our languages."""
    values = " ".join("wd:" + item for item in LANGUAGE if item != "Q11051")
    rows = sparql("""SELECT DISTINCT ?film ?title WHERE { VALUES ?lang { %s } ?film wdt:P364 ?lang; wdt:P406 ?album.
        ?page schema:about ?album; schema:isPartOf <https://en.wikipedia.org/>; schema:name ?title. }""" % values)
    found = defaultdict(list)
    for row in rows or []:
        found[qid(row["film"])].append(row["title"])
    return found


# ---------------------------------------------------------------- 1. film articles

def record(source, title, **facts):
    entry = {"film": None, "film_title": "", "title": title, "native_title": "", "singers": [], "lyricist": "",
             "composer": "", "year": None, "language": None, "qid": None, "source": source, "labels": [], "raga": None,
             "_link": None, "_film_link": None, "_hint": None, "_default": None, "_page": None, "_list_year": None}
    entry.update({name: value for name, value in facts.items() if value not in (None, "", [])})
    return entry


def good_title(title):
    return 1 < len(title) <= 100 and not re.fullmatch(r"[\d\W]+|total( length)?|untitled", title, re.I)


def tracks_in(text, site, whole=False):
    """Every track an article lists, in order: {{Track listing}}s anywhere, and song tables and
    list lines in its music sections (anywhere in a soundtrack article, where `whole`)."""
    text = NOISE.sub("", text)
    marks = heading_paths(text)
    found = []
    in_music = lambda path: whole or any(MUSIC.search(name) for name in path)
    for position, named, _ in templates(text, TRACK_TEMPLATES):
        path = path_at(marks, position)
        if SCORE.search(clean(named.get("headline", "")) + " " + " ".join(path[-1:])):
            continue
        language = language_named(named.get("headline", "")) or language_named(" ".join(path[-1:]))
        extra = role(clean(named.get("extra_column", ""))) if named.get("extra_column") else None
        defaults = {"lyricist": credit(named.get("all_lyrics", "")) or credit(named.get("all_writing", "")),
                    "composer": credit(named.get("all_music", ""))}
        numbers = sorted({int(m.group(1)) for name in named for m in [re.fullmatch(r"title(\d+)", name)] if m})
        for number in numbers:
            raw = named.get(f"title{number}", "")
            titles = titles_in(raw)
            if not titles or not good_title(titles[0]):
                continue
            track = {"title": titles[0], "link": link_for(raw, titles[0]), "singers": [], "raga": None,
                     "lyricist": credit(named.get(f"lyrics{number}", "")) or credit(named.get(f"writer{number}", "")) or defaults["lyricist"],
                     "composer": credit(named.get(f"music{number}", "")) or defaults["composer"],
                     "language": language, "position": position + number}
            cell = named.get(f"extra{number}", "")
            if extra == "singers":
                track["singers"] = names(cell)
            elif extra in ("lyricist", "composer") and cell:
                track[extra] = credit(cell)
            elif extra == "raga" and cell:
                track["raga"] = clean(cell).split("\n")[0] or None
            found.append(track)
    for start, path, roles, rows in tables(text):
        if not in_music(path) or SCORE.search(" ".join(path[-1:])):
            continue
        language = language_named(" ".join(path[-1:]))
        for index, row in enumerate(rows):
            facts = row_facts(roles, row)
            for title, link in zip(facts["titles"], facts["links"]):
                if good_title(title):
                    found.append({"title": title, "link": link, "singers": facts["singers"],
                                  "lyricist": facts.get("lyricist", ""), "composer": facts.get("composer", ""),
                                  "raga": facts.get("raga"), "language": facts.get("language") or language,
                                  "position": start + index})
    found += list_tracks(text, marks, site, in_music)
    return sorted(found, key=lambda track: track["position"])


def list_tracks(text, marks, site, in_music):
    """Tracks given as list lines in a music section: '# "Title" – Singer' on English Wikipedia;
    'Title - singer' in Devanagari or Gujarati script on the Hindi and Gujarati ones."""
    found, position = [], 0
    for line in text.split("\n"):
        start, position = position, position + len(line) + 1
        match = re.match(r"^[#*]+\s*(.+)$", line.strip())
        if not match or not in_music(path_at(marks, start)):
            continue
        body = clean(match.group(1)).split("\n")[0]
        if site == "en":
            quoted = QUOTED.match(body)
            if not quoted:
                continue
            title, rest = quoted.group(1).strip(), body[quoted.end():]
            inside = re.match(r"\s*\(([^)]*)\)", rest)
            rest = inside.group(1) if inside else (re.sub(r"^\s*[-–—:]\s*", "", rest) if re.match(r"\s*[-–—:]", rest) else "")
        else:
            parts = re.split(r"\s+[-–—]\s+|\s*:\s+", body, maxsplit=1)
            if len(parts) < 2 or not SCRIPT.get(site, INDIC).search(parts[0]):
                continue
            title, rest = parts[0].strip(" \"'“”"), parts[1]
        if good_title(title) and len(title) <= 60:
            found.append({"title": title, "link": None, "singers": names(rest), "lyricist": "", "composer": "",
                          "raga": None, "language": None, "position": start, "listed": True})
    return found


def names_film(target, film):
    """Whether an article title names the film: 'Devdas (soundtrack)' for 'Devdas (2002 Hindi film)'."""
    base = re.sub(r"\s*\([^)]*\)$", "", target)
    for name in {film["name"], film_name(film["title"])} - {"", None}:
        if key(base) == key(name) or (len(bones(name)) >= 4 and similar(bones(base), bones(name)) >= 0.85):
            return True
    return False


def soundtrack_targets(text, film):
    """Articles a film's music section sends the reader to: its {{Main}} targets, its
    '(soundtrack)' links anywhere, and '(album)' links in the music section. Only those that
    name the film: Dil Se.. links 'Jeans (soundtrack)' and Ra.One 'Dostana (soundtrack)' in
    passing, and a {{See also}} can point at a singer's whole song list."""
    text = NOISE.sub("", text)
    marks = heading_paths(text)
    found = []
    for position, _, positional in templates(text, MAIN_TEMPLATES):
        if any(MUSIC.search(name) for name in path_at(marks, position)):
            found += [target.split("{{!}}")[0].split("#")[0] for target in positional if not target.startswith("#")]
    for match in LINK.finditer(text):
        target = match.group(1).strip()
        if re.search(r"\((?:[^)]*\s)?soundtrack\)$", target, re.I):
            found.append(target)
        elif re.search(r"\((?:[^)]*\s)?album\)$", target, re.I) and any(MUSIC.search(n) for n in path_at(marks, match.start())):
            found.append(target)
    found = [re.sub(r"\s+", " ", clean(target)).strip() for target in found]
    return [target for target in dict.fromkeys(found) if target and "=" not in target and names_film(target, film)]


def film_tracks(films, order):
    """Stage 1: track listings from film articles and their soundtrack articles."""
    log("film articles:", len(order))
    records, targets = [], defaultdict(list)
    # A thousand articles at a time, so the whole crawl's wikitext is never held at once. 1000 is a
    # multiple of the 50-title batch, so the requests (and cache keys) are the same as in one go.
    for start in range(0, len(order), 1000):
        chunk = order[start:start + 1000]
        texts = contents(EN, [films[item]["title"] for item in chunk])
        for item in chunk:
            text = texts.get(films[item]["title"], "")
            records += film_records(item, films[item], tracks_in(text, "en"), 0)
            for target in soundtrack_targets(text, films[item]):
                if target != films[item]["title"] and item not in targets[target]:
                    targets[target].append(item)
        if len(order) > 1000:
            log("  film articles read:", start + len(chunk), "/", len(order))
    chosen = set(order)
    for item, titles_ in soundtrack_items().items():
        for target in titles_:
            if item in chosen and item not in targets[target]:
                targets[target].append(item)
    log("soundtrack articles and {{Main}} targets:", len(targets))
    texts = contents(EN, sorted(targets))
    for target, items in targets.items():
        tracks = tracks_in(texts.get(target, ""), "en", whole=True)
        for item in items:  # after the film article's own tracks, when the two are put in order
            records += film_records(item, films[item], tracks, 10 ** 7)
    found = {r["film"] for r in records}
    log("tracks from film and soundtrack articles:", len(records), "on", len(found), "of", len(order), "films")
    return records


def film_records(item, film, tracks, offset):
    return [record("track listing", t["title"], film=item, film_title=film["name"], singers=t["singers"],
                   lyricist=t["lyricist"], composer=t["composer"], raga=t["raga"], language=t["language"],
                   _link=t["link"], _position=offset + t["position"]) for t in tracks]


# ---------------------------------------------------------------- 2. singer pages

def singer_pages(limited, pages):
    """Every 'List of ... songs recorded by' page of an Indian singer, by title."""
    titles = []
    for prefix in SINGER_PREFIXES[:2] if limited else SINGER_PREFIXES:
        params = {"action": "query", "list": "allpages", "apprefix": prefix, "apnamespace": "0",
                  "apfilterredir": "nonredirects", "aplimit": "max"}
        while True:
            data = wiki_api(EN, params)
            titles += [page["title"] for page in data.get("query", {}).get("allpages", [])]
            if "continue" not in data or limited:
                break
            params = {**params, **data["continue"]}
    generic = [title for title in titles if title.startswith(SINGER_PREFIXES[0] + " ")]
    named_ = [title for title in titles if not title.startswith(SINGER_PREFIXES[0] + " ")]
    if limited:
        generic = generic[:50]
    found = categories(generic)
    indian = sorted(set(named_) | {title for title in generic if any(INDIAN.search(c) for c in found.get(title, []))})
    log("singer pages:", len(titles), "listed,", len(indian), "of Indian singers")
    return indian[:pages] if limited else indian


def singer_tracks(limited, pages):
    """Stage 2: the rows of every Indian singer's song list."""
    titles = singer_pages(limited, pages)
    texts = contents(EN, titles, batch=10)
    records = []
    for title in titles:
        text = texts.get(title, "")
        singer = re.sub(r"\s*\([^)]*\)$", "", re.sub(r"^List of (?:[\w-]+ )*?songs recorded by ", "", title))
        page_language = language_named(title.split(" songs recorded by")[0])
        before = len(records)
        for _, path, roles, rows in tables(NOISE.sub("", text)):
            heading_language = language_named(" ".join(path))
            heading_year = next((int(m) for name in reversed(path) for m in YEAR.findall(name)), None)
            for row in rows:
                facts = row_facts(roles, row)
                if not facts.get("film_title") and not facts.get("film_link"):
                    continue
                singers = facts["singers"] if any(same_person(singer, s) for s in facts["singers"]) else [singer] + facts["singers"]
                group_year = YEAR.search(row.group or "")
                for title_, link in zip(facts["titles"], facts["links"]):
                    if good_title(title_):
                        records.append(record("singer page", title_, film_title=facts.get("film_title"), _film_link=facts.get("film_link"),
                                              singers=singers, lyricist=facts.get("lyricist"), composer=facts.get("composer"),
                                              year=facts.get("year") or heading_year or (int(group_year.group(1)) if group_year else None),
                                              raga=facts.get("raga"), _link=link, _page=title,
                                              _hint=facts.get("language") or heading_language or page_language))
        log("  ", title, len(records) - before, "rows")
    return records


# ---------------------------------------------------------------- 3-5. Binaca, awards, ragas

def list_tracks_from(text, source, label=None, role_=None, language=None):
    """Rows of the song tables on a list page: Binaca's number ones, an award's winners and
    nominees (unmarked rows of a table that marks its winners), the raga list."""
    records = []
    dagger = not re.search(r"‡[^\n]{0,60}\bnominat", text or "")
    for _, path, roles, rows in tables(NOISE.sub("", text), film_songs=source == "award"):
        # A table marks its winners among nominees only when years have several rows; a
        # winners-only table (the Filmfare South pages) can carry a stray bold name.
        years = Counter(row_facts(roles, row).get("year") for row in rows) if source == "award" else Counter()
        several = sum(1 for year, count in years.items() if year and count > 1)
        winners = source == "award" and not (label or "").startswith("National Film Award") and \
            several >= max(1, len(years) // 2) and any(marked(row, roles, dagger) for row in rows)
        heading = path[-1] if path else ""
        for row in rows:
            facts = row_facts(roles, row)
            if not facts["titles"]:
                continue
            people = facts["person"]
            singers = facts["singers"] + (people if role_ == "singer" else [])
            lyricist = facts.get("lyricist") or (", ".join(people) if role_ == "lyricist" else "")
            labels = []
            if label:
                labels = [label if not winners or marked(row, roles, dagger) else label + " nominee"]
            raga = facts.get("raga") or (row.group if source == "raga" and row.group and not YEAR.search(row.group) else None)
            if source == "raga" and not raga and heading and len(heading) > 2 and not re.search(r"\d|see also|references", heading, re.I):
                raga = heading
            group_year = YEAR.search(row.group or "")
            hint = facts.get("language") or language_named(" ".join(path)) or language
            for title, link in zip(facts["titles"], facts["links"]):
                for version, said in versions(title) if source == "raga" else [(title, None)]:
                    if not good_title(version):
                        continue
                    # The year on an award or chart list is the ceremony's or the chart's; the
                    # film's own year comes first, this one only when the film is unknown.
                    records.append(record(source, version, film_title=facts.get("film_title"), _film_link=facts.get("film_link"),
                                          singers=singers, lyricist=lyricist, composer=facts.get("composer"),
                                          _list_year=facts.get("year") or (int(group_year.group(1)) if group_year else None),
                                          raga=raga, labels=labels, _link=link if version == title else None,
                                          _hint=said or hint, _default="hi" if source in ("binaca", "raga") else None))
    return records


def versions(title):
    """The raga list gives a song's versions in two languages in one cell: 'Koondhalile Megam
    Vanthu (Tamil) / Kurulande Megham Varishi (Telugu)'. Each is (title, language it names)."""
    if not re.search(r"\s/\s|\)\s*/", title):
        return [(title, None)]
    found = []
    for part in re.split(r"\s*/\s*", title):
        marker = re.search(r"\s*\(\s*([A-Za-z]+)\s*\)\s*$", part)
        said = ({"h": "hi"}.get(marker.group(1).lower()) or NAMED.get(marker.group(1).lower())) if marker else None
        # '(H)' is Hindi; '(T)' may be Tamil or Telugu, so it is dropped and the film decides.
        found.append((part[:marker.start()].strip() if said or (marker and len(marker.group(1)) == 1) else part.strip(), said))
    return found


def list_page_tracks(stages, limited, pages):
    """Stages 3-5: one batched call for Binaca, the award pages and the raga list."""
    awards = AWARDS[:pages] if limited else AWARDS
    titles = [BINACA, RAGAS] + [page for page, *_ in awards]
    texts = contents(EN, titles)
    missing = [title for title in titles if title not in texts]
    if missing:
        log("list pages not found:", missing)
    records = []
    if "binaca" in stages:
        found = list_tracks_from(texts.get(BINACA, ""), "binaca", "Binaca Geetmala #1", language="hi")
        log("Binaca Geetmala number ones:", len(found))
        records += found
    if "awards" in stages:
        for page, label, role_, language in awards:
            found = list_tracks_from(texts.get(page, ""), "award", label, role_, language)
            log(f"  {label}: {len(found)} songs, {sum(1 for r in found if not r['labels'][0].endswith('nominee'))} winners")
            records += found
    if "raga" in stages:
        found = list_tracks_from(texts.get(RAGAS, ""), "raga")
        log("songs based on ragas:", len(found), "with a raga:", sum(1 for r in found if r["raga"]))
        records += found
    return records


# ---------------------------------------------------------------- films and songs by id

def article_key(title):
    title = (title or "").replace("_", " ").strip()
    return title[:1].upper() + title[1:]


def resolve(records, films, limited):
    """Give every record its film's qid, and every linked track title its song's qid. Films the
    catalogue does not know are looked up on Wikidata; a linked 'film' with no language is an
    album or a show, and is kept only as a film title."""
    local = {article_key(info["title"]): item for item, info in films.items() if info.get("title")}
    songs_by_title = song_titles()
    wanted = []
    for entry in records:
        link = article_key(entry["_film_link"]) if entry["_film_link"] else None
        if entry["film"] is None and link:
            # "[[Barfi! (soundtrack)|Barfi!]]" in a film column is the film's album: the film is meant.
            album_of = re.sub(r"\s*\((?:[^)]*\s)?(?:soundtrack|album)\)$", "", link, flags=re.I)
            if link in local or album_of in local:
                entry["film"] = local.get(link) or local[album_of]
            else:
                wanted.append(link)
        if entry["_link"] and article_key(entry["_link"]) not in songs_by_title:
            wanted.append(article_key(entry["_link"]))
    wanted = list(dict.fromkeys(wanted))
    if limited:
        wanted = wanted[:50]
    log("titles to look up on Wikidata:", len(wanted))
    ids = article_ids(wanted) if wanted else {}
    works = {work["id"] for work in json.loads((DATA / "catalog_base.json").read_text())}
    for entry in records:
        link = article_key(entry["_film_link"]) if entry["_film_link"] else None
        if entry["film"] is None and link in ids:
            entry["film"] = ids[link][0]
        if entry["_link"]:
            target = article_key(entry["_link"])
            song, article = (songs_by_title[target], target) if target in songs_by_title else ids.get(target, (None, ""))
            # A title can link to a redirect to the album or the film: the article must be the song's.
            about = re.sub(r"\s*\([^)]*\)$", "", article)
            if song and song not in works and song not in films and (key(about) == key(entry["title"]) or similar(bones(about), entry["_bones"] if "_bones" in entry else bones(entry["title"])) >= 0.8):
                entry["qid"] = song
    unknown = sorted({e["film"] for e in records if e["film"] and (e["film"] not in films or films[e["film"]]["composers"] is None)})
    if limited:
        unknown = unknown[:200]
    if unknown:
        log("films to look up on Wikidata:", len(unknown))
        for item, info in film_facts(unknown).items():
            old = films.get(item, {})
            films[item] = {**info, **{k: v for k, v in old.items() if v not in (None, "", [])}, "composers": info["composers"]}
    for entry in records:
        info = films.get(entry["film"] or "")
        if info and info["language"] is None and not info.get("catalogue") and entry["source"] != "track listing":
            entry["film_title"] = entry["film_title"] or films[entry["film"]]["name"]
            entry["film"] = None  # an album, a show or an unknown: no film to point at
        elif entry["film"] and entry["film"] not in films:
            entry["film"] = None
    by_name = defaultdict(list)
    for item, info in films.items():
        if info["name"]:
            by_name[key(info["name"])].append(item)
    for entry in records:  # films named without a link: by name and year
        if entry["film"] is None and entry["film_title"]:
            options = by_name.get(key(entry["film_title"]), [])
            # An album looked up above ("Aashiqui 2", 2013, no language) must not tie with its film.
            options = [item for item in options if films[item]["language"] is not None or films[item].get("catalogue")] or options
            dated = [item for item in options if entry["year"] and films[item]["year"] and abs(films[item]["year"] - entry["year"]) <= 1]
            exact = [item for item in dated if films[item]["year"] == entry["year"]]
            if len(exact) == 1:  # "Barfi!" (2012) over "Barfi" (2013)
                dated = exact
            if len(dated) == 1 or (len(options) == 1 and not entry["year"]):
                entry["film"] = (dated or options)[0]
        if entry["film"] and not entry["film_title"]:
            entry["film_title"] = films[entry["film"]]["name"]


def song_titles():
    """English article title -> qid for the songs the song catalogue already holds."""
    found = {}
    path = SONGS / "song_catalog.json"
    for item, song in (json.loads(path.read_text()) if path.exists() else {}).items():
        if song.get("wikis", {}).get("en"):
            found[article_key(song["wikis"]["en"])] = item
    return found


def song_names():
    """(film qid, folded title) -> song qid, from the song details (or, before those exist,
    one Wikidata query for the labels of the songs made for Indian films)."""
    found = {}
    path = SONGS / "song_details.json"
    if path.exists():
        named = []
        for item, detail in json.loads(path.read_text()).items():
            for film in detail.get("films", []):
                for label in {detail.get("labels", {}).get("en"), *detail.get("wikis", {}).values()} - {None, ""}:
                    label = re.sub(r"\s*\((?:[^)]*\s)?song\)$", "", label)
                    named.append(("(" not in label, film, key(label), item))
        # 'Yeh Dosti' and 'Yeh Dosti (sad version)' fold alike: the plain label is written last and wins.
        for _, film, folded, item in sorted(named, key=lambda entry: entry[0]):
            found[(film, folded)] = item
        return found
    values = " ".join("wd:" + item for item in LANGUAGE if item != "Q11051")
    rows = sparql("""SELECT ?item ?film ?label WHERE { VALUES ?lang { %s } ?film wdt:P364 ?lang. ?item wdt:P9899 ?film;
        rdfs:label ?label. FILTER(LANG(?label) IN ("en", "mul")) }""" % values)
    for row in rows or []:
        found[(qid(row["film"]), key(row["label"]))] = qid(row["item"])
    return found


# ---------------------------------------------------------------- merging

def same_title(key_a, key_b, bones_a, bones_b):
    """Two titles of one song: the same when folded, the same consonants, or one the start of
    the other (a list that gives the whole first line, "Ankhiyon ke jharokhon se, mainen dekha jo")."""
    shorter, longer = sorted((key_a, key_b), key=len)
    return (key_a == key_b or (len(bones_a) >= 6 and bones_a == bones_b)
            or (len(shorter) >= 10 and not shorter.startswith("raw:") and longer.startswith(shorter)))


def spoken(entry, films):
    """The language a record says its song is in: stated, else the film's."""
    return entry["language"] or entry["_hint"] or films.get(entry["film"] or "", {}).get("language")


def merge(records, films):
    """One record per (film, folded title, language); later sources fill what earlier ones
    lack. A dubbed version (RRR's Hindi "Dosti") stays apart from the original."""
    songs, by_film = [], defaultdict(list)
    for entry in sorted(records, key=lambda r: SOURCE_ORDER[r["source"]]):
        film_key = entry["film"] or "t:" + key(entry["film_title"] or "?")
        title_key, title_bones, language = key(entry["title"]), bones(entry["title"]), spoken(entry, films)
        same = next((s for s in by_film[film_key] if same_title(s["_key"], title_key, s["_bones"], title_bones)
                     and (not language or not spoken(s, films) or language == spoken(s, films))), None)
        if same is None:
            entry["_key"], entry["_bones"] = title_key, title_bones
            by_film[film_key].append(entry)
            songs.append(entry)
            continue
        for singer in entry["singers"]:
            if not any(same_person(singer, other) for other in same["singers"]):
                same["singers"].append(singer)
        for field in ("lyricist", "composer", "raga", "qid", "native_title", "film_title", "year", "_link", "_hint", "_default",
                      "_page", "_list_year"):
            if not same[field] and entry[field]:
                same[field] = entry[field]
        same["labels"] += [label for label in entry["labels"] if label not in same["labels"]]
        if ("(" in same["title"] and "(" not in entry["title"]) or (title_key != same["_key"] and same["_key"].startswith(title_key)):
            # The plain title, or the short one over a whole first line; the key follows it, so
            # the song's Wikidata label is looked up under the title kept.
            same["title"], same["_key"], same["_bones"] = entry["title"], title_key, title_bones
    return songs


def finish(songs, films):
    """Language, year and composer from the film where the source did not give them."""
    pages = defaultdict(Counter)
    for entry in songs:
        info = films.get(entry["film"] or "", {})
        if entry["_page"] and info.get("language") not in (None, "xx"):
            pages[entry["_page"]][info["language"]] += 1
    kept, dropped = [], Counter()
    for entry in songs:
        info = films.get(entry["film"] or "", {})
        page = pages.get(entry["_page"])
        language = (spoken(entry, films) or entry["_default"] or (page.most_common(1)[0][0] if page else None)
                    or ("hi" if entry["_page"] else None))
        if language not in PREFERENCE:
            dropped[language or "unknown"] += 1
            continue
        entry["language"] = language
        entry["year"] = entry["year"] or info.get("year") or entry["_list_year"]
        entry["composer"] = entry["composer"] or ", ".join(info.get("composers") or [])
        entry["film_title"] = entry["film_title"] or info.get("name", "")
        kept.append(entry)
    if dropped:
        log("left out, language not one of ours:", dict(dropped))
    return kept


# ---------------------------------------------------------------- 6-7. native titles

def match_native(english, native, by_position):
    """Pair Indian-script tracks with the English ones by the consonants of their titles and
    singers, with a little extra for the same place in lists of the same length."""
    pairs, used, scored = {}, set(), []
    same_length = by_position and len(english) == len(native)
    for i, entry in enumerate(english):
        for j, track in enumerate(native):
            title_score = similar(entry["_bones"], bones(track["title"]))
            singer_score = max([similar(bones(a), bones(b)) for a in entry["singers"] for b in track["singers"]] or [0])
            score = 0.6 * title_score + 0.25 * singer_score + (0.15 if same_length and i == j else 0)
            if title_score >= 0.35:
                scored.append((score, i, j))
    for score, i, j in sorted(scored, reverse=True):
        if score >= 0.45 and i not in pairs and j not in used:
            pairs[i] = native[j]["title"]
            used.add(j)
    return pairs


def native_titles(songs, films, items, site, languages):
    """Stage 6 (and the Gujarati probe): the native-script title of each track, from the
    film's article on the Hindi (or Gujarati) Wikipedia. Returns how many films had tracks."""
    field = "hiwiki" if site == HI else "guwiki"
    by_film = defaultdict(list)
    for entry in songs:
        if entry["source"] == "track listing" and entry["film"] in items and entry["language"] in languages:
            by_film[entry["film"]].append(entry)
    wanted = [item for item in items if films[item].get(field) and (by_film.get(item) or site == GU)]
    texts = contents(site, [films[item][field] for item in wanted], batch=25)
    with_tracks = filled = 0
    samples = []
    for item in wanted:
        tracks = [t for t in tracks_in(texts.get(films[item][field], ""), site.split(".")[0]) if SCRIPT[site.split(".")[0]].search(t["title"])]
        if not tracks:
            continue
        with_tracks += 1
        samples.append([films[item]["name"], [t["title"] for t in tracks[:3]]])
        english = sorted(by_film.get(item, []), key=lambda e: e.get("_position") or 0)
        by_position = not any(t.get("listed") for t in tracks)
        for index, title in match_native(english, tracks, by_position).items():
            if index < len(english) and not english[index]["native_title"]:
                english[index]["native_title"] = title
                filled += 1
    log(f"{site}: {len(wanted)} film articles asked for, {len(texts)} found, {with_tracks} with tracks, {filled} titles matched")
    return {"articles": len(wanted), "found": len(texts), "with_tracks": with_tracks, "matched": filled, "samples": samples[:10]}


def gujarati_probe(songs, films):
    """Stage 7: what Gujarati Wikipedia holds, in at most five calls: the articles of the films
    we know have one (60 of them, three calls), the pages that use its track-listing template
    (one), and a search for pages that name a lyricist (one)."""
    items = sorted(item for item, info in films.items() if info.get("guwiki"))[:75]
    report = native_titles(songs, films, items, GU, {"gu"})
    data = wiki_api(GU, {"action": "query", "list": "embeddedin", "eititle": "Template:Track listing", "einamespace": "0", "eilimit": "max"})
    report["track_listing_pages"] = [page["title"] for page in data.get("query", {}).get("embeddedin", [])]
    data = wiki_api(GU, {"action": "query", "list": "search", "srsearch": "ગીતકાર", "srnamespace": "0", "srlimit": "50", "srprop": ""})
    report["pages_naming_a_lyricist"] = data.get("query", {}).get("searchinfo", {}).get("totalhits")
    report["lyricist_page_titles"] = [hit["title"] for hit in data.get("query", {}).get("search", [])]
    log("gu.wikipedia: track listing template on", len(report["track_listing_pages"]), "pages;",
        report["pages_naming_a_lyricist"], "pages name a lyricist (ગીતકાર)")
    (SONGS / "gujarati_probe.json").write_text(json.dumps(report, ensure_ascii=False, indent=1))


# ---------------------------------------------------------------- main

def attach_song_ids(songs, films):
    names_ = song_names()
    matched = 0
    for entry in songs:
        if not entry["qid"] and entry["film"]:
            entry["qid"] = names_.get((entry["film"], entry["_key"]))
            matched += bool(entry["qid"])
    # A dubbed version under the same linked title is not the song the item is about: the item
    # stays with the version in the film's own language.
    holders = defaultdict(list)
    for entry in songs:
        if entry["qid"]:
            holders[entry["qid"]].append(entry)
    for entries in holders.values():
        keep = next((e for e in entries if e["language"] == films.get(e["film"] or "", {}).get("language")), entries[0])
        for entry in entries:
            if entry is not keep:
                entry["qid"] = None
    log("songs matched to a Wikidata item:", sum(1 for e in songs if e["qid"]), f"({matched} by film and title)")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--limit", type=int, help="only the N best-known films (and N pages of each list): a dry run")
    parser.add_argument("--pages", type=int, help="with --limit, how many singer and award pages to read (default N)")
    parser.add_argument("--stages", default=",".join(STAGES), help="comma-separated, of: " + ", ".join(STAGES))
    parser.add_argument("--offline", action="store_true", help="read only what is cached; make no request")
    args = parser.parse_args()
    global OFFLINE
    OFFLINE = args.offline
    stages = set(args.stages.split(","))
    if stages - set(STAGES):
        parser.error(f"unknown stages {sorted(stages - set(STAGES))}; choose from {', '.join(STAGES)}")
    limited = args.limit is not None
    pages = args.pages if args.pages is not None else args.limit
    SONGS.mkdir(parents=True, exist_ok=True)

    films = film_table()
    catalog_films(films, limited)
    order = sorted((item for item, info in films.items() if info["title"] and info["language"] in PREFERENCE),
                   key=lambda item: (-films[item]["links"], item))
    order = order[:args.limit] if limited else order
    log("Indian films:", len(films), " with an English article in our languages:", len(order))

    records = []
    if "films" in stages:
        records += film_tracks(films, order)
    if "singers" in stages:
        records += singer_tracks(limited, pages)
    if stages & {"binaca", "awards", "raga"}:
        records += list_page_tracks(stages, limited, pages)
    resolve(records, films, limited)
    songs = finish(merge(records, films), films)
    attach_song_ids(songs, films)
    if "hindi" in stages:
        native_titles(songs, films, order, HI, {"hi", "ur", "mr"})
    if "gujarati" in stages:
        gujarati_probe(songs, films)

    out = [{field: entry[field] for field in ("film", "film_title", "title", "native_title", "singers", "lyricist",
                                              "composer", "year", "language", "qid", "source", "labels", "raga")}
           for entry in songs]
    if not stages & {"films", "singers", "binaca", "awards", "raga"}:
        log("no song source among the stages: soundtracks.json left as it was")
        return
    (SONGS / "soundtracks.json").write_text(json.dumps(out, ensure_ascii=False))
    log("songs:", len(out), " by source:", dict(Counter(e["source"] for e in out)), " by language:",
        dict(Counter(e["language"] for e in out).most_common()))
    log("with a film:", sum(1 for e in out if e["film"]), " a Devanagari title:", sum(1 for e in out if e["native_title"]),
        " a canon label:", sum(1 for e in out if e["labels"]), " a raga:", sum(1 for e in out if e["raga"]),
        " a Wikidata item:", sum(1 for e in out if e["qid"]))
    log("network requests:", sum(REQUESTS.values()), dict(REQUESTS), "partial (--limit)" if limited else "")


if __name__ == "__main__":
    main()
