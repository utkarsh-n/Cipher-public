#!/usr/bin/env python3
"""Songs step 3: the song canon, from chart, award and list pages on English, Spanish and French Wikipedia.

Reads, as wikitext through the MediaWiki API:
  - Billboard: every Year-End Hot 100 (1959 on) and the year-end lists before it, every number
    one (year pages and decade pages), the Hot 100 top tens by year, and the R&B and rap number
    ones found through "Category:Lists of number-one songs in the United States";
  - the UK: number ones by decade and top tens by year;
  - awards and canon: Grammy Record and Song of the Year and Best Rap Song, the Oscar for Best
    Original Song (with the film each song was written for), the National Recording Registry,
    the Grammy Hall of Fame, the best-selling singles, Rolling Stone's 500 (what the page has);
  - Latin and Spain: Hot Latin number ones (1986 on; on the twin-chart pages from 2012, the Hot
    Latin column only), Latin Pop Airplay, the seven Latin Grammy song categories, Spain's number
    ones, Spain in Eurovision, and the Spanish Wikipedia lists for Mexico, Los 40, Chile and
    Argentina;
  - France: number ones 1955 on, Victoires de la Musique, the Félix, France in Eurovision, and
    the French Wikipedia number-one lists (singles and radio) and "Victoire de la chanson originale".
Songs are named as quoted links ("[[Song]]"), quoted titles with no article, or (on the Spanish
and French lists) plain or italic links in a song column. A table's columns are read by their
headers, with rowspans carried down, so a song held at number one for weeks, or an artist cell
spanning several rows, is read once; on a twin-chart page only the first chart is kept unless
the page says otherwise. The year comes from the row (a year or date column, a divider row),
else the section heading, else the page title; Year-End and top-ten pages always take the page's
year. Award winners are told from nominees by bold or gold rows, or by a column of nominees.
Where no column says "song" (the pre-1958 Billboard pages, charts side by side), every chart
column is read and the performer is the line under the title in the same cell.
Linked songs are resolved to Wikidata ids through each site's own sitelinks. No id is taken
from a link to a section ("Song#Artist version": the item is the original recording's), a
redirect to a section, an article whose disambiguator says album, band or film, an article
whose title shares no word with the title shown ("Mandy" -> "Brandy (Scott English song)"), or,
on English Wikipedia, one whose short description does not call it a song or single first.
Facts only: titles, artists, years, ranks, labels; no lyrics are read or kept.

Writes songs/song_canon.json, one row per song per list and label:
    {"title", "artist", "year", "culture", "label", "rank", "qid", "page", "site"}
(rank: the Year-End position, the top-ten peak, the Rolling Stone or best-sellers rank, the
Eurovision place; null elsewhere), and songs/relations_song_lists.json: each Oscar song
"written for" its film, in the shape of relations_songs.json. Any of --limit, --only, --sites,
--no-discover or --no-ids makes the run partial: it writes songs/song_canon.partial.json and no
relations file, so it never overwrites the full canon.

    fetch_song_lists.py                        the full crawl
    fetch_song_lists.py --limit 5              dry run: the first five pages only
    fetch_song_lists.py --only "UK top-ten"    only pages whose title matches
    fetch_song_lists.py --limit 5 --no-ids --no-discover --out /tmp/canon.json
"""
import argparse
import html
import json
import re
import time
import unicodedata
from collections import Counter

from common import DATA, log, wiki_api
from fetch_lists import NOISE, split_attributes

SONGS = DATA / "songs"
SITES = {"en": "en.wikipedia.org", "es": "es.wikipedia.org", "fr": "fr.wikipedia.org"}
YEAR_NOW = time.localtime().tm_year

# ----------------------------------------------------------------------------------------------
# Which pages, and what being on each one means.
# kind: chart (a number one), yearend and topten (a rank or peak is kept), award (winners and
# nominees told apart), list (a canon list; a rank is kept when the page gives one).
# others: what to do with a second song column (a twin chart): None skips it, "same" keeps the
# label, any other string is the label for it.


def page(site, title, label, culture, kind="chart", others=None, quoted=False, lines=False, film=False, known=False,
         within=None):
    """One page to read. `quoted`: only quoted titles are songs (an italic one is an album or a
    speech); `lines`: songs are also listed in bulleted lines, not only in tables; `film`: keep
    the film each song is from; `known`: the title came from the wiki itself (a category or
    prefix listing), so it exists and needs no check; `within`: read only the sections whose
    headings match this pattern (a page that lists other prizes too)."""
    return {"site": site, "title": title, "label": label, "culture": culture, "kind": kind,
            "others": others, "quoted": quoted, "lines": lines, "film": film, "known": known, "within": within}


def us_pages():
    pages = []
    for year in range(1959, YEAR_NOW):
        pages.append(page("en", f"Billboard Year-End Hot 100 singles of {year}", "Year-End Hot 100", "us", "yearend"))
    for year in range(1946, 1959):  # the titles vary before the Hot 100; whichever exist are read
        for name in ("top", "top 30", "top 50"):
            pages.append(page("en", f"Billboard year-end {name} singles of {year}", "Billboard year-end", "us", "yearend"))
    for year in range(1940, 1959):  # before the Hot 100: several charts side by side; 1958's Hot 100 page redirects here
        pages.append(page("en", f"List of Billboard number-one singles of {year}", "Billboard #1", "us", others="same"))
    for year in range(1958, YEAR_NOW + 1):
        pages.append(page("en", f"List of Billboard Hot 100 number ones of {year}", "Hot 100 #1", "us"))
    for decade in range(1950, YEAR_NOW, 10):
        pages.append(page("en", f"List of Billboard Hot 100 number-one singles of the {decade}s", "Hot 100 #1", "us"))
    for year in range(1958, YEAR_NOW + 1):
        pages.append(page("en", f"List of Billboard Hot 100 top-ten singles in {year}", "Hot 100 top 10", "us", "topten"))
    for decade in range(1950, YEAR_NOW, 10):
        pages.append(page("en", f"List of UK singles chart number ones of the {decade}s", "UK #1", "us"))
    for year in range(1952, YEAR_NOW + 1):
        pages.append(page("en", f"List of UK top-ten singles in {year}", "UK top 10", "us", "topten"))
    pages += [
        page("en", "Grammy Award for Record of the Year", "Grammy Record of the Year", "us", "award"),
        page("en", "Grammy Award for Song of the Year", "Grammy Song of the Year", "us", "award"),
        page("en", "Grammy Award for Best Rap Song", "Grammy Best Rap Song", "us", "award"),
        page("en", "Academy Award for Best Original Song", "Oscar Best Original Song", "us", "award", film=True),
        page("en", "National Recording Registry", "National Recording Registry", "us", "list", quoted=True),
        page("en", "List of best-selling singles", "Best-selling singles", "us", "list"),
        page("en", "List of best-selling singles in the United Kingdom", "UK best-selling singles", "us", "list"),
        page("en", "Rolling Stone's 500 Greatest Songs of All Time", "Rolling Stone 500", "us", "list"),
    ]
    return pages


