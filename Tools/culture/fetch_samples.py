#!/usr/bin/env python3
"""Songs step: which songs sample, interpolate, borrow from or translate which, from Wikipedia.

  1. Sample credits on English Wikipedia album and song pages, the ones with an album or song
     infobox: '"Track" contains samples of "Song", written by A, as performed by B', and the same
     for interpolations and "elements".
  2. Disputes: the table of 'List of songs subject to plagiarism disputes' (strength from what
     the Result column says) and the lead and dispute sections of the articles in
     'Category:Songs involved in plagiarism controversies'.
  3. Indian film music borrowing, both ways: sections of 'Indian film music' and 'Hindi film
     music', and of the articles on nine composers.
  4. Other-language versions: French adaptations on French Wikipedia ("adaptation française",
     "version française", "reprise en français") and Spanish ones on Spanish Wikipedia
     ("versión en español").

Disputes and borrowing are allegations, so their links read "inspired by", never "plagiarised".
Only facts are kept: titles, artists, years and Wikidata ids. No lyrics and no article text.

    fetch_samples.py                          everything
    fetch_samples.py --parts samples,fr       some of it (samples, disputes, india, fr, es): a dry run
    fetch_samples.py --limit 20 --resolve 1   dry run: 20 pages per search, 1 id lookup per wiki
    fetch_samples.py --merge                  only rebuild relations_songs.json from the parts

Writes songs/relations_wiki.json (schema 6 of the song plan) and songs/relations_songs.json, the
concatenation of every songs/relations_*.json part (this one, fetch_itwofs's, load_musicbrainz's).
A partial run (--limit, or only some --parts) writes songs/dryrun_relations_wiki.json instead, so
it never replaces the full file; build_songs reads only relations_*.json.
"""
import argparse
import json
import re
from collections import defaultdict

from common import DATA, log, wiki_api
from fetch_lists import rowspan, table_rows, wikitext

SONGS = DATA / "songs"
OUT = SONGS / "relations_wiki.json"
DRY_RUN = SONGS / "dryrun_relations_wiki.json"
MERGED = SONGS / "relations_songs.json"
SITES = {"en": "en.wikipedia.org", "fr": "fr.wikipedia.org", "es": "es.wikipedia.org"}
PARTS = ("samples", "disputes", "india", "fr", "es")

# 1. One search per phrase and infobox: each stays well under the 10,000-result ceiling.
SAMPLE_PHRASES = ['"contains samples"', '"contains a sample"', '"contains an interpolation"',
                  '"contains interpolations"', '"contains elements"']
SAMPLE_BOXES = ["Infobox album", "Infobox song"]
# 2.
DISPUTE_LIST = "List of songs subject to plagiarism disputes"
DISPUTE_CATEGORY = "Category:Songs involved in plagiarism controversies"
# 3. Article -> the sections to read (None: every section whose heading is about borrowing).
INDIAN_PAGES = {
    "Indian film music": ["Accusations of plagiarism"], "Hindi film music": ["Unauthorised contrafacta", "Cultural impact"],
    "Pritam": None, "Anu Malik": None, "Bappi Lahiri": None, "R. D. Burman": None, "Laxmikant–Pyarelal": None,
    "Rajesh Roshan": None, "Nadeem–Shravan": None, "Sanjeev–Darshan": None, "Viju Shah": None,
}
BORROWING_HEADING = re.compile(r"plagiar|controvers|cop(?:y|ied|ying)|inspir|lift|allegation|critic|borrow|legal|lawsuit|"
                               r"infring|legacy|influence|sampl|remix|popular culture", re.I)
# The sections of a song article in the plagiarism category that tell the dispute, leaving out a
# section about another song ('"Hello, I Love You" controversies'), where "the song" is not the page's.
DISPUTE_HEADING = re.compile(r"^(?!.*[\"«])(?=.*(?:plagiar|controvers|lawsuit|legal|copyright|infring|allegation|accusation|"
                             r"dispute|similarit|litigation|court))", re.I)
# 4. (search phrase, infobox the page must carry). Pages are songs or albums (track lists).
ADAPTATIONS = {
    "fr": [(phrase, "Infobox Musique (œuvre)") for phrase in ('"adaptation française"', '"version française"', '"reprise en français"')],
    "es": [('"versión en español"', box) for box in ("Ficha de sencillo", "Ficha de canción", "Ficha de álbum")],
}
ADAPTATION_PHRASE = {
    "fr": re.compile(r"\b(?:adaptation|version|reprise)s?\s+(?:fran[cç]aises?|en\s+fran[cç]ais)|\badapt[ée]+e?s?\s+en\s+fran[cç]ais", re.I),
    "es": re.compile(r"\bversi[oó]n(?:es)?\s+en\s+(?:espa[nñ]ol|castellano)|\badaptaci[oó]n\s+(?:al|en)\s+(?:espa[nñ]ol|castellano)", re.I),
}

# Where an artist comes from, by the adjective in front of the name. Pakistani music sits with
# India, as in build_songs.COUNTRY_CULTURE; "xx" is from outside the four cultures.
NATIONALITY = {
    "us": "American British English Scottish Welsh Irish Canadian Australian Jamaican Barbadian Trinidadian",
    "in": "Indian Bollywood Hindi Bangla Bengali Tamil Telugu Kannada Malayalam Marathi Gujarati Pakistani Punjabi Urdu",
    "es": "Spanish Mexican Cuban Colombian Argentine Argentinian Chilean Peruvian Venezuelan Dominican Uruguayan Latin Latino Catalan",
    "fr": "French Québécois Quebecois",
    "xx": "Turkish Egyptian Lebanese Arabic Arab Algerian Moroccan Tunisian Indonesian Thai Israeli Iranian Persian Greek "
          "Russian Chinese Japanese Korean Malaysian Bangladeshi Nepali Nepalese African Nigerian Guinean Senegalese "
          "Malian Congolese German Italian Dutch Swedish Norwegian Danish Finnish Polish Hungarian Romanian Czech Serbian "
          "Bulgarian Albanian Armenian Kurdish Afghan Uzbek Brazilian Portuguese Filipino Vietnamese Ukrainian Icelandic "
          "Austrian Kazakh Azerbaijani Pashto Middle-Eastern Tanzanian Kenyan Ethiopian Ghanaian Cameroonian Ivorian "
          "Zimbabwean Ugandan Sudanese Somali Haitian Syrian Iraqi Jordanian Palestinian Saudi Afghani Tajik Mongolian "
          "Burmese Singaporean Croatian Georgian Belarusian",
}
CULTURE_OF = {word.lower(): culture for culture, words in NATIONALITY.items() for word in words.split()}
CULTURE_OF.update({"middle eastern": "xx", "puerto rican": "es", "sri lankan": "xx", "south african": "xx", "new zealand": "us"})
NATION = r"(?:Middle Eastern|Puerto Rican|Sri Lankan|South African|New Zealand|%s)" % "|".join(
    sorted((w for words in NATIONALITY.values() for w in words.split()), key=len, reverse=True))
