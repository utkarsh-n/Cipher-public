#!/usr/bin/env python3
"""Songs step: Indian film songs and the foreign songs they borrowed, from ItwoFS.com.

ItwoFS ("Inspirations in Indian Film Songs", by Karthik S) lists, composer by composer, Hindi,
Tamil and Telugu songs whose tunes came from somewhere else. Each entry names the Indian
song(s), the film and its year, and then the original: "Lifted off Turkish singer Tarkan's
'Sikidim'". There are 29 static pages, read one every 5 seconds because robots.txt asks for that.

Only facts are kept: song titles, film year, composer, and the original's artist, title and year.
Commentary and quoted lyric lines are skipped, and the audio clips the pages link to are never
fetched. Entries are allegations, so the link reads "inspired by", never "plagiarised".

The site is CC BY 2.5 on condition of a link back next to the portion used, so every relation
keeps, as its page, the URL of the ItwoFS page it came from.

    fetch_itwofs.py                                  all 29 pages
    fetch_itwofs.py --limit 2                        the first two pages
    fetch_itwofs.py --pages hindi-others,coincidence just these
    fetch_itwofs.py --file saved.html --slug hindi-pritam --print   parse a saved copy, no network

Writes songs/relations_itwofs.json (schema 6) and refreshes songs/relations_songs.json. A partial
run (--limit, --pages or --file) writes songs/dryrun_relations_itwofs.json instead, so it never
replaces the full file; build_songs reads only relations_*.json.
"""
import argparse
import html
import json
import re
import sys
import time

from common import DATA, cache_path, fetch, log
from fetch_samples import CULTURE_OF, NATION, merge_parts

SITE = "https://www.itwofs.com/"
CRAWL_DELAY = 5  # seconds, as the site's robots.txt asks
OUT = DATA / "songs" / "relations_itwofs.json"
DRY_RUN = DATA / "songs" / "dryrun_relations_itwofs.json"

# Page -> the composer it is about (named as English Wikipedia names them, so the build can
# match soundtrack credits), or None where the page mixes composers.
PAGES = {
    "hindi-am": "Anu Malik", "hindi-amilind": "Anand–Milind", "hindi-ara": "Anand Raj Anand", "hindi-bl": "Bappi Lahiri",
    "hindi-jl": "Jatin–Lalit", "hindi-ka": "Kalyanji–Anandji", "hindi-lp": "Laxmikant–Pyarelal", "hindi-ns": "Nadeem–Shravan",
    "hindi-opn": "O. P. Nayyar", "hindi-pritam": "Pritam", "hindi-rr": "Rajesh Roshan", "hindi-rdb": "R. D. Burman",
    "hindi-salilc": "Salil Chowdhury", "hindi-sdb": "S. D. Burman", "hindi-sc": "Sandeep Chowta", "hindi-sanjdar": "Sanjeev–Darshan",
    "hindi-sj": "Shankar–Jaikishan", "hindi-others": None, "tamil-arr": "A. R. Rahman", "tamil-deva": "Deva",
    "tamil-ir": "Ilaiyaraaja", "tamil-kr": "Karthik Raja", "tamil-yuvan": "Yuvan Shankar Raja", "tamil-others": None,
    "telugu": None, "indi-pop": None, "advt": None, "coincidence": None, "trivia": None,
}
# The site's own coincidences page: songs that merely sound alike.
COINCIDENCE = {"coincidence"}
# Advertising jingles: the borrowing side is an advert, not a song, so nothing is kept.
ADVERTS = {"advt"}
AUDIO = (".rm", ".ram", ".ra", ".mp3", ".wav", ".wma", ".m4a", ".ogg", ".aac")

QUOTES = str.maketrans({"‘": "'", "’": "'", "“": '"', "”": '"', "´": "'", "`": "'"})
# A title in single quotes: the opening quote follows a space or punctuation, the closing one is
# followed by one, so "Tarkan's 'Sikidim'" and "'Sadda'ny Khalas'" both read right.
QUOTED = re.compile(r"""(?:(?<=^)|(?<=[\s(\[,&:;/"-]))'(\S(?:.*?\S)?)'(?=[\s.,!?;:)\]&/-]|$)""")
# Words that introduce a quoted lyric line rather than a song title ("the mukhda", "a jingle that
# goes", "she sings"); those are never kept. Lower case only, so a capitalised title word just
# before ('Words' and '...') is not taken for one.
LYRIC_CUE = re.compile(r"\b(?:lines?|lyrics?|hook|chorus|refrain|verse|phrase|words|mukhda|antara|portion|bits?|interlude|prelude|"
                       r"jingle|goes|says|said|saying|sings|sang|singing|chant(?:s|ed|ing)?|shout(?:s|ed|ing)?|"
                       r"(?:starts|starting|begins|beginning|opens|opening)\s+with)\b(?:\W+\w+){0,2}\W*$")