def latin_pages():
    pages = [page("en", "List of number-one Billboard Top Latin Songs from the 1980s", "Hot Latin #1", "es")]
    for year in range(1990, 2005):
        pages.append(page("en", f"List of number-one Billboard Hot Latin Tracks of {year}", "Hot Latin #1", "es"))
    for year in range(2005, 2010):
        pages.append(page("en", f"List of number-one Billboard Hot Latin Songs of {year}", "Hot Latin #1", "es"))
    for year in (2010, 2011):
        pages.append(page("en", f"List of number-one Billboard Top Latin Songs of {year}", "Hot Latin #1", "es"))
    for year in range(2012, YEAR_NOW + 1):  # twin charts: the Hot Latin column only
        pages.append(page("en", f"List of Billboard Hot Latin Songs and Latin Airplay number ones of {year}", "Hot Latin #1", "es"))
    pages.append(page("en", "List of Billboard Latin Pop Airplay number ones of 1994 and 1995", "Latin Pop Airplay #1", "es"))
    for year in range(1996, 2002):
        pages.append(page("en", f"List of Billboard Latin Pop Airplay number ones of {year}", "Latin Pop Airplay #1", "es"))
    for year in range(2002, 2013):
        pages.append(page("en", f"List of number-one Billboard Latin Pop Airplay songs of {year}", "Latin Pop Airplay #1", "es"))
    for category in ("Record of the Year", "Song of the Year", "Best Urban Song", "Best Pop Song", "Best Rock Song",
                     "Best Tropical Song", "Best Regional Mexican Song"):
        pages.append(page("en", f"Latin Grammy Award for {category}", f"Latin Grammy {category}", "es", "award"))
    pages += [
        page("en", "List of best-selling Latin singles", "Best-selling Latin singles", "es", "list"),
        page("en", "List of best-selling Latin singles in the United States", "Best-selling Latin singles", "es", "list"),
    ]
    for year in range(1985, YEAR_NOW + 1):  # two charts on the later pages: sales, then airplay
        pages.append(page("en", f"List of number-one singles of {year} (Spain)", "Spain #1", "es", others="Spain airplay #1"))
    pages += [
        page("en", "List of best-selling singles in Spain", "Spain best-selling singles", "es", "list"),
        page("en", "Spain in the Eurovision Song Contest", "Eurovision (Spain)", "es", "list"),
    ]
    return pages


def french_pages():
    pages = []
    for year in range(1955, YEAR_NOW + 1):  # "number-one singles" to 2015, "number-one hits" after; the redirects tell
        for name in ("singles", "hits"):
            pages.append(page("en", f"List of number-one {name} of {year} (France)", "France #1", "fr", others="same"))
    pages += [
        page("en", "List of best-selling singles in France", "France best-selling singles", "fr", "list"),
        # Only the song prizes: the same page lists the music-video winners as quoted titles too.
        page("en", "Victoires de la Musique", "Victoire (song)", "fr", "award", quoted=True, lines=True, within=r"\bsong\b"),
        # Lists ceremonies and recipients, no songs (checked); kept in case the page grows a song list.
        page("en", "Félix Award", "Félix", "fr", "award", quoted=True, lines=True, within=r"\bsong\b"),
        page("en", "France in the Eurovision Song Contest", "Eurovision (France)", "fr", "list"),
    ]
    for year in range(1955, YEAR_NOW + 1):
        pages.append(page("fr", f"Liste des titres musicaux numéro un en France en {year}", "France #1", "fr", others="same"))
    for year in range(2010, YEAR_NOW + 1):
        pages.append(page("fr", f"Liste des titres musicaux numéro un au classement radio en France en {year}", "France radio #1", "fr", others="same"))
    pages.append(page("fr", "Victoire de la chanson originale", "Victoire (song)", "fr", "award", lines=True))
    return pages


# Found by asking the wikis rather than by pattern: the titles follow no single scheme.
US_NUMBER_ONES = "Category:Lists of number-one songs in the United States"
RNB = re.compile(r"R&B|rhythm and blues|black|soul|hip[- ]hop|\brap\b", re.I)
HALL_OF_FAME = "List of Grammy Hall of Fame Award recipients"
ES_PREFIXES = ["Sencillos número uno", "Canciones número uno", "Los número uno", "Los números uno"]
ES_KEEP = re.compile(r"M[eé]xico|Los ?40|LOS ?40|Chile|Argentina|Espa[ñn]a en la d[eé]cada de 19[5-8]0")


def discovered_pages():
    """R&B and rap number ones, the Grammy Hall of Fame pages, and the Spanish Wikipedia lists."""
    pages = []
    members = category_members("en", US_NUMBER_ONES)
    for title, namespace in list(members):
        if namespace == 14 and RNB.search(title):
            members += category_members("en", title)
    for title, namespace in members:
        if namespace == 0 and RNB.search(title) and not re.search(r"album|^Lists of", title, re.I):
            label = "Rap #1" if re.search(r"\brap\b", title, re.I) else "R&B #1"
            pages.append(page("en", title, label, "us", known=True))
    for title in prefixed("en", 0, HALL_OF_FAME):
        pages.append(page("en", title, "Grammy Hall of Fame", "us", "list", quoted=True, lines=True, known=True))
    for prefix in ES_PREFIXES:
        for title in prefixed("es", 104, prefix):
            name = title.split(":", 1)[-1]
            if not ES_KEEP.search(name) or re.search(r"[ÁA]lbum", name):
                continue
            if re.search(r"Los ?40|LOS ?40", name):
                label = "Los 40 #1" + (" (Mexico)" if re.search(r"M[eé]xico", name) else " (Chile)" if "Chile" in name else "")
            elif re.search(r"M[eé]xico", name):
                label = "Mexico #1"
            elif "Chile" in name:
                label = "Chile #1"
            elif "Argentina" in name:
                label = "Argentina #1"
            else:
                label = "Spain #1"
            pages.append(page("es", title, label, "es", known=True))
    log("discovered:", len(pages), "pages")
    return pages


def category_members(site, title):
    """(title, namespace) of a category's pages and subcategories."""
    found = []
    params = {"action": "query", "list": "categorymembers", "cmtitle": title, "cmtype": "page|subcat", "cmlimit": "max"}
    while True:
        data = wiki_api(SITES[site], params)
        found += [(m["title"], m["ns"]) for m in data.get("query", {}).get("categorymembers", [])]
        if "continue" not in data:
            return found
        params = {**params, **data["continue"]}


def prefixed(site, namespace, prefix):
    """Titles of the articles (not redirects) that start with a prefix."""
    found = []
    params = {"action": "query", "list": "allpages", "apprefix": prefix, "apnamespace": str(namespace),
              "apfilterredir": "nonredirects", "aplimit": "max"}
    while True:
        data = wiki_api(SITES[site], params)
        found += [p["title"] for p in data.get("query", {}).get("allpages", [])]
        if "continue" not in data:
            return found
        params = {**params, **data["continue"]}


# ----------------------------------------------------------------------------------------------
# Talking to the wikis.