# The same on French and Spanish Wikipedia, by word stem.
NATION_STEMS = {
    "fr": [(r"am[ée]ricain|britannique|anglais|[ée]cossais|irlandais|gallois|australien|n[ée]o-z[ée]landais|jama[iï]ca", "us"),
           (r"fran[cç]ais|qu[ée]b[ée]cois", "fr"),
           (r"espagnol|mexicain|cubain|colombien|argentin|portoricain|chilien|v[ée]n[ée]zu[ée]lien|dominicain|p[ée]ruvien", "es"),
           (r"indien|pakistanais", "in")],
    "es": [(r"estadounidense|brit[aá]nic|ingl[eé]s|escoc[eé]s|irland[eé]s|gal[eé]s|galesa|australian|neozeland|canadiense|jamaiquin", "us"),
           (r"franc[eé]s|quebequ", "fr"),
           (r"espa[nñ]ol|mexican|cuban|colombian|argentin|puertorrique[nñ]|chilen|venezolan|dominican|peruan|uruguay", "es"),
           (r"\bindi[oa]\b|hind[uú]|pakistan", "in")],
}
# A lead's translation gloss names a language, not where the song is from: "«Total Eclipse of the
# Heart» (en español: «Eclipse total del corazón»)", "—en español: «No tengo nada»—", "connu en
# français sous le titre ...".
GLOSS = re.compile(r"\([^()]*\)|—[^—]*—|\ben\s+(?:espa[nñ]ol|castellano|fran[cç]ais)\b", re.I)

QUOTE_MARKS = str.maketrans({"“": '"', "”": '"', "„": '"', "‘": "'", "’": "'"})
# References, comments, and block quotations and poems, which can hold lines of a song.
NOISE = re.compile(r"<ref[^>]*/>|<ref[^>]*>.*?</ref>|<!--.*?-->|<blockquote[^>]*>.*?</blockquote>|<poem[^>]*>.*?</poem>", re.S | re.I)
# Quotation templates (English, French and Spanish), dropped whole for the same reason.
QUOTE_TEMPLATE = re.compile(r"\{\{\s*(?:quote|blockquote|cquote|rquote|quote box|quotation|poem ?quote|lyrics?|cita|citation(?: bloc)?|"
                            r"bloc citation)\s*[|}]", re.I)
LINK = re.compile(r"\[\[([^\]|#]*)(?:#[^\]|]*)?(?:\|([^\]]*))?\]\]")
YEAR = re.compile(r"\b(1[89]\d\d|20[0-3]\d)\b")
# A full stop that ends a sentence or a name, not the one in "R. Kelly", "B.I.G." or "Jr.".
NOT_INITIAL = r"(?<![\s.][A-Z])(?<!^[A-Z])(?<!Jr)(?<!Sr)(?<!St)(?<!Dr)(?<!Mr)(?<!Ms)(?<!vs)(?<!No)(?<!feat)"
FULL_STOP = NOT_INITIAL + r"\.(?:\s|$)"
SENTENCE = re.compile(r"(?<=[.!?])(?<![\s.][A-Z]\.)(?<!Jr\.)(?<!Sr\.)(?<!St\.)(?<!Dr\.)(?<!Mr\.)(?<!Ms\.)(?<!vs\.)(?<!No\.)"
                      r"\s+(?=[A-Z\"'«\[¿¡])")
# A quoted title, in any of the marks the three wikis use for songs. A title has no space just
# inside its quotes, so a stray inch mark (a 12" single) does not pair the wrong quotes and
# take the prose between two titles for one.
QUOTED = re.compile(r'"(?!\s)([^"\n]{1,160}?)(?<!\s)"')
ITALIC = re.compile(r"''(?!')(.{1,160}?)(?<!')''(?!')")
GUILLEMET = re.compile(r"«\s*([^»\n]{1,160}?)\s*»")
# Words that introduce a quoted lyric line rather than a song title ("the hook", "she sings",
# "qui commence par"); what follows them is never kept. Lower case only, so the words of a title
# just before ("Simon Says" and "...", "Blurred Lines" and "...") are not taken for one.
LYRIC_CUE = re.compile(r"\b(?:lines?|lyrics?|hook|chorus|refrain|verse|phrase|words|catchphrase|slogan|mukhda|antara|"
                       r"paroles?|vers|couplet|strophe|estribillo|estrofa|coro|letra|frase|"
                       r"says|said|saying|sings|sang|singing|chant(?:s|ed|ing)?|shout(?:s|ed|ing)?|exclaim(?:s|ed|ing)?|"
                       r"dice|dicen|diciendo|canta|dit|disant|chante|"
                       r"(?:starts|starting|begins|beginning|opens|opening)\s+with|commen[cç]\w*\s+par|(?:empieza|comienza)\s+con)"
                       r"\b(?:\W+\w+){0,2}\W*$")
NAME = r"[A-Z][\w.\-]*(?:(?:\s+|\s*/\s*)(?:[A-Z][\w.\-]*|ul|al|el|de|da|bin|ibn|van|von|of|the|and|&|n'))*"
NOT_SONG = re.compile(r"\b(?:album|EP|mixtape|compilation|soundtrack|film|band|group|duo|trio|singer|rapper|musician|producer|"
                      r"songwriter|composer|actor|actress|television|novel|book|video game|record label|company|"
                      r"groupe|chanteu|rappeu|musicien|compositeu|bande originale|cantante|grupo|banda|película|álbum|recopilatorio)", re.I)
SONGISH = re.compile(r"\b(?:song|single|composition|instrumental|track|standard|anthem|hymn|aria|ballad|jingle|carol|"
                     r"chanson|titre|morceau|hymne|canción|cancion|sencillo|tema|himno|composición)\b", re.I)

# 1. Sample credits. Tracks with names like these say nothing on their own.
GENERIC_TRACK = re.compile(r"^(?:intro|outro|interlude|skit|prelude|untitled|hidden track|bonus track)\b", re.I)
CREDIT = re.compile(r"\bcontain(?:s|ed|ing)?\s+(?:(?:an?|additional|uncredited|re-?played|re-?sung|re-?recorded|vocal|brief|"
                    r"some|several|various|two|three|multiple|the)\s+)*?(samples?|interpolations?|elements|portions?|excerpts?)\s+(?:of|from)\b", re.I)
CREDIT_PART = re.compile(r"\b(samples?|interpolations?|elements|portions?|excerpts?)\s+(?:of|from)\b", re.I)
PERFORMER = re.compile(r"\b(?:originally |as )?(?:performed|recorded|sung|produced and performed|performed and produced)\s+by\s+(.+?)"
                       r"(?=\s*[;(]|%s|,\s*(?:and|which|from|on|as|written|courtesy|under|used|both)\b|\s+(?:from|on|courtesy|under|in)\s+|$)" % FULL_STOP, re.I)
WRITER = re.compile(r"\b(?:written|composed|written and produced|written and performed|written and composed)\s+by\s+(.+?)"
                    r"(?=\s*[;(]|%s|,\s*(?:as|and as|and performed|performed|which|from|courtesy|and)\b|\s+(?:as|from|courtesy)\s+|$)" % FULL_STOP, re.I)
BY_NAME = re.compile(r"^\W*(?:\(\d{4}\)\W*)?(?:sung |performed |recorded |composed )?by\s+(.+?)(?=\s*[;(:]|%s|,|\"|"
                     r"\s+(?:from|in|on|and the|which|who|that|was|were|is|are|has|had|for|to|as)\b|$)" % FULL_STOP, re.I)
SELF = re.compile(r"\b(?:the song|the track|the single|this song|the record|the tune|the instrumental|the remix|its (?:chorus|beat|"
                  r"hook|instrumental|production|melody|music))\b|^\W*(?:it|which)\b", re.I)