NAME = r"[A-Z][\w.\-]*(?:(?:\s+|\s*/\s*)(?:[A-Z][\w.\-]*|ul|al|el|de|da|bin|ibn|van|von))*"
OWNER = re.compile(r"(%s)(?:'s|(?<=s)')(?=[\s,])" % NAME)
BY = re.compile(r"^\s*(?:\(\d{4}[^)]*\)\s*)?,?\s*by\s+(?:(?:the|a|an|%s|[a-z][\w-]*)[\s,]+){0,4}?(?!%s\b)((?:The\s+)?%s(?:\s+(?:&|and)\s+%s)?)" % (NATION, NATION, NAME, NAME))
YEAR = re.compile(r"\b(19[0-9]\d|20[0-2]\d)\b")
LIFT = re.compile(r"\blift|\bcop(?:y|ied)|ripped|rip-off|filch|plagiar|straight|direct|blatant|identical|reproduc|wholesale", re.I)
INSPIRE = re.compile(r"\binspir|influence|based on|borrow|\buses?\b|similar|reminiscent|shades|hint|traces|resembl", re.I)
# The site's own pages and lists ("RDB's copied list"), not songs.
SITE_WORDS = re.compile(r"\b(?:list|page|section|coincidences?|site|listing)\b", re.I)
NUMBERED = re.compile(r"(?:^|\s)(?:0\s?)?\d{1,2}\s?\.\s+(?=['\"])")
# Entry headings: "Shikdum [Dhoom (2004)]", "Oye Oye [Film: Tridev (1989)]", "Chala jaata hoon [Film: Mere
# Jeevan Saathi, 1972]", "Kya Love Story Hai (2007)", "Dosth bada dosth, from Saroja".
HEAD_BRACKET = re.compile(r"^(.*?)\[\s*(?:Film\s*:\s*)?([^\[\]]+?)\s*(?:\((\d{4})[^)]*\)|,\s*(\d{4}))?\s*\]\s*(.*)$")
HEAD_BARE = re.compile(r"^(.+?)\s*\((\d{4})[^)]*\)\s*(.*)$")
HEAD_FROM = re.compile(r"^(.+?),\s*from\s+(.+?)\s*$", re.I)
HEAD_LINE = re.compile(r"\[[^\[\]]+\(\d{4}[^)]*\)\s*\]")
COMPOSER_LINE = re.compile(r"^\s*(?:composer|music(?: director)?|MD)\s*:\s*(.+?)\s*$", re.I)
# "the Beatles song 'In my life'", "a 1970 Deep Purple track titled, 'Black Night'"
KIND_OWNER = re.compile(r"(?!%s\b)(%s)\s+(?:song|number|track|hit|classic|single|composition)(?:\s+(?:titled|called|named))?\s*,?\s*$" % (NATION, NAME))
# "From Europe's Final Countdown!": an original named without quotes, read only when nothing is quoted.
UNQUOTED = re.compile(r"(%s)(?:'s|(?<=s)')\s+(?:(?:song|number|track|hit|classic|single)\s*,?\s+)?"
                      r"(?!(?:song|number|track|hit|album|film|movie|tune|music)\b)([A-Z0-9][^.!?;'\"()]{1,60}?)"
                      r"(?=\s*(?:[.!?;(]|,?\s*respectively|$)|\s+and\s+%s(?:'s|(?<=s)'))" % (NAME, NAME))
MUSIC_CREDIT = re.compile(r"(?:music(?: director)?|composer|composed by|MD)\s*[:\-]\s*(%s)" % NAME, re.I)