def wikitext(site, title):
    """A page's wikitext, with references and comments taken out. `site` is en, es or fr.
    (fetch_lists.wikitext reads English Wikipedia only; the parameters here are the same, so an
    English page either script has read is not asked for twice.)"""
    data = wiki_api(SITES[site], {"action": "parse", "page": title, "prop": "wikitext", "redirects": "1"})
    text = NOISE.sub("", data.get("parse", {}).get("wikitext", ""))
    text = re.sub(r"<includeonly>.*?</includeonly>", "", text, flags=re.S)
    return re.sub(r"</?(?:onlyinclude|noinclude)\s*/?>", "", text)


def follow(query, title):
    """Where a title ends up after normalisation and redirects, and whether it lands on a section."""
    steps = {s["from"]: s for s in query.get("normalized", []) + query.get("redirects", [])}
    sectioned, seen = False, set()
    while title in steps and title not in seen:
        seen.add(title)
        sectioned = sectioned or bool(steps[title].get("tofragment"))
        title = steps[title]["to"]
    return title, sectioned


def existing(site, titles):
    """Asked title -> the article it resolves to, for the titles that exist."""
    found = {}
    for start in range(0, len(titles), 50):
        batch = titles[start:start + 50]
        query = wiki_api(SITES[site], {"action": "query", "redirects": "1", "titles": "|".join(batch)}).get("query", {})
        present = {p["title"] for p in query.get("pages", []) if not p.get("missing") and not p.get("invalid")}
        for title in batch:
            target, _ = follow(query, title)
            if target in present:
                found[title] = target
    return found


def wikidata_ids(site, titles):
    """Article title -> (Wikidata id, short description), through the article's sitelink on that
    site. A title that redirects to a section of another article (a song folded into its album's
    or singer's page) gets no id: the item would be the album's or the singer's. English
    Wikipedia gives each article a short description ("1985 single by Wham!"); the others do not."""
    ids = {}
    for start in range(0, len(titles), 50):
        batch = titles[start:start + 50]
        query = wiki_api(SITES[site], {"action": "query", "prop": "pageprops", "ppprop": "wikibase_item|wikibase-shortdesc",
                                       "redirects": "1", "titles": "|".join(batch)}).get("query", {})
        props = {p["title"]: p.get("pageprops", {}) for p in query.get("pages", [])}
        for title in batch:
            target, sectioned = follow(query, title)
            item = props.get(target, {}).get("wikibase_item")
            if item and not sectioned:
                ids[title] = (item, props[target].get("wikibase-shortdesc", ""))
        if start and start % 2500 == 0:
            log("  ids", site, start, "/", len(titles))
    return ids


# A linked "song" whose article turns out to be an album, a singer, a place or a movement.
SONGLIKE = re.compile(r"\b(songs?|singles?|canci[oó]n|chanson|sencillo|anthem|hymn|track|instrumental|composition|march|"
                      r"waltz|aria|lullaby|carol|jingle|theme|recording(?! (?:artist|studio|company|label|engineer))|"
                      r"standard|ballad|spiritual|tune|piece|medley|duet|rhyme|chant|remix|musical work)\b", re.I)
NOT_A_SONG = re.compile(r"\b(album|EP|extended play|mixtape|compilation|rapper|singer|musician|songwriter|composer|band|"
                        r"group|duo|trio|orchestra|record label|organi[sz]ation|movement|film|television|series|video game|"
                        r"actor|actress|poet|novel|book|company|city|country|politician|festival|artist|entertainer|"
                        r"producer|disambiguation|speech|island|river|town|village)\b", re.I)
# An article whose disambiguator names something other than a song: "Recuerdos (álbum)", "(EP)".
NOT_A_SONG_PAGE = re.compile(r"\((?:[^()]*\s)?(?:album|álbum|EP|banda|band|grupo|groupe|group|cantante|singer|rapper|rappeur|"
                             r"chanteur|chanteuse|musician|músico|musicien|película|film|serie|série|TV series|telenovela|"
                             r"musical|comédie musicale)\)$", re.I)
FILLER = {"the", "and", "los", "las", "les", "des", "une", "del", "por", "con", "for", "from", "with", "aux", "sur", "par",
          "pour", "una", "uno", "song", "cancion", "chanson", "single"}


def song_id(found):
    """The id of a song article, or None when its short description (English Wikipedia only)
    does not call it a song first: "1985 single by Wham!" is one, "1990 studio album by Ice
    Cube", "island in France" and a disambiguation page are not."""
    if not found:
        return None
    item, description = found
    if not description:
        return item
    song, other = SONGLIKE.search(description), NOT_A_SONG.search(description)
    return item if song and (not other or song.start() < other.start()) else None


def title_words(text):
    text = unicodedata.normalize("NFKD", text.lower())
    text = "".join(c for c in text if not unicodedata.combining(c))
    return {word for word in re.findall(r"\w+", text) if len(word) > 2 and word not in FILLER}


def id_worth_asking(title, article):
    """Whether a linked article can stand for the song the list names. Not when its
    disambiguator says album, band or film, nor when the shown title shares no word with the
    article's ("Mandy" linking to "Brandy (Scott English song)", "Dímelo" to "I Need to Know"):
    the article is about another recording, and the item would carry the wrong title and singer."""
    if not article or NOT_A_SONG_PAGE.search(article):
        return False
    shown, named = title_words(title), title_words(article)  # with its parentheses: "Arthur's Theme (Best That You Can Do)"
    return not shown or not named or any(a == b or (min(len(a), len(b)) > 3 and (a.startswith(b) or b.startswith(a)))
                                         for a in shown for b in named)


# ----------------------------------------------------------------------------------------------
# Wikitext to plain text.

# Templates whose first positional value is the text shown, whose last one is, whose values are
# shown one per line, and whose values are a date to be read for its year.
FIRST = {"abbr", "ill", "interlanguage link", "illm", "ill2", "flag", "tooltip", "nihongo", "nowrap", "nobr", "small",
         "smaller", "big", "nobold", "noitalic", "center", "visible anchor", "vanchor", "sup", "sub", "lien", "langue",
         "nowrap begin", "resize", "smallcaps", "highlight", "strong", "em", "linktext", "font", "uppercase", "lowercase",
         "escyr", "esc year", "escyr2", "année", "annee"}
LAST = {"sort", "ordenar", "lang", "font color", "color", "colour", "transl", "transliteration", "tsort", "sortcorrect"}
LINES = {"smalldiv", "plainlist", "plain list", "flatlist", "ubl", "unbulleted list", "hlist", "collapsible list",
         "bulleted list", "blist", "div col", "columns-list", "col-list", "nowrap list", "unordered list", "liste"}
DATES = {"dts", "date", "start date", "end date", "start date and age", "fecha", "date-", "birth date", "release date",
         "date table sorting", "dtsort", "sort date", "start-date", "film date"}
SAY = {"won": "Won", "nom": "Nominated", "yes": "Yes", "y": "Yes", "won-small": "Won", "nom-small": "Nominated",
       "!": "|", "'": "'", "ndash": "–", "mdash": "—", "nbsp": " ", "snd": " – ", "spaced ndash": " – ", "dot": " · ",
       "·": " · ", "•": " · ", "pipe": "|", "=": "=", "-": "", "clear": ""}