# 2. What a dispute's Result says: lost or settled, or dismissed.
LOST = re.compile(r"(?<!not )(?<!never )(?<!un)settle|royalt|\bcredit|\$|£|€|%|damages|awarded|liable|infringed|guilty|"
                  r"reissued|without permission|prohibited|confiscated|compensat|paid|agreed|undisclosed|amount|\bsum\b|"
                  r"ownership|share|owed|\bwon\b", re.I)
DISMISSED = re.compile(r"dismiss|cleared|not liable|no infringement|did not infringe|overturned|rejected|dropped|withdr[ae]w|"
                       r"never took|decided in (?:their|the defendants?'?) favou?r", re.I)
# 3. Borrowing in prose: (pattern, which title comes first, relation). "derived" means the
# borrowing song is named before the verb ("X is based on Y"); "original" the reverse.
BORROW = [
    (r"\b(?:was|were|been|being|is|are) (?:also |later |famously |widely |reportedly |allegedly )?(?:copied|plagiari[sz]ed|lifted|"
     r"sampled|borrowed|reworked|remade|recreated|covered|interpolated|used) (?:by|in)\b", "original", None),
    (r"\binspired (?!by\b)|\bturned (?:\w+ ){0,3}into\b|\bconverted (?:\w+ ){0,3}into\b", "original", None),
    (r"\binterpolat\w*(?: of)?\b", "derived", "interpolates"),
    (r"\bcontains? (?:an? |several )?(?:samples?|portions?) (?:of|from)\b|\bsampl(?:es|ed|ing)(?: from)?\b", "derived", "samples"),
    (r"\b(?:based (?:up)?on|lifted (?:from|off)|copied from|plagiari[sz]ed from|borrowed from|taken from|adapted from|derived from|"
     r"ripped off|inspired by|a (?:copy|rip-off|remake|recreation) of|similarit(?:y|ies) (?:to|with)|similar to|resembl\w*|"
     r"infring\w*(?: (?:on|upon))?(?: the copyright (?:of|to|in))?|accused of (?:copying|plagiari[sz]ing|stealing|lifting)|"
     r"plagiari[sz](?:ed|ing)|cop(?:ied|ying)|lifting|lifted|used\s+(?:\w+\s+){0,5}(?:from|of))\b", "derived", None),
]
BORROW = [(re.compile(pattern, re.I), order, relation) for pattern, order, relation in BORROW]
# 0.8 when the text says the tune was lifted or the case was lost or settled; an accusation alone is 0.6.
STRONG = re.compile(r"\blift|\bcop(?:y|ied)\b|copied from|rip-?off|ripped|\bstole|blatant|settle|liable|royalt|songwriting credit|"
                    r"found (?:to have|that)|plagiari[sz]ed from|was plagiari[sz]ed|ruled (?:that|in favou?r of the plaintiff)", re.I)
WEAK_OUTCOME = re.compile(r"dismiss|cleared|did not infringe|no infringement|not liable|ruled in favou?r of (?:the )?(?:defendant|him|her|them)|"
                          r"withdr[ae]w|nothing (?:was )?copied|no evidence", re.I)
# An outcome later in the paragraph ("he withdrew the complaint a few months later") counts too,
# unless the paragraph also says the borrower paid.
PAID = re.compile(r"settle|liable|royalt|awarded|damages|songwriting credit", re.I)

RELATION = {  # relation -> (backward, strength)
    "samples": ("sampled by", 0.9), "interpolates": ("interpolated in", 0.85), "version of": ("other version", 0.9),
    "inspired by": ("inspired", 0.6), "cover of": ("covered as", 0.95),
}


# ---------- wikitext helpers ----------

def clean(text):
    """Wikitext with references, comments, tags and most templates gone, links and italics kept."""
    text = drop_quotes(NOISE.sub("", text)).translate(QUOTE_MARKS).replace("'''", "")  # bold says nothing about a title
    text = re.sub(r"\{\{\s*(?:ill|interlanguage link|illm|ill-wd|lien web)\s*\|\s*([^|}]+)[^{}]*\}\}", r"[[\1]]", text, flags=re.I)
    text = re.sub(r"\{\{\s*'s\s*\}\}", "'s", text)
    text = re.sub(r"\{\{\s*(?:lang|langue|transl)\s*\|\s*[\w-]+\s*\|\s*([^{}|]*)[^{}]*\}\}", r"\1", text, flags=re.I)
    text = re.sub(r"\{\{\s*(?:nowrap|nobr|small|smaller|nobold|noitalic|j|date|dts)\s*\|\s*([^{}]*)\}\}", r"\1", text, flags=re.I)
    for _ in range(4):
        text = re.sub(r"\{\{[^{}]*\}\}", "", text)
    text = re.sub(r"<br\s*/?>", "; ", text)
    text = re.sub(r"<[^>]+>", " ", text)
    # A quoted title written inside its link, [[Brutal (song)|"Brutal"]], reads as "[[Brutal (song)|Brutal]]".
    return re.sub(r"\[\[([^\]|]+)\|\s*\"([^\"\]]+)\"\s*\]\]", r'"[[\1|\2]]"', text)


def raw(text):
    """Wikitext without references, comments and quotations, other templates still in place (for
    infoboxes)."""
    return drop_quotes(NOISE.sub("", text)).translate(QUOTE_MARKS)


def drop_quotes(text):
    """The text without its quotation templates (nested templates inside them go too)."""
    while True:
        match = QUOTE_TEMPLATE.search(text)
        if not match:
            return text
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
        if depth:  # never closed: drop to the end of the line
            index = text.find("\n", match.start()) % (len(text) + 1)
        text = text[:match.start()] + " " + text[index:]


def body_lines(text):
    """The cleaned prose and list lines of an article, infoboxes and tables left out."""
    for line in raw(text).split("\n"):
        if not line.lstrip().startswith(("|", "{", "}", "!")):
            yield clean(line)


def plain(text):
    text = clean(text)
    text = LINK.sub(lambda m: m.group(2) if m.group(2) is not None else m.group(1), text)
    text = re.sub(r"\[https?://\S+\s*([^\]]*)\]", r"\1", text).replace("'''", "").replace("''", "")
    return re.sub(r"\s+", " ", text.replace("[[", "").replace("]]", "")).strip()


def titles_in(text, marks=("quote",)):
    """[(start, end, title, link target or None, year or None)] for the titles in cleaned wikitext,
    leaving out quoted lyric lines and anything too long to be a title."""
    found = []
    patterns = {"quote": QUOTED, "italic": ITALIC, "guillemet": GUILLEMET}
    for mark in marks:
        for match in patterns[mark].finditer(text):
            inner = match.group(1)
            title = plain(inner).strip(" ,;:")
            title = title[:-1] if title.endswith(".") and not re.search(r"\b[A-Z]\.$", title) else title
            words = title.split()
            if (not title or len(words) > 12 or len(title) > 90 or LYRIC_CUE.search(plain(text[max(0, match.start() - 60):match.start()]))
                    or (", " in title and len(words) > 6) or title.lower().startswith(("http", "file:", "image:"))):
                continue
            links = [m.group(1).strip() for m in LINK.finditer(inner)]
            # A link into a section ("Reflection#Versión en español") leads to another song's article.
            target = links[0] if len(links) == 1 and not links[0].startswith(":") and "#" not in inner else None
            year = re.match(r"\s*\((\d{4})\)", text[match.end():match.end() + 12])
            found.append((match.start(), match.end(), title, target, int(year.group(1)) if year else None))
    found.sort()
    return [entry for index, entry in enumerate(found) if not index or entry[0] >= found[index - 1][1]]


