#!/usr/bin/env python3
"""Step 1b: the canon, and who remade whom.

Reads list articles on English Wikipedia:
  - best-of polls, prize lists and box-office lists for each culture;
  - bestsellers year by year: the Bookman and Publishers Weekly top tens from 1895, and every
    New York Times number one from 1931;
  - the tables of remakes (Hindi films remade from foreign ones, film remakes A-Z, American
    shows based on foreign ones) and of television formats sold around the world.
Every listed work is marked as canon, which the builder turns into prominence, and added to
the catalogue if it is missing. Bestsellers with no article of their own are kept as plain
facts (title, author, year). Updates catalog_base.json; writes canon.json and relations.json.
"""
import hashlib
import json
import re

from common import DATA, log, wiki_api

SITE = "en.wikipedia.org"

# (article, kind, culture, label). The label is kept on each work so the app can say why it is
# there. A culture of None marks works already in the catalogue without adding new ones: those
# lists range over the whole world.
LISTS = [
    ("Modern Library 100 Best Novels", "book", "us", "Modern Library 100"),
    ("20th Century's Greatest Hits: 100 English-Language Books of Fiction", "book", "us", "100 English-language books"),
    ("List of English-language books considered the best", "book", "us", "Considered the best"),
    ("Great Books of the Western World", "book", None, "Great Books"),
    ("Harvard Classics", "book", None, "Harvard Classics"),
    ("Pulitzer Prize for Fiction", "book", "us", "Pulitzer Prize"),
    ("National Book Award for Fiction", "book", "us", "National Book Award"),
    ("Great American Novel", "book", "us", "Great American Novel"),
    ("Booker Prize", "book", "us", "Booker Prize"),
    ("The Big Read", "book", "us", "The Big Read"),
    ("List of best-selling books", "book", None, "Best-selling books"),
    ("Bokklubben World Library", "book", None, "World Library"),
    ("Le Monde's 100 Books of the Century", "book", None, "Le Monde 100"),
    ("Prix Goncourt", "book", "fr", "Prix Goncourt"),
    ("Prix Renaudot", "book", "fr", "Prix Renaudot"),
    ("Prix Femina", "book", "fr", "Prix Femina"),
    ("Grand Prix du roman de l'Académie française", "book", "fr", "Grand Prix du roman"),
    ("Premio Planeta de Novela", "book", "es", "Premio Planeta"),
    ("Premio Nadal", "book", "es", "Premio Nadal"),
    ("Alfaguara Prize", "book", "es", "Premio Alfaguara"),
    ("Rómulo Gallegos Prize", "book", "es", "Rómulo Gallegos Prize"),
    ("Latin American Boom", "book", "es", "Latin American Boom"),
    ("Jnanpith Award", "book", "in", "Jnanpith Award"),
    ("Saraswati Samman", "book", "in", "Saraswati Samman"),
    ("Narmad Suvarna Chandrak", "book", "in", "Narmad Suvarna Chandrak"),
    ("List of Sahitya Akademi Award winners for Hindi", "book", "in", "Sahitya Akademi (Hindi)"),
    ("List of Sahitya Akademi Award winners for Gujarati", "book", "in", "Sahitya Akademi (Gujarati)"),
    ("List of Sahitya Akademi Award winners for Urdu", "book", "in", "Sahitya Akademi (Urdu)"),
    ("Hindi literature", "book", "in", "Hindi literature"),
    ("Gujarati literature", "book", "in", "Gujarati literature"),
    ("Indian epic poetry", "book", "in", "Indian epics"),
    ("AFI's 100 Years...100 Movies", "film", "us", "AFI 100"),
    ("AFI's 100 Years...100 Movies (10th Anniversary Edition)", "film", "us", "AFI 100"),
    ("National Film Registry", "film", "us", "National Film Registry"),
    ("Academy Award for Best Picture", "film", "us", "Best Picture"),
    ("List of highest-grossing films in the United States and Canada", "film", "us", "US box office"),
    ("Time's All-Time 100 Movies", "film", None, "Time 100 movies"),
    ("List of films voted the best", "film", None, "Voted the best"),
    ("The Sight and Sound Greatest Films of All Time 2022", "film", None, "Sight and Sound 2022"),
    ("Cahiers du Cinéma's Annual Top 10 Lists", "film", None, "Cahiers du Cinéma top ten"),
    ("Academy Award for Best International Feature Film", "film", None, "Best International Feature"),
    ("Filmfare Award for Best Film", "film", "in", "Filmfare Best Film"),
    ("National Film Award for Best Feature Film", "film", "in", "National Film Award"),
    ("List of highest-grossing Indian films", "film", "in", "Indian box office"),
    ("List of highest-grossing Hindi films", "film", "in", "Hindi box office"),
    ("List of Indian submissions for the Academy Award for Best International Feature Film", "film", "in", "India's Oscar entry"),
    ("Gujarati cinema", "film", "in", "Gujarati cinema"),
    ("List of Gujarati films", "film", "in", "Gujarati cinema"),
    ("César Award for Best Film", "film", "fr", "César"),
    ("Palme d'Or", "film", None, "Palme d'Or"),
    ("French New Wave", "film", "fr", "French New Wave"),
    ("List of French submissions for the Academy Award for Best International Feature Film", "film", "fr", "France's Oscar entry"),
    ("Goya Award for Best Film", "film", "es", "Goya"),
    ("Ariel Award for Best Picture", "film", "es", "Ariel"),
    ("Golden Age of Mexican cinema", "film", "es", "Mexican Golden Age"),
    ("List of Spanish submissions for the Academy Award for Best International Feature Film", "film", "es", "Spain's Oscar entry"),
    ("List of Mexican submissions for the Academy Award for Best International Feature Film", "film", "es", "Mexico's Oscar entry"),
    ("List of Argentine submissions for the Academy Award for Best International Feature Film", "film", "es", "Argentina's Oscar entry"),
    ("Primetime Emmy Award for Outstanding Drama Series", "tv", "us", "Emmy (drama)"),
    ("Primetime Emmy Award for Outstanding Comedy Series", "tv", "us", "Emmy (comedy)"),
    ("TV Guide's 50 Greatest TV Shows of All Time", "tv", "us", "TV Guide 50"),
    ("List of television shows listed among the best", "tv", None, "Listed among the best"),
    ("List of most watched television broadcasts in the United States", "tv", "us", "Most watched (US)"),
    ("List of longest-running Indian television series", "tv", "in", "Longest-running (India)"),
    ("List of Hindi television sitcoms", "tv", "in", "Hindi sitcoms"),
    ("List of Hindi comedy shows", "tv", "in", "Hindi comedy"),
    ("List of programs broadcast by DD National", "tv", "in", "Doordarshan"),
    ("List of telenovelas", "tv", "es", "Telenovelas"),
    ("List of TelevisaUnivision telenovelas", "tv", "es", "Televisa telenovelas"),
    ("List of French television series", "tv", "fr", "French television"),
]
NYT_YEARS = range(1931, 2026)
TOP_TEN_PAGES = ["Bookman list of bestselling novels in the United States in the 1890s"] + [
    f"Publishers Weekly list of bestselling novels in the United States in the {decade}s" for decade in range(1900, 2030, 10)]