NAMED = re.compile(r"^\s*[\w\- ]+\s*=")


def split_top(text, separator="|"):
    """Split on a separator that is not inside [[...]] or {{...}}."""
    parts, depth, start, index = [], 0, 0, 0
    while index < len(text):
        pair = text[index:index + 2]
        if pair in ("[[", "{{"):
            depth, index = depth + 1, index + 2
        elif pair in ("]]", "}}") and depth:
            depth, index = depth - 1, index + 2
        elif depth == 0 and text.startswith(separator, index):
            parts.append(text[start:index])
            index += len(separator)
            start = index
        else:
            index += 1
    parts.append(text[start:])
    return parts


def template_text(body):
    parts = split_top(body)
    name = parts[0].strip().lower().replace("_", " ")
    values = [p for p in parts[1:] if not NAMED.match(p)]
    named = dict(p.split("=", 1) for p in parts[1:] if NAMED.match(p))
    named = {k.strip().lower(): v for k, v in named.items()}
    if name in SAY:
        return SAY[name]
    if name == "sortname":
        return " ".join(expand(v).strip() for v in values[:2])
    if name == "lien":  # French Wikipedia's link to an untranslated article
        return expand(named.get("fr") or (values[0] if values else ""))
    if name.startswith("lang-") or name.startswith("lang|"):
        return expand(values[-1]) if values else ""
    if name in FIRST:
        return expand(values[0]) if values else ""
    if name in LAST:
        return expand(values[-1]) if values else ""
    if name in LINES:
        return "\n".join(expand(v).strip() for v in values)
    if name in DATES:
        return " ".join(expand(v).strip() for v in values)
    return ""


def expand(text):
    """Replace every template with the text it shows (or nothing, for notes and decorations)."""
    if "{{" not in text:
        return text
    out, index = [], 0
    while True:
        start = text.find("{{", index)
        if start < 0:
            out.append(text[index:])
            return "".join(out)
        out.append(text[index:start])
        depth, end = 0, start
        while end < len(text):
            if text.startswith("{{", end):
                depth, end = depth + 1, end + 2
            elif text.startswith("}}", end):
                depth, end = depth - 1, end + 2
                if depth == 0:
                    break
            else:
                end += 1
        out.append(template_text(text[start + 2:end - 2]))
        index = end


FILE_LINK = re.compile(r"\[\[(?:File|Image|Fichier|Archivo|Imagen|Datei):(?:[^\[\]]|\[\[[^\]]*\]\])*\]\]", re.I)
LINK = re.compile(r"\[\[([^\]|]*)(?:\|([^\]]*))?\]\]")
EXTERNAL = re.compile(r"\[(?:https?:)?//[^\s\]]+\s*([^\]]*)\]")
TAG = re.compile(r"<[^>]+>")
FOOTNOTE = re.compile(r"<sup[^>]*>.*?</sup>|(?<!\[)\[(?:[a-z0-9]{1,3}|(?:nb|note) ?\d+)\](?!\])", re.I | re.S)
MARKS = " \t\n*†‡§¶♦◊^¤♠♣✝✦★☆Δψ,;:–—-"


def plain(text, breaks=", "):
    """Wikitext to the words a reader sees."""
    text = FILE_LINK.sub("", text)
    text = FOOTNOTE.sub("", text)
    text = re.sub(r"<br\s*/?>", breaks, text, flags=re.I)
    text = TAG.sub("", text)
    text = LINK.sub(lambda m: m.group(2) if m.group(2) is not None else m.group(1).lstrip(":"), text)
    text = EXTERNAL.sub(r"\1", text)
    text = html.unescape(text.replace("'''", "").replace("''", ""))
    text = re.sub(r"\s+", " ", text)
    return text.strip(MARKS + " ").strip()


def link_target(raw):
    """The article a [[link]] points to, or None for files, categories and other wikis."""
    target = raw.split("#")[0].strip().replace("_", " ")
    if not target or target.startswith(":") or re.match(r"(?i)(file|image|category|categoría|catégorie|wikt|wiktionary|"
                                                       r"fichier|archivo|imagen|template|help|portal|wikipedia|w|en|es|fr|de|it|pt):", target):
        return None
    return target[0].upper() + target[1:]


def song_target(raw):
    """The article a song link points to. A link to a section ("[[Tainted Love#Soft Cell
    version|...]]") gives none: that article's item is the original song, not this recording,
    so the chart entry would be credited to the wrong performer."""
    return None if re.search(r"#\s*\S", raw) else link_target(raw)


# ----------------------------------------------------------------------------------------------
# Finding songs in a cell.

OPEN, CLOSE = "\"“«„", "\"”»“"
# A quoted title, linked or not, with links allowed inside the quotes: "[[Song]]", "[[Article|Song]]",
# « [[Chanson]] », "Song with no article", "[[Song]] (remix)".
QUOTED = re.compile(r"[%s]\s*((?:[^%s\n\[\]{}]|\[\[[^\]\n]*\]\])+?)\s*[%s]" % (OPEN, OPEN + CLOSE, CLOSE))
# The same, written with the quotes inside the link: [[Article|"Song"]].
QUOTED_LINK = re.compile(r"\[\[([^\]|]+)\|\s*[%s]([^\]\n]+?)[%s]\s*\]\]" % (OPEN, CLOSE))
FIRST_LINK = re.compile(r"\[\[([^\]|]+)(?:\|([^\]]*))?\]\]")
NOT_A_TITLE = re.compile(r"^(?:n/?a|none|—|–|-|tbd|tba|ninguno|ninguna|aucun|aucune|no number[- ]one.*|"
                         r"no (?:award|ceremony).*|not awarded|non attribué|desierto|vacant|\?)$", re.I)


def quoted_songs(content):
    """[(title, article)] for every quoted title in a stretch of wikitext."""
    content = QUOTED_LINK.sub(lambda m: '"[[%s|%s]]"' % (m.group(1), m.group(2)), content)
    content = FILE_LINK.sub("", TAG.sub(" ", re.sub(r"<br\s*/?>", " ", content, flags=re.I)))
    found = []
    for match in QUOTED.finditer(content):
        span = match.group(1)
        title = plain(span)
        if not title or NOT_A_TITLE.match(title) or len(title) > 150 or not re.search(r"\w", title):
            continue
        link = FIRST_LINK.search(span)
        if not link and len(title.split()) > 15:
            continue  # a quoted sentence, not a title (the longest listed titles run to 11 words)
        # A double A-side written inside one link: "[[Song|Song" / "Other side]]".
        for index, part in enumerate(re.split(r"[%s]\s*[/,&]\s*[%s]" % (CLOSE, OPEN), title)):
            if part.strip():
                found.append((part.strip(), song_target(link.group(1)) if link and index == 0 else None))
    return found