def lines_of(body):
    """The page as text lines: one per table row or line break. An entry's heading (a grey cell)
    starts with @@HEAD@@, and the text of a link to an audio clip is wrapped in {{ }}."""
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        text = body.decode("cp1252", errors="replace")
    text = re.sub(r"(?is)<script.*?</script>|<style.*?</style>|<!--.*?-->", " ", text)
    text = re.sub(r"\s+", " ", text)  # the source's own line breaks mean nothing
    text = re.sub(r"(?i)<td[^>]*bgcolor\s*=\s*[\"']?#?e8e8e8[\"']?[^>]*>", "\n@@HEAD@@ ", text)

    def anchor(match):
        label = re.sub(r"<[^>]+>", " ", match.group(2))
        target = match.group(1).lower().split("?")[0]
        return " {{%s}} " % label if target.endswith(AUDIO) else label

    text = re.sub(r"(?is)<a\b[^>]*?href\s*=\s*[\"']?([^\"'\s>]+)[^>]*>(.*?)</a>", anchor, text)
    text = re.sub(r"(?i)</tr>|<br\s*/?>|</p>|</li>|<hr[^>]*>", "\n", text)
    text = re.sub(r"<[^>]+>", " ", text)
    text = html.unescape(text).replace("\xa0", " ").translate(QUOTES)
    text = re.sub(r"<\s*[A-Za-z]{1,5}\s*>", " ", text)  # the site's own markers, such as <TC>
    lines = [re.sub(r"\s+", " ", line).strip() for line in text.split("\n")]
    return [line for line in lines if line]


def entries(lines):
    """[{"head", "summary", "listen"}]: an entry's heading, the rows that state the borrowing,
    and its "Listen to" rows (whose clip names pair Indian songs with originals)."""
    heads = [i for i, line in enumerate(lines) if line.startswith("@@HEAD@@")]
    if not heads:  # no grey headings on this page: fall back to "[Film (Year)]" lines
        heads = [i for i, line in enumerate(lines) if HEAD_LINE.search(line) and len(line) < 200]
        lines = ["@@HEAD@@ " + line if i in heads else line for i, line in enumerate(lines)]
    found = []
    for number, start in enumerate(heads):
        end = heads[number + 1] if number + 1 < len(heads) else len(lines)
        head, body = lines[start][8:].strip(), lines[start + 1:end]
        # A heading broken over two lines: carry on until the film's year shows up.
        while body and not re.search(r"\(\d{4}", head) and len(body[0]) < 120 and re.search(r"\(\d{4}", body[0]):
            head, body = head + " " + body[0], body[1:]
        summary, listen = [], []
        for line in body:
            if "{{" in line or line.lower().startswith("listen to"):
                listen.append(line)
            elif not listen:
                summary.append(line)
        found.append({"head": head, "summary": summary, "listen": listen})
    return found


def split_titles(text):
    text = text.strip(" ,-:")
    quoted = [match.group(1).strip() for match in QUOTED.finditer(text)]
    if quoted:
        return quoted
    return [part.strip(" '\"") for part in re.split(r"\s*(?:,|&|\band\b|/)\s*", text) if len(part.strip(" '\"")) > 1]


def parse_head(head):
    """(Indian song titles, film, year or None, composer named in the heading or None)."""
    head = head.strip()
    if HEAD_BRACKET.match(head):
        songs, film, year, other_year, rest = HEAD_BRACKET.match(head).groups()
        year = year or other_year
    elif HEAD_BARE.match(head):
        songs, (film, year, rest) = "", HEAD_BARE.match(head).groups()
    elif HEAD_FROM.match(head):
        (songs, film), year, rest = HEAD_FROM.match(head).groups(), None, ""
    else:
        return None
    film = film.strip(" ,'")
    titles = [re.sub(r"^[A-Z]\w*'s\s+", "", title) for title in split_titles(songs)]  # "Yuvan's Dosth bada dosth"
    # A film's title song mostly shares the film's name.
    titles = [film if re.fullmatch(r"(?:the\s+)?title\s+(?:song|track)", title, re.I) else title for title in titles]
    credit = MUSIC_CREDIT.search(rest)
    return titles, film, int(year) if year else None, credit.group(1) if credit else None