REMAKES_OF_FOREIGN = "List of Hindi film remakes of foreign films"
FILM_REMAKES = ["List of film remakes (A–M)", "List of film remakes (N–Z)"]
SHOWS_FROM_ABROAD = "List of American television shows based on foreign shows"
FORMATS = "List of international television show franchises"

NOISE = re.compile(r"<ref[^>]*/>|<ref[^>]*>.*?</ref>|<!--.*?-->", re.S)
# Works are italicised: ''[[Title]]'', ''[[Article|Title]]'' or [[Article|''Title'']].
ITALIC_LINK = re.compile(r"''\[\[([^\]|#]+)(?:\|[^\]]*)?\]\]''|\[\[([^\]|#]+)\|''[^\]]*''\]\]")
# A cell that opens with a link, italic or not: the work a table row is about.
LEADING_LINK = re.compile(r"^[\s']*\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]*))?\]\]")
BARE_TITLE = re.compile(r"^\s*''+([^'\[\]]+?)''+")
UNLINK = re.compile(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]")
SKIP_TARGET = ("file:", "image:", "category:", "wikt:", ":")


def wikitext(title):
    data = wiki_api(SITE, {"action": "parse", "page": title, "prop": "wikitext", "redirects": "1"})
    return NOISE.sub("", data.get("parse", {}).get("wikitext", ""))


def linked_works(text):
    found = []
    for match in ITALIC_LINK.finditer(text):
        target = (match.group(1) or match.group(2)).strip()
        if not target.lower().startswith(SKIP_TARGET):
            found.append(target)
    return list(dict.fromkeys(found))


def split_attributes(part):
    """'rowspan="2" | text' -> ('rowspan="2" ', ' text'), ignoring pipes inside links and templates."""
    depth = index = 0
    while index < len(part):
        pair = part[index:index + 2]
        if pair in ("[[", "{{"):
            depth, index = depth + 1, index + 2
        elif pair in ("]]", "}}"):
            depth, index = depth - 1, index + 2
        elif part[index] == "|" and depth == 0:
            return part[:index], part[index + 1:]
        else:
            index += 1
    return "", part