def cell_songs(content, quoted_only):
    """The songs a song-column cell names: its quoted titles, else its first link, else its text.
    With `quoted_only` an unquoted cell is an album or a speech and names no song."""
    found = quoted_songs(content)
    if found or quoted_only:
        return found
    bare = re.sub(r"<br\s*/?>", "\n", content, flags=re.I).strip()
    if not bare:
        return []
    link = FIRST_LINK.search(bare)
    if link and link_target(link.group(1)) and bare.startswith(("[[", "''[[", "'''[[", "'''''[[")):
        title = plain(link.group(2) if link.group(2) is not None else link.group(1))
        return [(title, song_target(link.group(1)))] if title and not NOT_A_TITLE.match(title) else []
    title = plain(bare.split("\n")[0])
    if not title or NOT_A_TITLE.match(title) or len(title) > 120 or not re.search(r"[^\W\d_]", title):
        return []
    return [(title, song_target(link.group(1)) if link else None)]


def cell_artist(content):
    """The performer written on the line under the title in the same cell:
    '"[[Song]]"<br><small>[[Singer]] and band</small>'. Empty when the next line is another title."""
    content = QUOTED_LINK.sub(lambda m: '"[[%s|%s]]"' % (m.group(1), m.group(2)), content)
    match = QUOTED.search(content)
    if not match:
        return ""
    rest = content[match.end():]
    head = re.match(r"\s*(?:</?\w+[^>]*>\s*)*<br\s*/?>", rest, re.I)
    if not head:
        return ""
    below = re.split(r"<br\s*/?>", rest[head.end():], flags=re.I)[0]
    if QUOTED.search(below):
        return ""
    text = plain(below)
    return text if re.search(r"[^\W\d_]", text) else ""


MONTH = re.compile(r"\b(?:january|february|march|april|may|june|july|august|september|october|november|december|enero|"
                   r"febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre|janvier|"
                   r"février|mars|avril|mai|juin|juillet|août|septembre|octobre|novembre|décembre|jan|feb|mar|apr|jun|jul|"
                   r"aug|sep|sept|oct|nov|dec)\b\.?", re.I)


def date_like(text):
    """A cell that is only a date ("January 7", "7 de enero", "14/02"): never a performer."""
    rest = re.sub(r"\b(?:de|del|of|the|er|st|nd|rd|th)\b|[\d\W_]", "", MONTH.sub("", text), flags=re.I)
    return bool(MONTH.search(text) or re.search(r"\d", text)) and not rest


def bullet_entries(content):
    """Nominees listed inside one cell: '* Writer – "Song" (Performer)', one per line."""
    entries = []
    for line in content.split("\n"):
        if not line.strip().startswith(("*", "#")):
            continue
        for title, article in quoted_songs(line)[:1]:
            after = re.search(r"[%s]\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)" % CLOSE, line)
            before = re.split(r"\s[–—-]\s", line.lstrip("*# "), maxsplit=1)
            artist = plain(after.group(1)) if after else (plain(before[0]) if len(before) > 1 else "")
            entries.append((title, article, artist))
    return entries


# ----------------------------------------------------------------------------------------------
# Tables.

YEAR = re.compile(r"(?<![\d/])(1[89]\d\d|20\d\d)(?![\d]|s\b|’s|'s)")
SONG_HEAD = re.compile(r"\b(songs?|singles?|titles?|record|recording|tracks?|work|nominated work|canci[oó]n(es)?|sencillos?|"
                       r"tema|t[ií]tulo|titres?|chansons?|morceau|single\(s\)|song\(s\)|title\(s\))\b", re.I)
NOT_SONG_HEAD = re.compile(r"label|album|artist|writer|producer|date|week|semaine|semana|ref|peak|sales|vent|certif|year|"
                           r"\baño|année|number of|times|discogr|intérprete|interprète|weeks|semaines|days|origin|language", re.I)
ARTIST_HEAD = re.compile(r"artist|performer|singer|interpr|cantante|artista|artiste|grupo|groupe|performed|recorded by|"
                         r"\bband\b|\bact\b|chanteu|int[ée]rpret", re.I)
WRITER_HEAD = re.compile(r"writer|composer|lyricist|compositor|autor|auteur|compositeur|letra|parolier|music by|lyrics by", re.I)
YEAR_HEAD = re.compile(r"^(years?|años?|ann[ée]es?|ceremony|c[ée]r[ée]monie|edici[oó]n|[ée]dition|ceremonia|releas|"
                       r"lanzamiento|sortie|year of|year released|recorded|inducted)", re.I)
DATE_HEAD = re.compile(r"date|week|issue|fecha|semaine|semana|reached|entry|entered", re.I)
NOT_DATE_HEAD = re.compile(YEAR_HEAD.pattern + r"|^weeks?\b|^semaines?\b|^semanas?\b|weeks (?:at|in|on)|number of|nombre de|n[uú]mero de", re.I)
RANK_HEAD = re.compile(r"^(no\.?|nº|n°|#|pos\.?|position|posici[oó]n|rank|ranking|rang|place|placing|lugar|puesto|peak|final$)\b", re.I)
FILM_HEAD = re.compile(r"\b(films?|movies?|motion picture|pel[ií]culas?)\b", re.I)
NOMINEE_HEAD = re.compile(r"nominee|nominad|nomm[ée]|finalist", re.I)
RESULT_HEAD = re.compile(r"^(result|resultado|r[ée]sultat|outcome|status)", re.I)
FORMAT_HEAD = re.compile(r"^(format|type|category|cat[ée]gorie|categor[ií]a)\b", re.I)
WINNER_STYLE = re.compile(r"faeb86|gold|ffd700|eedd82|f9e48b|ffe082|b0c4de", re.I)


def tables(body):
    """The tables in a stretch of wikitext, and the text around them."""
    found, outside, current, depth = [], [], [], 0
    for line in body.split("\n"):
        stripped = line.strip()
        if stripped.startswith("{|"):
            depth += 1
        if depth:
            current.append(line)
        else:
            outside.append(line)
        if stripped.startswith("|}") and depth:
            depth -= 1
            if depth == 0:
                found.append("\n".join(current))
                current = []
    if current:
        found.append("\n".join(current))
    return found, "\n".join(outside)


ATTRIBUTES_ONLY = re.compile(r"^\s*(?:(?:rowspan|colspan|style|class|align|valign|bgcolor|width|scope|data-sort-value)\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s|]+)\s*)+$", re.I)


def table_rows(table):
    """[(row attributes, [(kind, attributes, content)])], kind being "!" for a header cell."""
    rows, cells, attributes, nested = [], [], "", 0
    for line in table.split("\n")[1:]:
        stripped = line.strip()
        open_markup = cells and (cells[-1][2].count("{{") > cells[-1][2].count("}}") or
                                 cells[-1][2].count("[[") > cells[-1][2].count("]]"))
        if nested or open_markup:
            cells[-1][2] += "\n" + line
            nested += stripped.startswith("{|") - stripped.startswith("|}")
            continue
        if stripped.startswith("{|"):
            if cells:
                cells[-1][2] += "\n" + line
                nested = 1
            continue
        if stripped.startswith("|}"):
            break
        if stripped.startswith("|+"):
            continue
        if stripped.startswith("|-"):
            if cells:
                rows.append((attributes, cells))
            cells, attributes = [], stripped[2:]
            continue
        if stripped.startswith(("|", "!")):
            kind = stripped[0]
            for part in split_top(stripped[1:], "||"):
                for piece in (split_top(part, "!!") if kind == "!" else [part]):
                    attrs, content = split_attributes(piece)
                    if attrs and "=" not in attrs and attrs.strip():
                        attrs, content = "", piece  # a bare pipe in the text, not attributes
                    if not attrs and ATTRIBUTES_ONLY.match(content):
                        attrs, content = content, ""  # its text came from a template, now expanded away
                    cells.append([kind, attrs, content.strip()])
        elif cells:
            cells[-1][2] += "\n" + line
    if cells:
        rows.append((attributes, cells))
    return rows