def skeleton(title):
    """Romanised Hindi is spelt many ways ("samundar"/"samandar", "machaale"/"machale"): compare
    titles by their consonants."""
    letters = re.sub(r"[^a-z0-9]", "", title.lower())
    if not letters:
        return ""
    core = letters[0] + re.sub(r"[aeiouy]", "", letters[1:])
    return re.sub(r"(.)\1+", r"\1", core)


def same_title(one, other):
    a, b = skeleton(re.sub(r"\(.*?\)", "", one)), skeleton(re.sub(r"\(.*?\)", "", other))
    return bool(a and b) and (a == b or (min(len(a), len(b)) >= 4 and (a.startswith(b) or b.startswith(a))))


def culture_near(text):
    found = re.findall(NATION, text)
    return CULTURE_OF.get(found[-1].lower().replace("-", " ")) if found else None


def clean_name(name):
    name = re.sub(r"^(?:%s)\s+" % NATION, "", name.strip(" ,/"))
    # A capitalised word that opens the sentence is not part of the name: "From Europe's ...".
    name = re.sub(r"^(?:(?:From|Inspired|Lifted|Copied|Ditto|Direct|Blatant|Straight|Taken|Based|Off|Of|By|And|Also|Yes)\s+)+", "", name)
    # "Fontella Bass. The song was ...": the next sentence's first word is not part of the name.
    name = re.sub(r"\.\s+(?:The|A|An|This|It|He|She|They)$", "", name)
    name = re.sub(r"\s+", " ", name).strip(" ,/.")
    return "" if re.fullmatch(NATION, name) else name  # "the Tanzanian song 'Malaika'" names no artist


def clean_composer(text):
    """"Ravindra Jain (Movie released in 1975)" -> "Ravindra Jain"; "?" -> ""."""
    text = re.split(r"\s*[,;(]|\s+Singer\s*:", text or "")[0]
    return text.strip(" ?.:-")


# The composers the site has pages for, so that "A R Rahman's 'Madrasa suthi pakka poren'" reads
# as the Indian song and not as an original.
KNOWN_COMPOSERS = {re.sub(r"[^a-z]", "", name.lower()) for name in PAGES.values() if name}


def indian_composer(name):
    return re.sub(r"[^a-z]", "", name.lower()) in KNOWN_COMPOSERS


def quotes(text):
    """Quoted titles with their spans, leaving out quoted lyric lines and anything too long to be
    a title."""
    found = []
    for match in QUOTED.finditer(text):
        title = re.sub(r",?\s*respectively$", "", match.group(1).strip(" .,!?"))
        words = title.split()
        # A trailing "..." marks a line quoted from a song, not its title.
        if (not title or LYRIC_CUE.search(text[max(0, match.start() - 40):match.start()]) or len(words) > 9
                or (", " in title and len(words) > 4) or "..." in match.group(1) or "\u2026" in match.group(1)
                or title.lower() in ("recreating", "inspired", "lifted")
                or SITE_WORDS.search(title)):
            continue
        found.append((match.start(), match.end(), title))
    return found


def originals_and_mentions(text, indian, composer, film=""):
    """Split a summary's titles into foreign originals (with artist, year, culture, strength)
    and mentions of the Indian songs, each with its position."""
    originals, mentions = [], []
    previous = 0
    for start, end, title in quotes(text):
        window = text[previous:start]
        owners = list(OWNER.finditer(window))
        owner = clean_name(owners[-1].group(1)) if owners else ""
        kind = KIND_OWNER.search(window) if not owner else None
        owner = owner or (clean_name(kind.group(1)) if kind else "")
        after = text[end:end + 120]
        by = BY.match(after)
        artist = clean_name(by.group(1)) if by else owner
        # "Aashiqui's (1990) 'Mera dil tere liye'" and "Pritam's 'Dhoom machale'" name the Indian song.
        if artist and ((composer and skeleton(artist) == skeleton(composer)) or (film and same_title(artist, film))
                       or indian_composer(artist) or (film and same_title(title, film))):
            artist = ""
        if artist:
            # The year: "(2001)" right after it, "Waris Baig's 1998 track, 'Kal shab'", or later in the
            # same sentence ("from his 2002 album"), but never past the next quoted title.
            following = QUOTED.search(after)
            rest = re.split(r"[.!?](?:\s|$)|\bwhile\b|\bwhereas\b", after[:following.start()] if following else after, maxsplit=1)[0]
            rest = rest[:OWNER.search(rest).start()] if OWNER.search(rest) else rest
            year = (re.match(r"\s*\((\d{4})", after) or (YEAR.search(window[owners[-1].end():]) if owners and not by else None)
                    or YEAR.search(rest))
            originals.append({"pos": start, "title": title, "artist": artist, "year": int(year.group(1)) if year else None,
                              "culture": culture_near(window[-80:] + " " + (after[:by.end()] if by else ""))})
        elif any(same_title(title, song) for song in indian):
            mentions.append((start, next(song for song in indian if same_title(title, song))))
        previous = end
    # Indian titles named without quotes: "Lamha lamha is lifted from ...", but not inside another
    # quoted title (Amr Diab's 'Ana' is not the Indian 'Ana').
    spans = [(start, end) for start, end, _ in quotes(text)]
    for song in indian:
        for match in re.finditer(r"(?<!\w)%s(?!\w)" % re.escape(song), text, re.I):
            inside = any(start <= match.start() < end for start, end in spans)
            if not inside and not any(abs(match.start() - pos) <= 1 for pos, _ in mentions):
                mentions.append((match.start(), song))
    mentions.sort()
    return originals, mentions