def table_rows(text):
    """The rows of every table in the text, each a list of (attributes, content) cells."""
    rows = []
    for chunk in re.split(r"\n\|-[^\n]*", text):
        cells = []
        for line in chunk.split("\n"):
            if line.startswith(("{|", "|}", "|+")):
                continue
            if line.startswith(("|", "!")):
                for part in re.split(r"\|\||!!", line[1:]):
                    attributes, content = split_attributes(part)
                    cells.append((attributes, content.strip()))
            elif cells and line.strip() and not line.startswith("="):
                cells[-1] = (cells[-1][0], (cells[-1][1] + " " + line.strip()).strip())
        if cells:
            rows.append(cells)
    return rows


def leading_works(content):
    """The works a cell names: one link, or several separated by line breaks."""
    found = []
    for part in re.split(r"<br\s*/?>", content):
        match = LEADING_LINK.match(part)
        if match and not match.group(1).lower().startswith(SKIP_TARGET):
            found.append(match.group(1).strip())
    return found


def rowspan(attributes):
    match = re.search(r"rowspan\s*=\s*\"?(\d+)", attributes)
    return int(match.group(1)) if match else 1


def remakes_of_foreign(text):
    """(original, remake) from rows of: [year,] Hindi film, original film, notes."""
    pairs = []
    for row in table_rows(text):
        named = [content for _, content in row if content and not re.fullmatch(r"\d{4}", content)]
        if len(named) >= 2:
            remake, original = leading_works(named[0]), leading_works(named[1])
            if remake and original:
                pairs.append((original[0], remake[0]))
    return pairs


def film_remakes(text):
    """(original, remake) from rows of: original (spanning its remakes), remake, notes."""
    pairs = []
    original, remaining = None, 0
    for row in table_rows(text):
        if remaining > 0:
            remakes = leading_works(row[0][1])
            remaining -= 1
        else:
            first = leading_works(row[0][1])
            original = first[0] if first else None
            remaining = rowspan(row[0][0]) - 1
            remakes = leading_works(row[1][1]) if len(row) > 1 else []
        if original:
            pairs += [(original, remake) for remake in remakes]
    return pairs


def shows_from_abroad(text):
    """(original, remake) from rows of: American show(s), original show(s), country, notes."""
    pairs = []
    for row in table_rows(text):
        if len(row) >= 2:
            pairs += [(original, remake) for remake in leading_works(row[0][1]) for original in leading_works(row[1][1])]
    return pairs


def formats(text):
    """One group per television format: the original and every country's version of it."""
    groups = []
    for section in re.split(r"\n===", text):
        members = [m.group(1).strip() for m in re.finditer(r"Original name:\s*'*\[\[([^\]|#]+)", section)]
        for row in table_rows(section):
            for _, content in row:
                if content.startswith("''"):
                    members += leading_works(content)
        members = list(dict.fromkeys(members))
        if len(members) >= 2:
            groups.append(members)
    return groups


def bestsellers(listed, facts):
    """Top tens of the year (1895 on) and New York Times number ones (1931 on).

    `listed` gets (article, kind, culture, label, year) for works with an article; `facts` gets
    (title, author, label, year) for the rest.
    """
    def record(cell, author, label, year):
        link = LEADING_LINK.match(cell)
        if link and not link.group(1).lower().startswith(SKIP_TARGET):
            listed.append((link.group(1).strip(), "book", "us", label, year))
            return
        bare = BARE_TITLE.match(cell)
        if bare:
            facts.append((bare.group(1).strip(), UNLINK.sub(r"\1", author).strip(" '"), label, year))

    for page in TOP_TEN_PAGES:
        year = None
        for line in wikitext(page).split("\n"):
            heading = re.match(r"==\s*(\d{4})\s*==", line)
            if heading:
                year = int(heading.group(1))
            elif year and line.startswith("#"):
                title, _, author = line.lstrip("# ").partition(" by ")
                record(title, author, "Bestseller of the year", year)
    log("top tens through", year)

    for year in NYT_YEARS:
        shelf = "NYT #1"
        for section in re.split(r"\n(?===)", wikitext(f"List of The New York Times number-one books of {year}")):
            heading = re.match(r"=+\s*([^=\n]+?)\s*=+", section)
            if heading:
                name = heading.group(1).lower()
                shelf = "NYT #1 nonfiction" if "non" in name else "NYT #1 fiction" if "fiction" in name else shelf
            for row in table_rows(section):
                for index, (_, content) in enumerate(row):
                    if content.startswith("''") or content.startswith("[["):
                        if index > 0 or len(row) == 2:
                            record(content, row[index + 1][1] if index + 1 < len(row) else "", shelf, year)
                            break
    log("bestsellers:", sum(1 for entry in listed if entry[3].startswith(("NYT", "Bestseller"))), "with articles,", len(facts), "without")