def span(attributes, name):
    match = re.search(name + r"\s*=\s*[\"']?\s*(\d+)", attributes, re.I)
    return max(1, min(int(match.group(1)), 400)) if match else 1


def grid(rows):
    """Rows with rowspans and colspans spread out: each row lists its cells column by column, a
    cell spanning several rows or columns appearing in each of them (the same object)."""
    out, carry = [], {}
    for attributes, cells in rows:
        line, queue, column = [], list(cells), 0
        while True:
            if column in carry:
                left, cell = carry[column]
                line.append(cell)
                if left <= 1:
                    del carry[column]
                else:
                    carry[column] = (left - 1, cell)
                column += 1
            elif queue:
                cell = tuple(queue.pop(0))
                down, across = span(cell[1], "rowspan"), span(cell[1], "colspan")
                for _ in range(min(across, 30)):
                    line.append(cell)
                    if down > 1:
                        carry[column] = (down - 1, cell)
                    column += 1
            elif any(c > column for c in carry):
                line.append(None)
                column += 1
            else:
                break
        out.append((attributes, line))
    return out


def is_header(attributes, line):
    cells = [c for c in line if c]
    return bool(cells) and all(c[0] == "!" for c in cells) and not any(re.search(r"scope\s*=\s*\"?row", c[1]) for c in cells)


def spanning(line):
    """A row that is one cell across the whole table: a divider such as "Singles from 1984"."""
    cells = [c for c in line if c]
    return len(line) > 1 and len(set(map(id, cells))) == 1


def nearest(column, candidates, groups):
    if not candidates:
        return None
    same = [c for c in candidates if groups[c] and groups[c] == groups[column]]
    pool = same or [c for c in candidates if not groups[c]] or candidates
    return min(pool, key=lambda c: (abs(c - column), c < column))


def read_table(table, spec):
    """Every song a table names: dicts of title, article, artist, year, rank, winner, film, group."""
    expanded = grid(table_rows(table))
    headers = []
    while expanded and is_header(*expanded[0]) and not spanning(expanded[0][1]):
        headers.append(expanded.pop(0)[1])
    width = max([len(line) for _, line in expanded] + [len(h) for h in headers] + [0])
    names, groups = [], []
    for column in range(width):
        texts = [h[column] if column < len(h) else None for h in headers]
        last = texts[-1] if texts else None
        names.append(plain(last[2]).lower() if last else "")
        top = texts[0] if len(texts) > 1 else None
        groups.append(plain(top[2]).lower() if top and top is not last else "")

    def columns(pattern, exclude=None):
        return [c for c, n in enumerate(names) if n and pattern.search(n) and not (exclude and exclude.search(n))]

    song_columns = columns(SONG_HEAD, NOT_SONG_HEAD)
    artist_columns = columns(ARTIST_HEAD, WRITER_HEAD)
    writer_columns = columns(WRITER_HEAD) or columns(NOMINEE_HEAD)
    year_columns = columns(YEAR_HEAD)
    date_columns = columns(DATE_HEAD, NOT_DATE_HEAD)
    rank_columns = columns(RANK_HEAD, DATE_HEAD)
    film_columns = columns(FILM_HEAD, re.compile(r"song|single|title", re.I))
    nominee_columns = columns(NOMINEE_HEAD)
    result_columns = columns(RESULT_HEAD)
    format_columns = columns(FORMAT_HEAD)
    if spec["film"] and not film_columns:
        film_columns = columns(re.compile(r"\b(picture|from)\b", re.I), re.compile(r"song|single|title", re.I))

    def value(line, column):
        return line[column][2] if column is not None and column < len(line) and line[column] else ""

    found = []
    year_here = None
    for attributes, line in expanded:
        cells = [c for c in line if c]
        if not cells:
            continue
        if spanning(line) or is_header(attributes, line):
            # A row of one cell across the table, or a repeated header: a divider, often "1985".
            years = YEAR.findall(plain(cells[0][2]))
            if len(set(years)) == 1:
                year_here = int(years[0])
            continue
        year_cell = next((value(line, c) for c in year_columns if YEAR.search(plain(value(line, c)))), "")
        row_year = int(YEAR.search(plain(year_cell)).group(1)) if year_cell else None
        if row_year is None and not headers:  # no headers: a year standing alone in a leading cell
            for cell in cells[:2]:
                text = plain(cell[2])
                if re.fullmatch(r"\D{0,30}(1[89]\d\d|20\d\d)\D{0,30}", text) and not quoted_songs(cell[2]):
                    row_year = int(YEAR.search(text).group(1))
                    break
        result = " ".join(plain(value(line, c)).lower() for c in result_columns)
        formats = " ".join(plain(value(line, c)).lower() for c in format_columns)
        if re.search(r"\balbum\b|\bálbum\b|\bLP\b", formats, re.I) and not re.search(r"single|song", formats, re.I):
            continue
        films = []
        for c in film_columns[:1]:
            for match in FIRST_LINK.finditer(value(line, c)):
                target = link_target(match.group(1))
                if target:
                    films.append((plain(match.group(2) or match.group(1)), target))
                    break

        targets = song_columns if song_columns else []
        entries = []
        for order, column in enumerate(targets):
            if order > 0 and not spec["others"]:
                break
            group = 0 if order == 0 else 1
            if order > 0 and groups[column] and groups[column] == groups[targets[0]]:
                continue  # a second song column in the same chart (a double A-side split in two)
            content = value(line, column)
            if not content:
                continue
            # No performer column (the Oscar lists its songwriters): the writers stand in.
            artist_column = nearest(column, artist_columns or writer_columns, groups)
            date_column = nearest(column, date_columns, groups)
            rank_column = nearest(column, rank_columns, groups)
            cell = line[column]
            for title, article in cell_songs(content, spec["quoted"]):
                bold = "'''" in content
                styled = bool(WINNER_STYLE.search(attributes + " " + cell[1]))
                entries.append({"title": title, "article": article,
                                "artist": plain(value(line, artist_column)) or cell_artist(content),
                                "date": plain(value(line, date_column)), "rank": plain(value(line, rank_column)),
                                "group": group, "signal": True if (bold or styled or "won" in result or "winner" in result
                                                                   or "ganador" in result or "lauréat" in result) else
                                                          False if "nominat" in result or "nomin" in result else None})
        if not song_columns:
            # No column says "song": the first cell holding a quoted title (every such cell where
            # the columns are charts side by side, as on the pre-1958 Billboard pages). The
            # performer is the line under the title in the same cell, else, when the row names
            # only one song, a neighbouring cell that is not a date.
            holding = []
            for cell in line:
                if not cell or any(cell is seen for seen in holding):
                    continue
                if cell[0] == "!" and YEAR.search(plain(cell[2])) and not quoted_songs(cell[2]):
                    continue
                if quoted_songs(cell[2]):
                    holding.append(cell)
            for order, cell in enumerate(holding):
                if order > 0 and not spec["others"]:
                    break
                neighbour = None
                if len(holding) == 1:
                    index = next(i for i, c in enumerate(line) if c is cell)
                    neighbour = next((c for c in line[index + 1:] + line[:index][::-1] if c and c is not cell and not quoted_songs(c[2])
                                      and re.search(r"[^\W\d_]", plain(c[2])) and not YEAR.search(plain(c[2]))
                                      and not date_like(plain(c[2]))), None)
                artist = cell_artist(cell[2]) or (plain(neighbour[2]) if neighbour else "")
                for title, article in quoted_songs(cell[2])[:3]:
                    entries.append({"title": title, "article": article, "artist": artist, "date": "", "rank": "",
                                    "group": 0 if order == 0 else 1,
                                    "signal": True if "'''" in cell[2] or WINNER_STYLE.search(attributes + " " + cell[1]) else None})
        for column in nominee_columns:
            for title, article, artist in bullet_entries(value(line, column)):
                entries.append({"title": title, "article": article, "artist": artist, "date": "", "rank": "",
                                "group": 0, "signal": False, "nominee_column": True})
        for entry in entries:
            entry["year"] = row_year
            entry["divider_year"] = year_here
            entry["films"] = films
            found.append(entry)
    # Winners. Where a column lists the nominated songs, the song in the main column won. Else, if
    # anything is marked as a winner (bold, gold, "won"), the unmarked rest were nominated; a
    # table with no marks at all lists winners only.
    listed = any(e["signal"] is False and e.get("nominee_column") for e in found)
    marked = any(e["signal"] is True for e in found)
    for entry in found:
        entry["winner"] = entry["signal"] is True or (entry["signal"] is None and (listed or not marked))
    return found