def field(text, names):
    """The first value of an infobox field, e.g. field(text, "artist|artiste")."""
    match = re.search(r"^\s*\|\s*(?:%s)\s*=\s*(.*)$" % names, text, re.M | re.I)
    return match.group(1).strip() if match else ""


def nation_at(text, site):
    """(position, culture) of the first adjective of nationality in French or Spanish text, or None."""
    found = [(match.start(), culture) for stem, culture in NATION_STEMS[site] for match in [re.search(stem, text, re.I)] if match]
    return min(found) if found else None


def culture_near(text, site="en", foreign=None):
    """The culture an adjective of nationality points to (the first one named); `foreign` for
    one outside the four."""
    if site in NATION_STEMS:
        found = nation_at(text, site)
        return found[1] if found else None
    found = re.findall(r"\b%s\b" % NATION, text)
    culture = CULTURE_OF.get(found[0].lower().replace("-", " ")) if found else None
    return foreign if culture == "xx" else culture


def page_facts(site, title, text):
    """Who a song or album page is by, its year, culture, and whether it is an album."""
    head = text[:6000]
    artist = plain(field(head, "artist|artiste|artista|interprète|int[eé]rprete"))
    artist = re.split(r"\s*;\s*|\s+(?:featuring|feat\.|ft\.|con|avec)\s+", artist)[0]
    if artist.lower() in ("various artists", "various", "artistes variés", "varios artistas", "divers"):
        artist = ""
    year = YEAR.search(field(head, "released|published|recorded|sortie|date de sortie|parution|publicaci[oó]n|lanzamiento|fecha|grabaci[oó]n"))
    album = bool(re.search(r"\{\{\s*(?:Infobox album|Ficha de [aá]lbum)", head, re.I)
                 or re.search(r"\|\s*charte\s*=\s*album", head, re.I))
    lead = next((line for line in text.split("\n") if line.startswith("'''") or line[:40].count("'''") >= 2), "")
    first = plain(lead).split(". ")[0]
    song = re.sub(r"\s*\((?:[^()]*\b(?:song|single|chanson|canción|sencillo|titre)\b[^()]*)\)$", "", title)
    if site in NATION_STEMS:
        blanked = GLOSS.sub(lambda match: " " * len(match.group(0)), first)  # positions kept
        nation, adapted = nation_at(blanked, site), ADAPTATION_PHRASE[site].search(first)
        culture = nation[1] if nation else None
        if adapted and (nation is None or adapted.start() < nation[0]):
            # "Les Grilles de ma maison est une adaptation française de la chanson américaine ...":
            # the page's song is itself the French (or Spanish) version.
            culture = site
    else:
        culture = culture_near(first, site, foreign="xx")
    if culture is None and re.search(r"[\u0370-\u1fff\u3000-\uffff]", first):
        culture = "xx"  # a title given in another script ("Futurista (未来派野郎)"): not English-language
    return {"artist": artist[:80], "year": int(year.group(1)) if year else None, "album": album,
            "culture": culture, "song": song}


def sentences(text):
    """List items and prose sentences, each with the line it came from."""
    for line in text.split("\n"):
        line = line.strip()
        if not line or line.startswith(("{|", "|", "!", "=", "[[Category", "[[Catégorie", "[[Categoría", "{{", "[[File", "[[Fichier", "[[Archivo")):
            continue
        if line.startswith(("*", "#", ";", ":")):
            yield line.lstrip("*#;: ")
        else:
            yield from SENTENCE.split(line)


def artist_name(text):
    """A credited name, or "" when the cell or clause says something else ("Disney's usage of ...")."""
    name = re.sub(r"\s*\([^)]*\)", "", text or "").strip(" ,;:'\"")
    name = re.sub(r"(?:\s+(?:and|&|y|et|with))+\s*$", "", name)  # cut off before the next title
    name = re.sub(r"^(?:the |la |le |el )?(?:group|band|singer|rapper|duo|trio|artist|producer|composer|musician|"
                  r"groupe|chanteuse|chanteur|grupo|banda|cantante)s?,?\s+", "", name, flags=re.I)
    name = name[:-1] if name.endswith(".") and not re.search(r"[A-Z]\.$", name) else name
    loose = [w for w in name.split() if w[:1].islower() and w not in ("and", "of", "the", "de", "la", "del", "y", "et", "feat.", "featuring", "with", "von", "van", "da", "du", "des", "los", "las", "le")]
    return "" if len(name) > 80 or len(loose) > 1 else name


def last_person(text):
    """The last linked name in a stretch of wikitext that is not a year, a date or a title."""
    for match in reversed(list(LINK.finditer(text))):
        label = plain(match.group(2) or match.group(1))
        before = text[max(0, match.start() - 2):match.start()]
        if label[:1].isupper() and not re.search(r"\d", label) and not before.endswith(("''", '"', "«", "« ")):
            return label
    return ""


def side(title, artist, year=None, culture=None, link=None, qid=None):
    return {"title": title, "artist": artist_name(artist), "qid": qid, "culture": culture, "year": year, "_link": link}


def relation(a, b, forward, strength, page, site):
    return {"a": a, "b": b, "forward": forward, "backward": RELATION[forward][0], "strength": strength,
            "source": "w", "page": page if site == "en" else f"{site}:{page}", "_site": site}


# ---------- fetching ----------

def search(site, query, limit=None):
    """Titles of the articles a search finds, best first."""
    titles = []
    params = {"action": "query", "list": "search", "srsearch": query, "srnamespace": "0", "srlimit": "500", "srprop": ""}
    while True:
        data = wiki_api(SITES[site], params)
        titles += [hit["title"] for hit in data.get("query", {}).get("search", [])]
        if "continue" not in data or (limit and len(titles) >= limit):
            break
        params = {**params, **data["continue"]}
    return titles[:limit] if limit else titles


def pages(site, titles, section=None):
    """{title: (wikitext, qid)} for the given articles, 50 to a request."""
    found = {}
    for start in range(0, len(titles), 50):
        params = {"action": "query", "prop": "revisions|pageprops", "rvprop": "content", "rvslots": "main",
                  "ppprop": "wikibase_item", "redirects": "1", "titles": "|".join(titles[start:start + 50])}
        if section is not None:
            params["rvsection"] = str(section)
        while True:
            data = wiki_api(SITES[site], params)
            for page in data.get("query", {}).get("pages", []):
                entry = found.setdefault(page["title"], ["", None])
                revisions = page.get("revisions") or [{}]
                entry[0] = entry[0] or revisions[0].get("slots", {}).get("main", {}).get("content", "")
                entry[1] = entry[1] or page.get("pageprops", {}).get("wikibase_item")
            if "continue" not in data:
                break
            params = {**params, **data["continue"]}
        if start and start % 1000 == 0:
            log(f"  {site} pages", start, "/", len(titles))
    return {title: tuple(entry) for title, entry in found.items() if entry[0]}