def strength_for(text):
    if LIFT.search(text):
        return 0.8
    return 0.6


def pair_block(text, indian, composer, film=""):
    """(indian title, original) pairs stated in one block of summary text, or None when the block
    names several of each and does not say which goes with which."""
    originals, mentions = originals_and_mentions(text, indian, composer, film)
    if not originals:
        return []
    for original in originals:
        before = [m for m in mentions if m[0] < original["pos"]]
        start = before[-1][0] if before else 0
        original["strength"] = strength_for(text[start:original["pos"]] or text)
    if len(indian) == 1:
        return [(indian[0], original) for original in originals]
    if mentions:
        pairs = []
        for original in originals:
            before = [song for pos, song in mentions if pos < original["pos"]]
            after = [song for pos, song in mentions if pos > original["pos"]]
            if before or after:
                pairs.append((before[-1] if before else after[0], original))
        return pairs
    if len(originals) == 1:
        return [(song, originals[0]) for song in indian]
    if len(indian) == len(originals):
        return list(zip(indian, originals))
    return None


def unquoted(line, composer, film):
    """The originals in a first line such as "From Europe's Final Countdown!" or "Lifted off Ali
    Zafar's Rangeen and Faakhir's Marjawan, respectively!", where nothing is in quotes."""
    found = []
    for match in UNQUOTED.finditer(line):
        artist, title = clean_name(match.group(1)), match.group(2).strip(" ,")
        if (len(title.split()) > 8 or (composer and skeleton(artist) == skeleton(composer)) or (film and same_title(artist, film))
                or indian_composer(artist) or LYRIC_CUE.search(line[:match.start(2)]) or SITE_WORDS.search(title)):
            continue
        year = re.match(r"\s*\((\d{4})", line[match.end(2):])
        found.append({"pos": match.start(2), "title": title, "artist": artist, "year": int(year.group(1)) if year else None,
                      "culture": culture_near(line[:match.start(2)]), "strength": strength_for(line)})
    return found


def listen_pairs(listen, indian, originals):
    """Pairs read off the "Listen to <Indian song> | <original>" rows, for entries whose summary
    does not say which original goes with which song. Only originals the summary names (with an
    artist) are kept."""
    pairs = []
    for line in listen:
        anchors = re.findall(r"\{\{(.+?)\}\}", line)
        heads, tails = [], []
        for position, anchor in enumerate(anchors):
            base = re.sub(r"\(.*?\)", "", anchor).strip(" -|")
            own = next((song for song in indian if same_title(base, song)), None)
            other = next((o for o in originals if same_title(base, o["title"])), None)
            if position == 0 or (own and not other):
                heads.append(own or base)
            elif other:
                tails.append(other)
        pairs += [(head, tail) for head in heads for tail in tails]
    return pairs