ITALIC_TITLE = re.compile(r"''\[\[([^\]|]+)(?:\|([^\]]*))?\]\]''")
# "(interprète : X)", "(writer/composer/performer: X - lyrics: Y)", "(sung by X)".
PERFORMED_BY = re.compile(r"(?:interpr[èe]t\w*(?:/\w+)*\s*:|\bperformers?(?:/\w+)*\s*:|\b(?:sung|performed) by)\s*(.+?)\s*"
                          r"(?:\s[-–]\s|\(|\)|$)", re.I)
BY = re.compile(r"^\s*(?:\bby\b|\bde\b|d['’]|\bpor\b|\bpar\b|[–—-])\s*(.+?)\s*(?:\(|$)", re.I)


def read_lines(text, italic):
    """Songs in bulleted or numbered lines: '* "[[Song]]" – Artist (1956)', or on French
    Wikipedia '* 1985 : ''[[Chanson]]'' (interprète : X)' with the title in italics."""
    found = []
    for line in text.split("\n"):
        if not line.strip().startswith(("*", "#")):
            continue
        line = QUOTED_LINK.sub(lambda m: '"[[%s|%s]]"' % (m.group(1), m.group(2)), line)
        quoted = QUOTED.search(line)
        songs = quoted_songs(line[:quoted.end()]) if quoted else []
        if songs:
            (title, article), end = songs[0], quoted.end()
        elif italic and ITALIC_TITLE.search(line):
            match = ITALIC_TITLE.search(line)
            title, article, end = plain(match.group(2) or match.group(1)), song_target(match.group(1)), match.end()
        else:
            continue
        rest = plain(line[end:])
        named = PERFORMED_BY.search(rest) or BY.search(rest)
        before = re.split(r"\s[–—-]\s|:\s", line[:end].lstrip("*# "), maxsplit=1)
        artist = named.group(1).strip() if named else (plain(before[0]) if len(before) > 1 and not YEAR.fullmatch(plain(before[0])) else "")
        years = YEAR.findall(plain(line[:end])) or YEAR.findall(rest)
        found.append({"title": title, "article": article, "artist": artist, "date": "", "rank": "", "group": 0,
                      "signal": None, "winner": True, "year": int(years[0]) if years else None, "divider_year": None,
                      "films": []})
    return found


HEADING = re.compile(r"^(={2,6})\s*(.+?)\s*\1\s*$", re.M)
SKIP_SECTION = re.compile(r"album|by artist|artists? with|number[- ]one artists|by record label|record label|most weeks|"
                          r"longest|statistic|best[- ]?sell|bestsell|best sales|meilleures ventes|ventes|see also|references|"
                          r"^notes?$|footnotes|external links|further reading|bibliography|sources|million|platinum|certif|"
                          r"milestone|achievement|superlative|most wins|most nominations|youngest|oldest|multiple|"
                          r"winners of other|trivia|véase también|referencias|enlaces externos|^notas$|voir aussi|"
                          r"références|liens externes|artistas|artistes|por artista|par artiste|álbum|records? and|"
                          r"by (?:decade|songwriter|producer|label|country)|semi-final|withdrawn|did not|non-qualif|"
                          r"^background$|chart debuts|multiple entries|^entries by|^key$|legend|eligibility|performances|"
                          r"shortlist|finalists|submitted|submissions|preselect|^records$|foreign-language|criteria|"
                          r"related involvement|conductors|heads of delegation|jury|commentators|spokespersons|"
                          r"stage directors|costume|gallery|^hostings$", re.I)


def sections(text):
    """[(headings, body)]: the body of each section with the headings above it."""
    found, path, last = [], [], 0
    for match in HEADING.finditer(text):
        found.append((list(path), text[last:match.start()]))
        level = len(match.group(1))
        path = [(lvl, name) for lvl, name in path if lvl < level] + [(level, plain(expand(match.group(2))))]
        last = match.end()
    found.append((list(path), text[last:]))
    return [([name for _, name in path], body) for path, body in found]


def page_year(title):
    years = YEAR.findall(title)
    return int(years[0]) if years else None


def read_page(spec, text):
    """Canon rows for one page."""
    rows = []
    title_year = page_year(spec["resolved"])
    fixed_year = spec["kind"] in ("yearend", "topten")
    for headings, body in sections(text):
        skip = SKIP_SECTION
        if spec["kind"] == "list" and "best-selling" in spec["title"].lower():
            skip = re.compile(SKIP_SECTION.pattern.replace(r"best[- ]?sell|bestsell|", ""), re.I)
        if any(skip.search(h) for h in headings):
            continue
        if spec.get("within") and not any(re.search(spec["within"], h, re.I) for h in headings):
            continue
        heading_years = [int(y) for h in headings for y in YEAR.findall(h)]
        section_year = heading_years[-1] if heading_years else None
        body = expand(body)
        found_tables, outside = tables(body)
        entries = []
        for table in found_tables:
            entries += read_table(table, spec)
        if spec["lines"]:
            entries += read_lines(outside, italic=spec["site"] == "fr")
        for entry in entries:
            if entry["group"] > 0 and not spec["others"]:
                continue
            label = spec["label"] if entry["group"] == 0 or spec["others"] == "same" else spec["others"]
            if spec["kind"] == "award" and not entry["winner"]:
                label += " nominee"
            date_years = YEAR.findall(entry["date"])
            if fixed_year:
                year = title_year or section_year or entry["year"]
            else:
                year = (entry["year"] or (int(date_years[-1]) if date_years else None) or entry["divider_year"]
                        or section_year or (title_year if spec["kind"] != "list" else None))
            rank = None
            if spec["kind"] in ("yearend", "topten", "list"):
                number = re.match(r"\D{0,3}(\d{1,3})\b", entry["rank"])
                rank = int(number.group(1)) if number else None
            rows.append({"title": entry["title"], "article": entry["article"], "artist": entry["artist"][:200],
                         "year": year, "label": label, "rank": rank, "films": entry["films"]})
    return rows