def resolve(site, targets, batches=None):
    """{link target: (qid, year)} for linked titles that are songs with an article of their own:
    not a redirect into a section of an album page, not a disambiguation page, not described as
    an album, an artist or a film."""
    found = {}
    targets = sorted({t[0].upper() + t[1:] for t in targets if t and not t.startswith(":")})
    for number, start in enumerate(range(0, len(targets), 50)):
        if batches is not None and number >= batches:
            break
        batch = targets[start:start + 50]
        data = wiki_api(SITES[site], {"action": "query", "prop": "pageprops|pageterms", "ppprop": "wikibase_item|wikibase-shortdesc|disambiguation",
                                      "wbptterms": "description", "redirects": "1", "titles": "|".join(batch)})
        query = data.get("query", {})
        sources, fragment = defaultdict(list), set()
        for step in query.get("normalized", []):
            sources[step["to"]].append(step["from"])
        for step in query.get("redirects", []):
            origin = sources.pop(step["from"], [step["from"]])
            sources[step["to"]] += origin
            if step.get("tofragment"):
                fragment.update(origin)
        for page in query.get("pages", []):
            props = page.get("pageprops", {})
            description = props.get("wikibase-shortdesc") or " ".join(page.get("terms", {}).get("description", []))
            if "disambiguation" in props or not props.get("wikibase_item"):
                continue
            if description and not SONGISH.search(description):
                continue  # an album, an artist, a film or a controversy, not a song
            year = YEAR.search(description) if SONGISH.search(description or "") else None
            for origin in sources.get(page["title"], []) + ([page["title"]] if page["title"] in batch else []):
                if origin not in fragment:
                    found[origin] = (props["wikibase_item"], int(year.group(1)) if year else None)
    return found


def finish(relations, batches=None):
    """Wikidata ids (and years) for linked titles, then the internal fields go."""
    by_site = defaultdict(set)
    for entry in relations:
        for key in ("a", "b"):
            if entry[key]["_link"] and not entry[key]["qid"]:
                by_site[entry["_site"]].add(entry[key]["_link"])
    ids = {}
    for site, targets in by_site.items():
        found = resolve(site, list(targets), batches)
        ids.update({(site, target): value for target, value in found.items()})
        log(f"  {site}: {len(found)} of {len(targets)} linked titles are songs with a Wikidata item")
    kept, seen = [], set()
    named = {(e["a"]["title"].lower(), e["b"]["title"].lower(), e["forward"]) for e in relations if e["a"]["artist"]}
    for entry in relations:
        for key in ("a", "b"):
            end = entry[key]
            link = end.pop("_link")
            if link and not end["qid"]:
                qid, year = ids.get((entry["_site"], link[0].upper() + link[1:]), (None, None))
                end["qid"] = qid
                end["year"] = end["year"] or year
        site = entry.pop("_site")
        a, b = entry["a"], entry["b"]
        if not a["artist"] and (a["title"].lower(), b["title"].lower(), entry["forward"]) in named:
            continue  # the same pair is also stated with the singer's name
        if (a["qid"] and a["qid"] == b["qid"]) or (a["title"].lower() == b["title"].lower() and a["artist"].lower() == b["artist"].lower()):
            continue
        key = (a["title"].lower(), a["artist"].lower(), b["title"].lower(), b["artist"].lower(), entry["forward"], site)
        if key not in seen:
            seen.add(key)
            kept.append(entry)
    return kept


# ---------- 1. sample credits ----------

def credit_sides(unit, facts, links, page_qid):
    """The (a, b, relation) triples one sample-credit note states."""
    found = []
    credit = CREDIT.search(unit)
    if not credit:
        return found
    left, right = unit[:credit.start()], unit[credit.start():]
    tracks = [(title, target or links.get(title.lower()), year) for _, _, title, target, year in titles_in(left)]
    if not tracks:
        # "The song contains a sample of ...": the page's own song, unless the page is an album.
        if facts["album"] or not (SELF.search(plain(left)) or not plain(left).strip(" *#")):
            return found
        tracks = [(facts["song"], None, facts["year"])]
    by_track = BY_NAME.match(plain(unit[unit.find(tracks[0][0]) + len(tracks[0][0]):credit.start()])) if facts["artist"] == "" else None
    artist = facts["artist"] or (by_track.group(1) if by_track else "")
    starts = [m.start() for m in CREDIT_PART.finditer(right)] + [len(right)]
    for index in range(len(starts) - 1):
        part = right[starts[index]:starts[index + 1]]
        kind = "interpolates" if re.match(r"interpolation|elements", CREDIT_PART.match(part).group(1), re.I) else "samples"
        titles = titles_in(part)
        originals = []
        for number, (start, end, title, target, year) in enumerate(titles):
            following = titles[number + 1][0] if number + 1 < len(titles) else len(part)
            info = plain(part[end:following])
            names = PERFORMER.search(info) or BY_NAME.match(info) or WRITER.search(info)
            name = names.group(1).strip(" ,.") if names else ""
            originals.append([title, target or links.get(title.lower()), year, name[:80] if len(name) <= 80 else "", info])
        for number in range(len(originals) - 2, -1, -1):  # '"X" and "Y", written by ...': both by the same people
            if not originals[number][3] and re.fullmatch(r"\W*(?:and|&)?\W*", originals[number][4]):
                originals[number][3] = originals[number + 1][3]
        for title, target, year, name, info in originals:
            if not name and not target:
                continue
            # English Wikipedia's sample credits are overwhelmingly American and British records;
            # an original with an English title and nothing said about where it is from is taken
            # as English-language.
            b_culture = culture_near(info) or ("us" if title.isascii() and facts["culture"] in ("us", None) else None)
            for track, track_target, track_year in tracks:
                if GENERIC_TRACK.match(track):
                    continue
                own = page_qid if track == facts["song"] and not facts["album"] else None
                a_culture = facts["culture"] or ("us" if track.isascii() else None)
                a = side(track, artist, track_year or facts["year"], a_culture, track_target, own)
                found.append((a, side(title, name, year, b_culture, target), kind))
    return found


def sample_credits(limit, page_titles=None):
    titles = page_titles or []
    if not titles:
        for box in SAMPLE_BOXES:
            for phrase in SAMPLE_PHRASES:
                titles += search("en", f'{phrase} hastemplate:"{box}"', limit)
                if limit and len(dict.fromkeys(titles)) >= limit:
                    break
            if limit and len(dict.fromkeys(titles)) >= limit:
                break
        titles = list(dict.fromkeys(titles))[:limit] if limit else list(dict.fromkeys(titles))
    log("sample-credit pages:", len(titles))
    relations = []
    # 500 pages at a time (the same 50-title requests), so a few thousand album pages of
    # wikitext are never all in memory at once.
    for start in range(0, len(titles), 500):
        for title, (text, qid) in pages("en", titles[start:start + 500]).items():
            relations += credits_of_page(title, text, qid)
        log("  pages", min(start + 500, len(titles)), "/", len(titles), "->", len(relations), "credits")
    log("  sample and interpolation credits:", len(relations))
    return relations