def wikidata_ids(titles):
    ids = {}
    for start in range(0, len(titles), 50):
        data = wiki_api(SITE, {"action": "query", "prop": "pageprops", "ppprop": "wikibase_item", "redirects": "1",
                               "titles": "|".join(titles[start:start + 50])})
        renamed = {}
        for step in data.get("query", {}).get("normalized", []) + data.get("query", {}).get("redirects", []):
            renamed[step["to"]] = renamed.get(step["from"], step["from"])
        for page in data.get("query", {}).get("pages", []):
            item = page.get("pageprops", {}).get("wikibase_item")
            if item:
                ids[renamed.get(page["title"], page["title"])] = item
    return ids


def main():
    listed = []  # (article, kind, culture, label, year)
    facts = []   # (title, author, label, year)
    for article, kind, culture, label in LISTS:
        works = linked_works(wikitext(article))
        listed += [(title, kind, culture, label, None) for title in works]
        log(label, len(works))
    bestsellers(listed, facts)

    pairs = [(o, r, "film", "in") for o, r in remakes_of_foreign(wikitext(REMAKES_OF_FOREIGN))]
    log("Hindi remakes of foreign films:", len(pairs))
    for page in FILM_REMAKES:
        pairs += [(o, r, "film", None) for o, r in film_remakes(wikitext(page))]
    pairs += [(o, r, "tv", "us") for o, r in shows_from_abroad(wikitext(SHOWS_FROM_ABROAD))]
    groups = formats(wikitext(FORMATS))
    log("remake pairs:", len(pairs), " television formats:", len(groups))

    titles = [entry[0] for entry in listed] + [t for o, r, _, _ in pairs for t in (o, r)] + [t for group in groups for t in group]
    ids = wikidata_ids(list(dict.fromkeys(titles)))
    base = json.loads((DATA / "catalog_base.json").read_text())
    known = {work["id"]: work for work in base if not work.get("fact")}
    canon = {}
    added = 0

    def ensure(item, kind, culture, year=None):
        """Put a work in the catalogue. Without a culture it is kept only if its own language
        or country turns out to be one of ours (the builder decides)."""
        nonlocal added
        if item not in known:
            known[item] = {"id": item, "kind": kind, "cultures": [culture] if culture else [], "links": 0, "listed": True, **({"year": year} if year else {})}
            added += 1

    for title, kind, culture, label, year in listed:
        item = ids.get(title)
        if not item or (culture is None and item not in known):
            continue
        entry = canon.setdefault(item, {"labels": [], "bestseller_year": None})
        if label not in entry["labels"]:
            entry["labels"].append(label)
        if year and not entry["bestseller_year"]:
            entry["bestseller_year"] = year
        ensure(item, kind, culture, year)

    # Bestsellers nobody has written an article about: title, author and year are all there is.
    linked_names = {re.sub(r"\s*\([^)]*\)$", "", title).lower() for title, _, _, label, _ in listed if label.startswith(("NYT", "Bestseller"))}
    seen = {}
    for title, author, label, year in facts:
        key = (title.lower(), author.lower())
        if title.lower() in linked_names or len(title) < 2:
            continue
        if key in seen:
            entry = canon[seen[key]]
            if label not in entry["labels"]:
                entry["labels"].append(label)
            continue
        item = "B" + hashlib.sha1("|".join(key).encode()).hexdigest()[:10]
        seen[key] = item
        shelf = "nonfiction" if "nonfiction" in label else "fiction"
        reason = (f"Number-one New York Times bestseller ({shelf}), {year}" if label.startswith("NYT")
                  else f"One of the ten bestselling novels of {year} in the United States")
        known[item] = {"id": item, "kind": "book", "cultures": ["us"], "links": 0, "year": year, "fact": True,
                       "title": title, "maker": author, "summary": reason}
        canon[item] = {"labels": [label], "bestseller_year": year}

    relations = {"pairs": [], "groups": []}
    for original, remake, kind, culture in pairs:
        a, b = ids.get(original), ids.get(remake)
        if a and b and a != b:
            relations["pairs"].append([a, b])
            ensure(b, kind, culture)
            ensure(a, kind, None)
    for group in groups:
        members = list(dict.fromkeys(ids[title] for title in group if title in ids))
        if len(members) >= 2:
            relations["groups"].append(members)
            for member in members:
                ensure(member, "tv", None)

    (DATA / "catalog_base.json").write_text(json.dumps(list(known.values()), ensure_ascii=False))
    (DATA / "canon.json").write_text(json.dumps(canon, ensure_ascii=False))
    (DATA / "relations.json").write_text(json.dumps(relations, ensure_ascii=False))
    log("canon works:", len(canon), " new to the catalogue:", added, " bestsellers kept as facts:", len(seen),
        " remake pairs:", len(relations["pairs"]), " formats:", len(relations["groups"]))


if __name__ == "__main__":
    main()