def parse_entry(entry, composer, coincidence):
    """[(indian title, film, year, composer, original)] for one entry."""
    head = parse_head(entry["head"])
    if not head:
        return []
    indian, film, year, credited = head
    summary = []
    for line in entry["summary"]:
        credit = COMPOSER_LINE.match(line)
        if credit:  # "Composer: Viju Shah/ Kalyanji Anandji", a row of its own on mixed pages
            credited = credited or clean_composer(credit.group(1))
        else:
            summary.append(line)
    text = " ".join(summary)
    # Some entries run on into a long write-up; the borrowing is stated at the start.
    text = text if len(text) <= 500 or NUMBERED.search(text) else re.split(r"(?<=[.!?])\s", text[:500])[0]
    composer = clean_composer(credited) or composer or ""
    pairs = []
    items = [item for item in NUMBERED.split(text) if item.strip()]
    if len(items) > 1 or NUMBERED.match(text):
        # "01. 'Miss you everyday' - ... 02. 'Deewana teri aankhon ka' ...": one song per item.
        for item in items:
            found = quotes(item)
            if not found:
                continue
            song = found[0][2]
            pairs += pair_block(item[found[0][1]:], [song], composer) or []
    else:
        found = pair_block(text, indian, composer, film)
        if found is None:
            originals, _ = originals_and_mentions(text, indian, composer, film)
            for original in originals:
                original["strength"] = strength_for(text)
            found = listen_pairs(entry["listen"], indian, originals)
        elif not found and indian and summary:
            originals = unquoted(summary[0], composer, film)
            if len(indian) == 1 or len(originals) == 1:
                found = [(song, original) for original in originals for song in indian]
            elif len(indian) == len(originals):
                found = list(zip(indian, originals))
        pairs = found
    result = []
    for song, original in pairs:
        if coincidence:
            original["strength"] = 0.4
        result.append((song, film, year, composer, original))
    return result


def relations_from(body, slug):
    if slug in ADVERTS:
        return []
    composer = PAGES.get(slug)
    page = SITE + slug + ".html"
    relations, seen = [], set()
    for entry in entries(lines_of(body)):
        for song, film, year, by, original in parse_entry(entry, composer, slug in COINCIDENCE):
            key = (song.lower(), year, original["title"].lower(), original["artist"].lower())
            if key in seen:
                continue
            seen.add(key)
            relations.append({
                "a": {"title": song, "artist": by, "qid": None, "culture": "in", "year": year},
                "b": {"title": original["title"], "artist": original["artist"], "qid": None,
                      "culture": original["culture"], "year": original["year"]},
                "forward": "inspired by", "backward": "inspired", "strength": original["strength"],
                "source": "i", "page": page,
            })
    return relations


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--limit", type=int, help="read only the first N pages")
    parser.add_argument("--pages", help="comma-separated page names, e.g. hindi-pritam,coincidence")
    parser.add_argument("--file", help="parse a saved copy of one page instead of fetching (needs --slug)")
    parser.add_argument("--slug", help="which page --file is, e.g. hindi-pritam")
    parser.add_argument("--print", action="store_true", help="print the relations instead of writing them")
    args = parser.parse_args()

    if args.file:
        with open(args.file, "rb") as saved:
            relations = relations_from(saved.read(), args.slug or "")
    else:
        slugs = args.pages.split(",") if args.pages else list(PAGES)
        unknown = [slug for slug in slugs if slug not in PAGES]
        if unknown:
            sys.exit(f"unknown pages: {unknown}")
        slugs = slugs[:args.limit] if args.limit else slugs
        relations, last = [], 0.0
        for slug in slugs:
            # robots.txt: Crawl-delay 5. Only the page itself; its audio clips are never requested.
            # fetch() pauses only after a good answer, so the delay is kept here too, for the
            # request after a failed one.
            url = SITE + slug + ".html"
            if not cache_path(url)[1].exists():
                time.sleep(max(0.0, CRAWL_DELAY - (time.time() - last)))
            body = fetch(url, pause=CRAWL_DELAY)
            last = time.time()
            if body is None:
                log("  could not read", slug)
                continue
            found = relations_from(body, slug)
            log(slug, len(found), "relations")
            relations += found

    if args.print:
        for relation in relations:
            print(json.dumps(relation, ensure_ascii=False))
        log(len(relations), "relations (not written)")
        return
    partial = bool(args.file or args.pages or args.limit)
    out = DRY_RUN if partial else OUT
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(relations, ensure_ascii=False, indent=0))
    log(len(relations), "relations ->", out.name)
    if not partial:
        merge_parts()


if __name__ == "__main__":
    main()