def credits_of_page(title, text, qid):
    text = raw(text)
    facts = page_facts("en", title, text)
    links = {plain(m.group(2) or m.group(1)).lower(): m.group(1).strip() for m in LINK.finditer(text) if m.group(1) and m.group(2)}
    relations = []
    numbered = {}  # {{Track listing}} titleN, for a credit given as noteN
    for line in text.split("\n"):
        entry = re.match(r"\s*\|\s*(title|note)(\d+)\s*=\s*(.*)$", line)
        if entry and entry.group(1) == "title":
            numbered[entry.group(2)] = clean(entry.group(3)).strip().strip('"')
            continue
        if entry and entry.group(2) in numbered and CREDIT.search(entry.group(3)):
            units = ['"%s" %s' % (numbered[entry.group(2)], clean(entry.group(3)))]
        elif line.lstrip().startswith(("|", "{", "}", "!", "=")):
            continue
        else:
            units = [unit for unit in sentences(clean(line)) if CREDIT.search(unit)]
        for unit in units:
            for a, b, kind in credit_sides(unit, facts, links, qid):
                relations.append(relation(a, b, kind, RELATION[kind][1], title, "en"))
    return relations


# ---------- 2. disputes ----------

def grid(rows):
    """Table rows with every rowspan cell repeated in the rows it covers."""
    carried, result = {}, []
    for row in rows:
        out, cells, column = [], list(row), 0
        while cells or any(col >= column for col in carried):
            if column in carried:
                left, cell = carried[column]
                out.append(cell)
                if left <= 1:
                    del carried[column]
                else:
                    carried[column] = (left - 1, cell)
            elif cells:
                attributes, content = cells.pop(0)
                out.append((attributes, content))
                if rowspan(attributes) > 1:
                    carried[column] = (rowspan(attributes) - 1, (attributes, content))
            else:
                break
            column += 1
        result.append([content for _, content in out])
    return result


def dispute_strength(result, original_artist, second_artist):
    """0.8 when the borrower settled or lost, 0.4 when the claim was dismissed, 0.6 otherwise."""
    favour = re.search(r"in ([\w .'-]+?)(?:'s|s')? favou?r", result)
    if favour:
        name = favour.group(1).lower()
        if name and name.split()[-1] in second_artist.lower():
            return 0.4
        if name and name.split()[-1] in original_artist.lower():
            return 0.8
    if DISMISSED.search(result) and not re.search(r"(?<!not )(?<!never )(?<!un)settled", result, re.I):
        return 0.4
    if LOST.search(result):
        return 0.8
    return 0.6


def dispute_list(limit):
    relations = []
    text = clean(wikitext(DISPUTE_LIST))
    for cells in grid(table_rows(text)):
        if len(cells) < 6 or not titles_in(cells[1]) or not titles_in(cells[3]):
            continue
        original_artist, second_artist, result = plain(cells[2]), plain(cells[4]), plain(cells[5])
        strength = dispute_strength(result, original_artist, second_artist)
        sampled = re.search(r"\bsampl", result, re.I)
        for _, _, original, original_link, original_year in titles_in(cells[1]):
            for _, _, second, second_link, second_year in titles_in(cells[3]):
                a = side(second, second_artist, second_year, None, second_link)
                b = side(original, original_artist, original_year, None, original_link)
                relations.append(relation(a, b, "samples" if sampled else "inspired by", 0.9 if sampled else strength, DISPUTE_LIST, "en"))
        if limit and len(relations) >= limit:
            break
    log("dispute table:", len(relations))
    return relations


def dispute_articles(limit):
    titles, params = [], {"action": "query", "list": "categorymembers", "cmtitle": DISPUTE_CATEGORY, "cmnamespace": "0", "cmlimit": "500"}
    while True:
        data = wiki_api(SITES["en"], params)
        titles += [member["title"] for member in data.get("query", {}).get("categorymembers", [])]
        if "continue" not in data:
            break
        params = {**params, **data["continue"]}
    titles = [title for title in titles if not title.startswith("List of")]
    titles = titles[:limit] if limit else titles
    relations = []
    for title, (text, qid) in pages("en", titles).items():
        facts = page_facts("en", title, raw(text))
        own = side(facts["song"], facts["artist"], facts["year"], facts["culture"], None, qid)
        # The lead, and the sections that tell the dispute (most leads only mention it).
        body = "\n".join(body_lines(text))
        lead = re.split(r"\n(?==+[^=\n]+=+\s*\n)", "\n" + body)[0]
        relations += prose_relations(lead + "\n" + sections(body, None, DISPUTE_HEADING), title, "en", own=own)
    log("dispute articles:", len(titles), "->", len(relations))
    return relations


# ---------- 3. borrowing in prose ----------

def possessor(window, people, pronouns=False):
    """The artist a title is credited to just before it: "Lata Mangeshkar's" (or, with `pronouns`,
    "his": the paragraph's first-named artist)."""
    match = re.search(r"(%s)(?:'s|(?<=s)')(?:\s+[\w-]+){0,4}\s*$" % NAME, window)
    if match:
        name = match.group(1)
        if " " not in name:  # "Khan's" after "[[Nusrat Fateh Ali Khan]]" earlier in the paragraph
            name = next((full for full in reversed(people) if full.split()[-1] == name), name)
        return name
    if pronouns and re.search(r"\b(?:his|her|their)(?:\s+[\w-]+){0,3}\s*$", window) and people:
        return people[0]  # the paragraph's first-named artist, who is usually what it is about
    return ""


def prose_relations(text, page, site, own=None, maker="", indian=False):
    """Song pairs stated in prose: "X" is based on / lifted from / inspired / sampled ... "Y".
    `own` is the page's song (for "the song was accused of copying ..."), `maker` the composer a
    composer's article is about, credited with the borrowing song when nothing else is named.
    `indian` (the Indian film music pages): a title followed by "in ''Film''" is an Indian film song,
    and "his song" means the paragraph's first-named artist."""
    relations = []
    for paragraph in text.split("\n"):
        people = []
        said = plain(paragraph)
        weak = bool(WEAK_OUTCOME.search(said)) and not PAID.search(said)
        for sentence in SENTENCE.split(paragraph):
            relations += sentence_relations(sentence, page, site, own, maker, people, indian, weak)
            # Linked names of two words or more, not inside a quoted or italic title.
            people += [plain(m.group(2) or m.group(1)) for m in LINK.finditer(sentence)
                       if len(plain(m.group(2) or m.group(1)).split()) >= 2 and sentence[max(0, m.start() - 1):m.start()] not in ('"', "'")
                       and not m.group(1).lower().startswith(("file:", "category:"))]
    return relations


def mask_links(text):
    """The text with link markup blanked to spaces, so that "[[Sampling (music)|samples]]" reads as
    "samples" at the same position."""
    def blank(match):
        target, label = match.group(1), match.group(2)
        if label is None:
            return "  " + target + "  " if "#" not in match.group(0) else " " * len(match.group(0))
        return " " * (len(match.group(0)) - len(label) - 2) + label + "  "
    return LINK.sub(blank, text)