# ----------------------------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--limit", type=int, default=0, help="dry run: read only the first N pages (after --only)")
    parser.add_argument("--only", default="", help="only pages whose title matches this regular expression")
    parser.add_argument("--sites", default="en,es,fr", help="which Wikipedias to read, from en,es,fr")
    parser.add_argument("--no-discover", action="store_true", help="skip the pages found by category and prefix (R&B, rap, Hall of Fame, Spanish lists)")
    parser.add_argument("--no-ids", action="store_true", help="do not resolve songs to Wikidata ids (qid stays null)")
    parser.add_argument("--out", help="default songs/song_canon.json, or song_canon.partial.json for a dry run")
    parser.add_argument("--relations-out", help="default songs/relations_song_lists.json (none is written by a dry run)")
    args = parser.parse_args()
    sites = set(args.sites.split(","))
    # Anything short of the whole crawl with ids is partial and never overwrites the real canon.
    partial = bool(args.limit or args.only or args.no_discover or args.no_ids or set(args.sites.split(",")) != set(SITES))
    out_path = args.out or str(SONGS / ("song_canon.partial.json" if partial else "song_canon.json"))
    relations_path = args.relations_out or (None if partial else str(SONGS / "relations_song_lists.json"))

    specs = us_pages() + latin_pages() + french_pages()
    if not args.no_discover:
        specs += discovered_pages()
    specs = [s for s in specs if s["site"] in sites and (not args.only or re.search(args.only, s["title"]))]

    # Which of the candidate titles exist, and where their redirects lead; each article once.
    # Under --limit the check stops once enough pages are found, so a dry run asks little.
    chosen, seen = [], set()
    for site in SITES:
        for spec in specs:
            if spec["site"] == site and spec["known"] and (site, spec["title"]) not in seen and not (args.limit and len(chosen) >= args.limit):
                seen.add((site, spec["title"]))
                chosen.append({**spec, "resolved": spec["title"]})
        wanted = [s for s in specs if s["site"] == site and not s["known"]]
        step = 50 if not args.limit else max(1, args.limit)
        for start in range(0, len(wanted), step):
            if args.limit and len(chosen) >= args.limit:
                break
            batch = wanted[start:start + step]
            resolved = existing(site, list(dict.fromkeys(s["title"] for s in batch)))
            for spec in batch:
                target = resolved.get(spec["title"])
                if target and (site, target) not in seen and not (args.limit and len(chosen) >= args.limit):
                    seen.add((site, target))
                    chosen.append({**spec, "resolved": target})
    log("pages to read:", len(chosen), dict(Counter(s["site"] for s in chosen)))

    rows = []
    for number, spec in enumerate(chosen):
        text = wikitext(spec["site"], spec["resolved"])
        try:
            found = read_page(spec, text) if text else []
        except Exception as error:  # one odd page must not stop the crawl
            log("  could not read", spec["site"], spec["resolved"], repr(error)[:120])
            found = []
        for row in found:
            rows.append({**row, "culture": spec["culture"], "page": spec["resolved"], "site": spec["site"]})
        if not found:
            log("  nothing read from", spec["site"], spec["resolved"])
        if number % 25 == 0:
            log("page", number, "/", len(chosen), spec["resolved"], len(found))

    # One row per song per page and label: weeks at number one and carried rowspans repeat it.
    merged = {}
    for row in rows:
        key = (row["site"], row["page"], row["label"], row["title"].lower(), row["artist"].lower())
        if key not in merged:
            merged[key] = row
        else:
            kept = merged[key]
            if row["year"] and (not kept["year"] or row["year"] < kept["year"]):
                kept["year"] = row["year"]
            if row["rank"] and (not kept["rank"] or row["rank"] < kept["rank"]):
                kept["rank"] = row["rank"]
            kept["films"] = kept["films"] or row["films"]
    # A row with no performer (a chart of compositions beside one of records) folds into the row
    # on the same page that names one.
    named = {}
    for row in merged.values():
        if row["artist"]:
            named.setdefault((row["site"], row["page"], row["label"], row["title"].lower()), row)
    rows = []
    for row in merged.values():
        twin = None if row["artist"] else named.get((row["site"], row["page"], row["label"], row["title"].lower()))
        if twin is None:
            rows.append(row)
        elif not twin["article"]:
            twin["article"] = row["article"]
    for row in rows:
        if row["article"] and not id_worth_asking(row["title"], row["article"]):
            row["article"] = None  # an album, a band, or another recording's article: no id

    ids = {}
    if not args.no_ids:
        for site in SITES:
            titles = sorted({r["article"] for r in rows if r["site"] == site and r["article"]} |
                            {f for r in rows if r["site"] == site for _, f in r["films"]})
            if titles:
                log("resolving", len(titles), "titles on", site)
                ids[site] = wikidata_ids(site, titles)

    canon, relations = [], []
    for row in rows:
        qid = song_id(ids.get(row["site"], {}).get(row["article"])) if row["article"] else None
        canon.append({"title": row["title"], "artist": row["artist"], "year": row["year"], "culture": row["culture"],
                      "label": row["label"], "rank": row["rank"], "qid": qid, "page": row["page"], "site": row["site"]})
        for film_title, film_article in row["films"][:1]:
            film_qid = (ids.get(row["site"], {}).get(film_article) or (None,))[0]
            if film_qid and film_qid != qid:
                relations.append({"a": {"title": row["title"], "artist": row["artist"], "qid": qid, "culture": row["culture"], "year": row["year"]},
                                  "b": {"title": film_title, "artist": "", "qid": film_qid, "culture": row["culture"], "year": row["year"]},
                                  "forward": "written for", "backward": "song from", "strength": 0.9, "source": "w", "page": row["page"]})

    SONGS.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as out:
        json.dump(canon, out, ensure_ascii=False)
    if relations_path and not args.no_ids:
        with open(relations_path, "w") as out:
            json.dump(relations, out, ensure_ascii=False)
    resolved = sum(1 for row in canon if row["qid"])
    log("canon rows:", len(canon), " with a Wikidata id:", resolved, " distinct ids:", len({r["qid"] for r in canon if r["qid"]}),
        " song-film links:", len(relations), " ->", out_path, "(partial)" if partial else "")
    for label, count in Counter(row["label"] for row in canon).most_common():
        log("  ", label, count)


if __name__ == "__main__":
    main()