def sentence_relations(sentence, page, site, own, maker, people, indian=False, weak=False):
    titles = titles_in(sentence)
    masked = mask_links(sentence)
    verbs = []
    for pattern, order, kind in BORROW:
        for match in pattern.finditer(masked):
            if not any(start < match.end() and match.start() < end for start, end, _, _ in verbs):
                verbs.append((match.start(), match.end(), order, kind))
    # "turned his "Allah Hoo" into "I Love You"": the original comes first.
    for match in re.finditer(r"\binto\b", masked):
        if re.search(r"\b(?:turned|converted|transformed|reworked)\b", masked[:match.start()]) and \
                not any(start < match.end() and match.start() < end for start, end, _, _ in verbs):
            verbs.append((match.start(), match.end(), "original", None))
    verbs.sort()
    if not verbs or (not titles and own is None):
        return []
    plain_sentence = plain(sentence)
    strength = 0.4 if weak or WEAK_OUTCOME.search(plain_sentence) else 0.8 if STRONG.search(plain_sentence) else 0.6
    own_title = (own or {}).get("title", "").lower()

    def end_of(start, end, title, target, year):
        window = plain(sentence[max(0, start - 90):start])
        after = sentence[end:end + 140]
        after = after[:after.find('"')] if '"' in after else after  # up to the next quoted title
        by = BY_NAME.match(plain(after))
        score = re.match(r"\W*in (%s)'s (?:soundtrack|score|music|film|album)" % NAME, plain(after))
        artist = (by.group(1).strip() if by else "") or possessor(window, people, indian) or (score.group(1) if score else "")
        culture_hint = "in" if indian and score and not by else None
        if own and title.lower() == own_title:
            return dict(own, _link=target)
        if not year:
            near = re.search(r"\((\d{4})\)", after[:90])
            year = int(near.group(1)) if near else None
        film_song = indian and re.match(r"\s*(?:,\s*)?(?:in|from|for) ''", after)
        culture = "in" if film_song else culture_hint or culture_near(window[-50:])
        if not artist and maker and culture == "in":
            artist = maker
        return side(title, artist, year, culture, target)

    found = []
    for index, (start, end, order, kind) in enumerate(verbs):
        previous_end = verbs[index - 1][1] if index else 0
        next_start = verbs[index + 1][0] if index + 1 < len(verbs) else len(sentence)
        before = [t for t in titles if previous_end <= t[0] and t[1] <= start]
        after = []
        following = [t for t in titles if t[0] >= end and t[1] <= next_start]
        if index + 1 < len(verbs) and len(following) > 1:
            following = following[:-1]  # "A was inspired by X's B, C was inspired by ...": C goes with the next verb
        for title in following:
            after.append(title)
            # A list after the verb goes on only while nothing else is said in between.
            gap = plain(sentence[title[1]:next((t[0] for t in titles if t[0] > title[1]), next_start)])
            if re.search(r"\b(?:used|in which|which|while|whereas|but|also|another|latter|former|featuring)\b", gap):
                break
        first = [end_of(*before[-1])] if before else ([own] if own and SELF.search(plain(sentence[previous_end:start])) else [])
        second = [end_of(*t) for t in after] or ([own] if own and not before and SELF.search(plain(sentence[end:next_start])) else [])
        if not first or not second:
            continue
        if maker:  # on a composer's page the song named first is the composer's, unless said otherwise
            for end_ in first:
                if not end_["artist"] and end_ is not own:
                    end_["artist"], end_["culture"] = maker, end_["culture"] or "in"
        derived, originals = (first, second) if order == "derived" else (second, first)
        verb = masked[start:end]
        relation_kind = kind or ("samples" if re.search(r"sampl", verb, re.I) else "cover of" if re.search(r"\bcovered\b", verb, re.I)
                                 else "inspired by")
        for a in derived:
            for b in originals:
                # An original needs something to be found by: an artist, an article, or (for a film
                # song) the film's year.
                if a is b or not (b["artist"] or b["_link"] or b.get("qid") or (b["culture"] == "in" and b["year"])):
                    continue
                weight = RELATION[relation_kind][1] if relation_kind != "inspired by" else strength
                found.append(relation(dict(a), dict(b), relation_kind, weight, page, site))
    return found


def sections(text, wanted, pattern=BORROWING_HEADING):
    """The named sections of an article (or, with wanted None, those whose heading matches
    `pattern`: about borrowing), with their subsections."""
    chunks = re.split(r"\n(?==+[^=\n]+=+\s*\n)", "\n" + text)
    picked, level = [], None
    for chunk in chunks:
        heading = re.match(r"(=+)\s*([^=\n]+?)\s*=+", chunk)
        if not heading:
            continue
        depth, name = len(heading.group(1)), heading.group(2)
        if level is not None and depth > level:
            picked.append(chunk)
            continue
        level = None
        if (wanted and name in wanted) or (wanted is None and pattern.search(name)):
            picked.append(chunk)
            level = depth
    return "\n".join(picked)


def indian_borrowing():
    relations = []
    for title, (text, _) in pages("en", list(INDIAN_PAGES)).items():
        wanted = INDIAN_PAGES.get(title, None)
        body = sections("\n".join(body_lines(text)), wanted)
        maker = "" if wanted else re.sub(r"\s*\(.*\)$", "", title)
        relations += prose_relations(body, title, "en", maker=maker, indian=True)
    log("Indian film music borrowing:", len(relations))
    return relations


# ---------- 4. French and Spanish versions ----------

def adaptations(site, limit):
    phrase = ADAPTATION_PHRASE[site]
    titles = []
    for query, box in ADAPTATIONS[site]:
        titles += search(site, f'{query} hastemplate:"{box}"', limit)
        if limit and len(dict.fromkeys(titles)) >= limit:
            break
    titles = list(dict.fromkeys(titles))[:limit] if limit else list(dict.fromkeys(titles))
    log(f"{site} adaptation pages:", len(titles))
    relations = []
    for title, (text, qid) in pages(site, titles).items():
        facts = page_facts(site, title, raw(text))
        page_song = side(facts["song"], facts["artist"], facts["year"], facts["culture"], None, qid)
        for unit in sentences("\n".join(body_lines(text))):
            match = phrase.search(unit)
            if match:
                relations += version_sides(unit, match, site, facts, page_song, title)
    log(f"  {site} versions:", len(relations))
    return relations


# A linked name that is not a person: a tour, a label, an award, a place.
NOT_PERSON = re.compile(r"\b(?:Tour|Gira|Festival|Award|Awards|Premio|Premios|Prix|Records|Disques|Discos|Music|Musique|Música|"
                        r"Album|Álbum|Grammy|Billboard|Eurovisi\w*|Concurso|Concours|Radio|Show|Film|Película|Hispanoam\w*|"
                        r"Latinoam\w*|América|España|France|Francia|Estados Unidos|États-Unis|Mexique|México)\b", re.I)
PERFORMED_BY = re.compile(r"\b(?:chant[ée]+e?s?|interpr[ée]t[ée]+e?s?|enregistr[ée]+e?s?|popularis[ée]+e?s?|cantad[ao]s?|"
                          r"interpretad[ao]s?|grabad[ao]s?|popularizad[ao]s?|performed|sung|recorded)\s+(?:par|por|by)\b", re.I)
PERFORMING = re.compile(r"\b(?:grab|cant|interpret|lanz|incluy|enregistr|chant|interpr[eè]t|repren|repris|record|sang|sings)\w*", re.I)
# "... de la chanson américaine ''X''", "par [[Adapter]] du titre ''X''": what comes right before the original.
OF_ORIGINAL = re.compile(r"(?:\b(?:de|du|del|of)|\bd')(?:\s+[\w'-]+){0,4}\s*$", re.I)
NAMED_AS = re.compile(r"(?:titul\w+|llamad\w+|intitul\w+|sous le (?:nom|titre)(?: de)?|appel\w+|nomm\w+|called|titled|"
                      r"bajo el (?:nombre|título) de|\bcomo|\bcomme)\s*[:,]?\s*$", re.I)
# Italics also mark albums, films and magazines: a title just after one of these words is not a song.
WORK_CUE = re.compile(r"\b(?:álbum|album|disque|disco|LP|EP|película|film|série|serie|telenovela|revista|magazine|tour|gira|"
                      r"recopilatorio|compilation|comédie musicale|musical|edici[oó]n|[ée]dition|deluxe|banda sonora|"
                      r"soundtrack|bande originale)\b[^\"«»]{0,60}$", re.I)


def people_in(text):
    """[(start, end, name)] for linked names that can be a performer."""
    found = []
    for match in LINK.finditer(text):
        label = plain(match.group(2) or match.group(1))
        lead = text[max(0, match.start() - 2):match.start()]
        if (label[:1].isupper() and not re.search(r"\d", label) and not NOT_PERSON.search(label)
                and not lead.endswith(("''", '"', "«", "« "))):
            found.append((match.start(), match.end(), label))
    return found


def performer_after(text):
    """'interprétée par [[X]]', 'interpretado por ... [[X]]', or a plain 'de [[X]]' right after a title."""
    said = PERFORMED_BY.search(text[:220])
    if said:
        names = people_in(text[said.end():said.end() + 160])
        return names[0][2] if names else ""
    credit = re.match(r"\s*(?:\(\d{4}\)\s*)?,?\s*(?:de|d'|du|del|by)\s*(?=\[\[)", text)
    if credit:
        names = people_in(text[credit.end():credit.end() + 120])
        return names[0][2] if names and names[0][0] == 0 else ""
    return ""


def performer_before(text, page_artist):
    """The singer a sentence is about: a linked name followed by a verb of singing or recording, or
    the page's own artist when the sentence names them ("Aguilera graba una versión ...")."""
    for start, end, name in reversed(people_in(text)):
        if PERFORMING.search(text[end:end + 60]):
            return name
    words = [w for w in re.split(r"\W+", page_artist or "") if len(w) >= 4]
    if words and any(re.search(r"\b%s\b" % re.escape(w), plain(text)) for w in words):
        return page_artist
    return ""


def version_sides(unit, match, site, facts, page_song, page):
    """Other-language versions stated around a phrase such as "adaptation française":
      "''X'', adaptation française, par [[Adapter]], du titre ''Y'' de [[Artist]]": X is a version of Y;
      "Adaptation française de la chanson ''Y'' ..." on the page of X: the same;
      "[[Singer]] en a enregistré une adaptation française" or "una versión en español titulada «Z»"
      on the page of the original: Z (or the same title, by Singer) is a version of the page's song.
    A plain "adaptation française de [[Lyricist]]" credits who wrote the French words, and is skipped."""
    marks = ("quote", "italic", "guillemet")
    titles = [t for t in titles_in(unit, marks) if not WORK_CUE.search(plain(unit[max(0, t[0] - 90):t[0]]))
              and not NOT_PERSON.fullmatch(t[2])]
    before = [t for t in titles if t[1] <= match.start()]
    after = [t for t in titles if t[0] >= match.end()]
    own = page_song["title"].lower()
    lead_in = plain(unit[match.end():after[0][0]]) if after else ""
    original = after[0] if after and len(lead_in) < 140 and OF_ORIGINAL.search(lead_in) and not NAMED_AS.search(lead_in) else None
    rest = after[1:] if original else after
    named = None
    if rest:
        gap = plain(unit[original[1] if original else match.end():rest[0][0]])
        if NAMED_AS.search(gap) or (not original and re.fullmatch(r"[\s,:(]*(?:en \d{4}[\s,]*)?", gap)):
            named = rest[0]
    when = YEAR.search(plain(unit))
    year = int(when.group(1)) if when else None

    if original:
        if original[2].lower() == own:
            b = dict(page_song)
        else:
            tail = unit[original[1]:]
            b = side(original[2], performer_after(tail), original[4], culture_near(plain(tail[:120]), site), original[3])
        if named:
            singer = performer_after(unit[named[1]:]) or performer_before(unit[:match.start()], facts["artist"])
            a = side(named[2], singer, named[4] or year, site, named[3])
        elif before and before[-1][2].lower() != own:
            singer = performer_before(unit[:before[-1][0]], facts["artist"]) or facts["artist"]
            a = side(before[-1][2], singer, before[-1][4] or facts["year"], site, before[-1][3])
        elif original[2].lower() != own:
            a = dict(page_song, culture=site)  # the page's own song is the version
        else:
            return []
    else:
        # A version of the song named just before the phrase, or else of the page's own song.
        subject = before[-1] if before and before[-1][2].lower() != own and match.start() - before[-1][1] < 120 else None
        if subject:
            b = side(subject[2], performer_before(unit[:subject[0]], "") or performer_after(unit[subject[1]:]), subject[4], None, subject[3])
        elif facts["album"]:
            return []
        else:
            b = dict(page_song)
        singer = (performer_after(unit[named[1]:]) if named else "") or performer_before(unit[:match.start()], facts["artist"])
        if named:
            a = side(named[2], singer, named[4] or year, site, named[3])
        elif singer and singer != page_song["artist"]:
            a = side(page_song["title"], singer, year, site)  # same title, sung by someone else
        else:
            return []
    if a["title"].lower() == b["title"].lower() and a["artist"].lower() == b["artist"].lower():
        return []
    return [relation(a, b, "version of", 0.9, page, site)]


# ---------- output ----------

def merge_parts():
    """relations_songs.json: every songs/relations_*.json part, one after the other."""
    merged = []
    for path in sorted(SONGS.glob("relations_*.json")):
        if path.name != MERGED.name:
            merged += json.loads(path.read_text())
    MERGED.write_text(json.dumps(merged, ensure_ascii=False))
    log(len(merged), "relations ->", MERGED.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--parts", default=",".join(PARTS), help="which of " + ", ".join(PARTS))
    parser.add_argument("--limit", type=int, help="at most N pages per search (and N dispute rows/articles): a dry run")
    parser.add_argument("--resolve", type=int, help="at most N id lookups (of 50 titles) per wiki")
    parser.add_argument("--merge", action="store_true", help="only rebuild relations_songs.json")
    args = parser.parse_args()
    SONGS.mkdir(parents=True, exist_ok=True)
    if args.merge:
        merge_parts()
        return
    parts = set(args.parts.split(","))
    if parts - set(PARTS):
        parser.error(f"unknown parts: {sorted(parts - set(PARTS))}")
    relations = []
    if "samples" in parts:
        relations += sample_credits(args.limit)
    if "disputes" in parts:
        relations += dispute_list(args.limit)
        relations += dispute_articles(args.limit)
    if "india" in parts:
        relations += indian_borrowing()
    for site in ("fr", "es"):
        if site in parts:
            relations += adaptations(site, args.limit)
    relations = finish(relations, args.resolve)
    partial = bool(args.limit) or parts != set(PARTS)
    out = DRY_RUN if partial else OUT
    out.write_text(json.dumps(relations, ensure_ascii=False))
    kinds = defaultdict(int)
    for entry in relations:
        kinds[entry["forward"]] += 1
    log(len(relations), "relations ->", out.name, dict(kinds))
    if not partial:
        merge_parts()


if __name__ == "__main__":
    main()
