#!/usr/bin/env python3
"""Step 5: turn everything fetched into the app's culture index.

    build_culture.py                 writes ../../Cipher/Resources/culture-works.tsv
    build_culture.py --batches N     also writes the top N works to tag_batches/ for tagging

One line per work, tab-separated:
    qid, kind, culture, year, weight, title, native title, maker, summary, canon, themes,
    motifs, meaning, mood, siblings

`themes` are "phrase:weight" pairs, most salient first. A sixteenth column counts how many
times a song has been sampled, covered, re-versioned or borrowed from (all of them, not only
the eight relatives kept). `siblings` are "row:relation:strength"
triples pointing at other lines of the same file (0-based), with a fourth part naming where the
link was found when that is known (w Wikipedia, d Wikidata, m MusicBrainz, i ItwoFS). Songs come
from build_songs.py. Motifs, meaning and mood come from
the tagging pass (tags/*.jsonl) and are empty for works it has not reached.
"""
import json
import math
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

from build_songs import song_works
from common import DATA, ROOT, log

OUT = ROOT.parent / "Cipher" / "Resources" / "culture-works.tsv"
THEMES_OUT = ROOT.parent / "Cipher" / "Resources" / "culture-themes.tsv"
LANGUAGE_CULTURE = {"Q1568": "in", "Q5137": "in", "Q1617": "in", "Q1321": "es", "Q150": "fr", "Q1860": "us"}
CORE_INDIAN = {"Q1568", "Q5137", "Q1617"}  # Hindi, Gujarati, Urdu: Bollywood and the writer's own languages
NATIVE_LABEL = {"in": ["label_hi", "label_gu"], "es": ["label_es"], "fr": ["label_fr"], "us": []}
COUNTRY_CULTURE = {"Q30": "us", "Q668": "in", "Q142": "fr", "Q31": "fr", "Q39": "fr",
                   **{country: "es" for country in ("Q29", "Q96", "Q414", "Q739", "Q298", "Q419", "Q717", "Q241", "Q1183", "Q77")}}
# The lists English-language readers and viewers keep; a translated classic on one of these
# belongs on that shelf.
ENGLISH_LISTS = {"Modern Library 100", "100 English-language books", "Considered the best", "Pulitzer Prize", "National Book Award",
                 "Great American Novel", "Booker Prize", "The Big Read", "Great Books", "Harvard Classics", "World Library",
                 "Best-selling books", "Bestseller of the year", "NYT #1 fiction", "NYT #1 nonfiction", "AFI 100",
                 "National Film Registry", "Best Picture", "US box office", "Emmy (drama)", "Emmy (comedy)", "TV Guide 50", "Most watched (US)"}

# What a work linked from a list may be an instance of; anything else (a person, a newspaper,
# a city, a website) was linked in passing.
WORK_CLASSES = set("""Q11424 Q24869 Q226730 Q93204 Q202866 Q29168811 Q506240 Q24862 Q20650540 Q2484376 Q17517379 Q229390
Q5398426 Q15416 Q1259759 Q581714 Q1358344 Q622812 Q846662 Q182415 Q23745 Q7724161 Q1366112 Q117467246 Q2431196 Q1407245
Q21188110 Q3464665 Q526877 Q63952888 Q15416 Q1261214 Q653916 Q15709879 Q11578774 Q5273265 Q30599 Q21191270 Q7777570
Q7725634 Q8261 Q5185279 Q49084 Q25379 Q12106333 Q37484 Q571 Q47461344 Q1279564 Q149537 Q17991521 Q116476516 Q24723 Q1318295
Q2831984 Q386724 Q1667921 Q277759 Q3331189 Q7366 Q134556 Q482994 Q193934 Q35760 Q5633421 Q1760610 Q131436 Q12308638
Q1266946 Q36279 Q233 Q20540385 Q7889 Q1341174 Q747267 Q47512165 Q1318295 Q17537576 Q27032416 Q110910970 Q112983306 Q4502142
Q11826099 Q1792379 Q580922 Q861911 Q1193246 Q60571446 Q21198342 Q74817647 Q3297186 Q112092478 Q842256 Q108342890 Q1760610""".split())

MEDIA = r"(?:documentary |animated |television |short |silent )?(?:films?|novels?|books?|plays?|poems?|poetry|television (?:series|shows|programs|programmes)|short stories|works|fiction|comics|musicals|songs|literature|non-fiction books|memoirs|operas|video games)"
ABOUT = re.compile(r"^.*?\b" + MEDIA + r" about (.+)$", re.IGNORECASE)
SET_IN = re.compile(r"\bset (?:in|on|during) (.+)$", re.IGNORECASE)
GENRE = re.compile(r"^(?:\d{4}s )?(.+?) " + MEDIA + r"$", re.IGNORECASE)
# Category words that describe how a work was made rather than what it is.
NOT_A_GENRE = set("""american indian british french spanish mexican argentine italian german japanese canadian australian english
hindi gujarati urdu tamil telugu bengali marathi malayalam kannada punjabi language english-language hindi-language
spanish-language french-language foreign independent lost surviving rediscovered unreleased upcoming cancelled
black-and-white color colour technicolor sound silent 3d imax live-action direct-to-video sequel prequel reboot
first-run syndicated original streaming cable broadcast network debut feature anthology crossover dubbed
censored banned controversial public domain remade lost obscenity pre-code""".split())
SKIP_CATEGORY = re.compile(r"\b(directed by|produced by|scored by|shot in|shot at|screenplays? by|written by|edited by|"
                           r"distributed by|pictures|studios|productions|entertainment|films by|introduced in|endings|debuts|"
                           r"articles|stubs|wikipedia|pages|cs1|use \w+ dates|commons|templates)\b", re.IGNORECASE)
REMAKE = re.compile(r"\bremakes?\b|remade", re.IGNORECASE)
RELATION = {  # (how this work relates to the other, how the other relates back, strength)
    "source": ("based on", "adapted as", 0.9), "inspired": ("inspired by", "inspired", 0.75),
    "derivative": ("adapted as", "based on", 0.9), "remake": ("remake of", "remade as", 0.95),
    "adaptation": ("based on", "adapted as", 0.9), "homage": ("homage to", "echoed by", 0.6),
}


# How a genre feels. Used for the mood of works the tagging pass has not reached, at half weight.
GENRE_MOOD = [
    ("film noir", "fatalistic shadowy"), ("noir", "fatalistic shadowy"), ("horror", "dread menacing"), ("slasher", "gory dread"),
    ("zombie", "gory dread"), ("psychological", "unsettling"), ("thriller", "tense suspenseful"), ("romantic comedy", "warm playful"),
    ("black comedy", "sardonic"), ("dark comedy", "sardonic"), ("slapstick", "zany"), ("farce", "zany"), ("satir", "biting wry"),
    ("parody", "mocking playful"), ("sitcom", "light familiar"), ("comedy", "playful light"), ("tragedy", "mournful"),
    ("melodrama", "heightened tearful"), ("telenovela", "heightened tearful"), ("soap opera", "heightened tearful"),
    ("romance", "tender yearning"), ("romantic", "tender yearning"), ("love", "tender yearning"), ("war", "grim harrowing"),
    ("western", "rugged lonesome"), ("musical", "exuberant"), ("masala", "exuberant larger-than-life"), ("gangster", "gritty dangerous"),
    ("crime", "gritty dangerous"), ("heist", "slick tense"), ("spy", "suave paranoid"), ("dystopia", "bleak paranoid"),
    ("science fiction", "uncanny awestruck"), ("fantasy", "wondrous"), ("magic realism", "dreamlike"), ("surreal", "dreamlike"),
    ("adventure", "rousing"), ("action", "explosive adrenalized"), ("superhero", "heroic"), ("disaster", "panicked"),
    ("mystery", "intriguing suspicious"), ("detective", "intriguing suspicious"), ("coming-of-age", "bittersweet nostalgic"),
    ("gothic", "brooding haunted"), ("epic", "grand sweeping"), ("sport", "striving triumphant"), ("erotic", "sensual"),
    ("devotional", "devout reverent"), ("religious", "devout reverent"), ("mytholog", "mythic reverent"), ("patriotic", "proud"),
    ("historical", "stately"), ("period", "stately"), ("political", "charged"), ("existential", "alienated absurd"),
    ("absurd", "alienated absurd"), ("picaresque", "roguish"), ("pastoral", "serene"), ("road", "restless free"),
    ("children", "innocent bright"), ("family", "warm"), ("news", "urgent sober"), ("documentary", "sober"),
    ("game show", "competitive"), ("reality", "competitive voyeuristic"), ("talk show", "chatty"), ("poetry", "lyrical"),
    ("poem", "lyrical"), ("elegy", "mournful"), ("ghost", "haunted"), ("vampire", "seductive dread"), ("revenge", "vengeful"),
]


def moods_from(genres):
    """Up to three moods implied by a work's genres."""
    found = []
    for genre in genres:
        lowered = genre.lower()
        for key, moods in GENRE_MOOD:
            if key in lowered:
                found += [mood for mood in moods.split() if mood not in found]
                break
    return found[:3]


def looks_proper(head):
    """'Warner Bros.', 'A24', 'Yash Raj Films': a studio or publisher named in a category, not a genre."""
    words = head.split()
    for position, word in enumerate(words):
        core = word.strip("-.,'")
        if position > 0 and core[:1].isupper():
            return True
        if position == 0 and not core.isupper() and any(c.isupper() for c in core[1:]):
            return True
    return any(c.isdigit() for c in head)


def clean_phrase(text):
    text = re.sub(r"\s*\([^)]*\)", "", text).strip().lower()
    text = re.sub(r"^(the|a|an) ", "", text)
    return re.sub(r"\s+", " ", text).replace("\t", " ").replace("|", "/").replace(":", " -")


def labels(entries):
    # An "unknown value" in Wikidata arrives as a blank-node URL, not a name.
    return [entry["label"] for entry in entries if entry.get("label") and not entry["label"].startswith("http")]


def themes_from(detail, categories):
    """Weighted themes for a work from its subjects, categories and genres."""
    themes = {}

    def add(phrase, weight):
        phrase = clean_phrase(phrase)
        if 2 < len(phrase) <= 48 and not phrase[0].isdigit():
            themes[phrase] = max(themes.get(phrase, 0), weight)

    for subject in labels(detail.get("subject", [])):
        add(subject, 1.0)
    for category in categories:
        if SKIP_CATEGORY.search(category):
            continue
        about = ABOUT.match(category)
        if about:
            subject = about.group(1)
            add(subject, 0.9)
            # "organized crime in the United States" is also simply about organized crime.
            head = re.split(r" (?:in|of|during|from) (?:the )?[A-Z0-9]", subject)[0]
            if head != subject:
                add(head, 0.8)
            continue
        setting = SET_IN.search(category)
        if setting:
            add(setting.group(1), 0.45)
            continue
        genre = GENRE.match(category)
        if genre and not looks_proper(genre.group(1)):
            words = [word for word in genre.group(1).lower().split() if word not in NOT_A_GENRE and not word[0].isdigit()]
            if 0 < len(words) <= 3:
                add(" ".join(words), 0.6)
    for genre in labels(detail.get("genre", [])):
        stripped = re.sub(r"\b(films?|novels?|television (?:series|program)|fiction|literature|books?|genre)\b", "", genre).strip(" -")
        if stripped:
            add(stripped, 0.55)
    ranked = sorted(themes.items(), key=lambda item: (-item[1], item[0]))
    return ranked[:14]


def main():
    base = json.loads((DATA / "catalog_base.json").read_text())
    details = json.loads((DATA / "catalog_details.json").read_text())
    canon = json.loads((DATA / "canon.json").read_text()) if (DATA / "canon.json").exists() else {}
    cats = json.loads((DATA / "wikipedia_categories.json").read_text()) if (DATA / "wikipedia_categories.json").exists() else {}
    leads = json.loads((DATA / "wikipedia_leads.json").read_text()) if (DATA / "wikipedia_leads.json").exists() else {}
    tags = {}
    for path in sorted((DATA / "tags").glob("*.jsonl")) if (DATA / "tags").exists() else []:
        for line in path.read_text().splitlines():
            try:
                record = json.loads(line)
                tags[record["q"]] = record
            except Exception:
                continue

    relations = json.loads((DATA / "relations.json").read_text()) if (DATA / "relations.json").exists() else {"pairs": [], "groups": []}

    works = []
    for entry in base:
        detail = details.get(entry["id"], {})
        title = (detail.get("label_en") or detail.get("label_hi") or detail.get("label_es") or detail.get("label_fr")
                 or detail.get("label_gu") or entry.get("title"))
        if not title or re.fullmatch(r"Q\d+", title):
            continue
        types = {e["id"] for e in detail.get("type", [])}
        if entry.get("listed") and types and not (types & WORK_CLASSES):
            continue  # a list linked a person, a newspaper or a city in italics
        languages = {e["id"] for e in detail.get("language", []) + detail.get("worklang", [])}
        countries = {e["id"] for e in detail.get("country", [])}
        cultures = entry["cultures"]
        listed = entry["id"] in canon
        # The work's own language decides its culture, then the country it was made in; where
        # it was catalogued breaks ties. An American production stays American even with
        # Spanish or French spoken in it, and an English-language work from anywhere else
        # (a British series on Doordarshan, say) belongs with the English-language ones.
        by_country = next((COUNTRY_CULTURE[c] for c in COUNTRY_CULTURE if c in countries), None)
        spoken = [LANGUAGE_CULTURE[l] for l in ("Q1568", "Q5137", "Q1617", "Q150", "Q1321") if l in languages]
        english = "Q1860" in languages
        foreign = languages - set(LANGUAGE_CULTURE) - {"Q1860"}
        named_by = set(canon.get(entry["id"], {}).get("labels", []))
        # The country that made it, when its language agrees (Toy Story lists Spanish too);
        # a classic from outside our four worlds goes with the readers whose lists name it
        # (War and Peace has French in it, but it is on the English-language shelf); then how
        # it was catalogued, when its own language agrees; then language; then country.
        if by_country and by_country in cultures and ((by_country == "us" and english) or by_country in spoken):
            culture = by_country
        elif foreign and not english and by_country not in spoken:
            if named_by & ENGLISH_LISTS or "us" in cultures:
                culture = "us"
            elif spoken:
                culture = spoken[0]
            elif cultures and not entry.get("listed"):
                culture = cultures[0]
            else:
                continue
        elif set(cultures) & set(spoken):
            culture = next(c for c in cultures if c in spoken)
        elif "us" in cultures and (english or not languages):
            culture = "us"
        elif by_country in spoken:
            culture = by_country
        elif spoken:
            culture = spoken[0]
        elif by_country:
            culture = by_country
        elif english:
            culture = "us"
        elif cultures and not entry.get("listed"):
            culture = cultures[0]
        else:
            continue  # named by a list or a remake table, but from none of our four worlds
        if culture == "in" and entry["kind"] == "film" and not (languages & CORE_INDIAN) and entry["links"] < 8 and not listed:
            continue  # other Indian-language cinema only where it is widely known
        categories = cats.get(detail.get("enwiki", ""), []) if isinstance(detail.get("enwiki"), str) else []
        native = next((detail[key] for key in NATIVE_LABEL[culture] if isinstance(detail.get(key), str) and detail[key] != title), "")
        makers = labels(detail.get("director", [])) or labels(detail.get("author", [])) or labels(detail.get("creator", []))
        if entry["kind"] == "sport":
            makers = labels(detail.get("winner", []))
        if not makers and entry["kind"] == "tv":
            makers = labels(detail.get("network", []))[:1]
        if not makers and entry.get("maker"):
            makers = [entry["maker"]]
        canon_labels = list(canon.get(entry["id"], {}).get("labels", []))
        for category in categories:
            if "National Film Registry" in category and "National Film Registry" not in canon_labels:
                canon_labels.append("National Film Registry")
        works.append({
            "q": entry["id"], "kind": entry["kind"], "culture": culture, "year": entry.get("year") or canon.get(entry["id"], {}).get("bestseller_year"),
            "links": entry["links"], "awards": len(detail.get("award", [])), "canon": canon_labels,
            "title": title, "native": native, "maker": ", ".join(makers[:2]),
            "summary": detail.get("desc", "") if isinstance(detail.get("desc"), str) else entry.get("summary", ""),
            "themes": themes_from(detail, categories), "enwiki": detail.get("enwiki", "") if isinstance(detail.get("enwiki"), str) else "",
            "genre_moods": moods_from(labels(detail.get("genre", [])) + [c for c in categories if GENRE.match(c) and not SKIP_CATEGORY.search(c)]),
            "is_remake": any(REMAKE.search(c) for c in categories), "detail": detail,
            "gutenberg": next((e["label"] for e in detail.get("gutenberg", [])), ""),
        })

    # Songs, with the films they come from already in hand; their links wait for the rows.
    film_rows = {work["q"]: work for work in works if work["kind"] == "film"}
    songs, song_links = song_works(film_rows)
    works += songs

    # Prominence: how widely a work is written about, how decorated it is, and whether a
    # canon list names it; blended with its standing inside its own culture and medium so
    # that a smaller industry's landmarks are not buried under a larger one's also-rans.
    groups = defaultdict(list)
    for work in works:
        work["raw"] = 0.6 * min(1, math.log1p(work["links"]) / math.log(120)) + 0.2 * min(1, work["awards"] / 6) + 0.2 * min(1, len(work["canon"]) / 2)
        groups[(work["culture"], work["kind"])].append(work)
    for members in groups.values():
        members.sort(key=lambda work: work["raw"])
        for rank, work in enumerate(members):
            work["weight"] = round(100 * (0.5 * work["raw"] + 0.5 * rank / max(1, len(members) - 1)))
    works.sort(key=lambda work: (-work["weight"], work["title"]))
    row = {work["q"]: index for index, work in enumerate(works)}
    by_title = {work["enwiki"]: index for index, work in enumerate(works) if work["enwiki"]}

    # Relatives: stated in Wikidata, stated in the article's opening, or named by the tagger.
    siblings = defaultdict(dict)

    def link(a, b, forward, backward, strength, source=None):
        if a == b:
            return
        if strength > siblings[a].get(b, ("", 0, None))[1]:
            siblings[a][b] = (forward, strength, source)
        if strength > siblings[b].get(a, ("", 0, None))[1]:
            siblings[b][a] = (backward, strength, source)

    for index, work in enumerate(works):
        for prop in ("source", "inspired", "derivative"):
            for target in work["detail"].get(prop, []):
                if target["id"] in row:
                    forward, backward, strength = RELATION[prop]
                    link(index, row[target["id"]], forward, backward, strength)
        for relation, target in leads.get(work["enwiki"], []):
            other = by_title.get(target, by_title.get(target.replace("_", " ")))
            if other is not None:
                forward, backward, strength = RELATION[relation]
                link(index, other, forward, backward, strength)

    # Songs: samples, covers, versions, borrowing, and the films they are from.
    for a, b, forward, backward, strength, source in song_links:
        if a in row and b in row:
            link(row[a], row[b], forward, backward, strength, source)

    # Wikipedia's own tables of remakes, and of television formats sold from country to country.
    for original, remake in relations["pairs"]:
        if original in row and remake in row:
            link(row[remake], row[original], "remake of", "remade as", 0.95)
    for group in relations["groups"]:
        members = [row[item] for item in group if item in row]
        for position, first in enumerate(members):
            for second in members[position + 1:]:
                if group[0] in row and first == row[group[0]]:
                    link(second, first, "version of", "adapted as", 0.9)
                else:
                    link(first, second, "counterpart", "counterpart", 0.8)

    def find(title, year):
        """A tagger-named work in the catalogue, by title and (roughly) year."""
        wanted = clean_phrase(title)
        best = None
        for index in title_index.get(wanted, []):
            other = works[index]
            if year and other["year"] and abs(other["year"] - year) > 2:
                continue
            if best is None or other["weight"] > works[best]["weight"]:
                best = index
        return best

    title_index = defaultdict(list)
    for index, work in enumerate(works):
        for name in {work["title"], work["native"]}:
            if name:
                title_index[clean_phrase(name)].append(index)
    for index, work in enumerate(works):
        tag = tags.get(work["q"])
        if not tag:
            continue
        for sibling in tag.get("siblings", []):
            other = find(sibling.get("title", ""), sibling.get("year"))
            if other is not None:
                relation = sibling.get("relation", "kindred")
                strength = max(0.3, min(1.0, float(sibling.get("strength", 0.6))))
                link(index, other, relation, {"remake of": "remade as", "based on": "adapted as", "inspired by": "inspired"}.get(relation, relation), strength)

    # Kindred works: no stated link, but the same rare themes in a different culture.
    theme_works = defaultdict(list)
    for index, work in enumerate(works):
        tag = tags.get(work["q"], {})
        work["all_themes"] = dict(work["themes"])
        for position, theme in enumerate(tag.get("themes", [])):
            work["all_themes"][clean_phrase(theme)] = max(work["all_themes"].get(clean_phrase(theme), 0), 1.0 - 0.08 * position)
        for theme in work["all_themes"]:
            theme_works[theme].append(index)
    rarity = {theme: math.log(len(works) / len(members)) for theme, members in theme_works.items() if 2 <= len(members) <= 400}
    for index, work in enumerate(works):
        if work["weight"] < 45 or len(work["all_themes"]) < 3:
            continue
        scores = Counter()
        for theme, weight in work["all_themes"].items():
            if theme not in rarity:
                continue
            for other in theme_works[theme]:
                if works[other]["culture"] != work["culture"] and works[other]["kind"] != "channel":
                    scores[other] += weight * works[other]["all_themes"][theme] * rarity[theme]
        own = sum(weight * weight * rarity.get(theme, 0) for theme, weight in work["all_themes"].items()) or 1
        for other, score in scores.most_common(4):
            theirs = sum(w * w * rarity.get(t, 0) for t, w in works[other]["all_themes"].items()) or 1
            similarity = score / math.sqrt(own * theirs)
            if similarity >= 0.42:
                link(index, other, "kindred", "kindred", round(min(0.7, similarity), 2))

    def field(text):
        return str(text).replace("\t", " ").replace("\n", " ").strip()

    # Ideas that run together. Nobody tags this: it is what the corpus itself shows, theme by
    # theme, as the themes that share works with it far more often than chance would have it
    # (normalised pointwise mutual information). The app turns it into the "runs with" trail
    # that leads a writer from one idea to its neighbours across all four cultures.
    count = {theme: len(members) for theme, members in theme_works.items()}
    usable = {theme for theme, n in count.items() if 3 <= n <= len(works) // 12}
    pairs = Counter()
    for work in works:
        themes = sorted(theme for theme in work["all_themes"] if theme in usable)
        for position, first in enumerate(themes):
            for second in themes[position + 1:]:
                pairs[(first, second)] += 1
    total = len(works)
    neighbours = defaultdict(list)
    for (first, second), shared in pairs.items():
        if shared < 3:
            continue
        pmi = math.log(shared * total / (count[first] * count[second]))
        npmi = pmi / -math.log(shared / total)
        if npmi >= 0.2:
            # Rare pairs are noisy; a shared-count factor keeps the well-attested ones on top.
            strength = round(min(1.0, npmi * (0.6 + 0.4 * min(1, math.log(shared) / math.log(40)))), 2)
            neighbours[first].append((second, strength))
            neighbours[second].append((first, strength))
    theme_lines = []
    for theme in sorted(usable):
        near = sorted(neighbours.get(theme, []), key=lambda pair: -pair[1])[:12]
        if not near:
            continue
        top = sorted(theme_works[theme], key=lambda index: -works[index]["weight"])[:4]
        theme_lines.append("\t".join([theme, str(count[theme]), "|".join(f"{other}:{strength:.2f}" for other, strength in near), "|".join(map(str, top))]))
    THEMES_OUT.write_text("\n".join(theme_lines) + "\n")
    linked_works = sum(1 for work in works if any(theme in neighbours for theme in work["all_themes"]))
    log(f"{len(theme_lines)} themes with neighbours -> {THEMES_OUT.name} ({THEMES_OUT.stat().st_size // 1024} KB); "
        f"{sum(len(n) for n in neighbours.values()) // 2} theme pairs; {linked_works} works on the theme graph")

    taken_from = {"sampled by", "interpolated in", "covered as", "other version", "remixed as", "inspired", "answered by"}
    lines = []
    for index, work in enumerate(works):
        tag = tags.get(work["q"], {})
        taken = sum(1 for relation, _, _ in siblings[index].values() if relation in taken_from) if work["kind"] == "song" else 0
        themes = sorted(work["all_themes"].items(), key=lambda item: (-item[1], item[0]))[:14]
        # Relatives from another culture are the ones worth showing first.
        relatives = sorted(siblings[index].items(), key=lambda item: -(item[1][1] + (0.15 if works[item[0]]["culture"] != work["culture"] else 0)))[:8]
        lines.append("\t".join([
            work["q"], work["kind"], work["culture"], str(work["year"] or ""), str(work["weight"]),
            field(work["title"]), field(work["native"]), field(work["maker"]), field(work["summary"]),
            field("|".join(work["canon"][:3])),
            field("|".join(f"{theme}:{weight:.2f}" for theme, weight in themes)),
            field("|".join(clean_phrase(m) for m in tag.get("motifs", []))),
            field(tag.get("meaning", "")),
            field("|".join(clean_phrase(m) for m in tag["mood"]) if tag.get("mood") else "|".join(f"{m}:0.50" for m in work["genre_moods"])),
            "|".join(f"{other}:{relation}:{strength:.2f}" + (f":{source}" if source else "") for other, (relation, strength, source) in relatives),
            str(taken) if taken else "",
        ]))
    OUT.write_text("\n".join(lines) + "\n")

    kinds = Counter((work["culture"], work["kind"]) for work in works)
    log(f"{len(works)} works -> {OUT.name} ({OUT.stat().st_size // 1024} KB)")
    log("  by culture and kind:", dict(sorted(kinds.items())))
    log("  with themes:", sum(1 for w in works if w["all_themes"]), " tagged:", sum(1 for w in works if w["q"] in tags),
        " with relatives:", sum(1 for i in range(len(works)) if siblings[i]),
        " stated links:", sum(1 for i in siblings for _, (r, _s, _src) in siblings[i].items() if r != "kindred") // 2)

    if "--batches" in sys.argv or "--song-batches" in sys.argv:
        songs_only = "--song-batches" in sys.argv
        total = int(sys.argv[sys.argv.index("--song-batches" if songs_only else "--batches") + 1])
        # A fixed share per culture, so the tagging pass covers all four worlds.
        share = {"us": 0.34, "in": 0.30, "es": 0.18, "fr": 0.18}
        wanted = ("song",) if songs_only else ("film", "tv", "book")
        chosen = []
        for culture, fraction in share.items():
            pool = [w for w in works if w["culture"] == culture and w["kind"] in wanted and w["q"] not in tags and not w.get("stub")]
            chosen += pool[:int(total * fraction)]
        folder = DATA / "tag_batches"
        folder.mkdir(exist_ok=True)
        # Song batches get their own names, so their tags never overwrite the works' tag files.
        prefix = "songs" if songs_only else "batch"
        for old in folder.glob(f"{prefix}_*.tsv"):
            old.unlink()
        size = 110
        for number, start in enumerate(range(0, len(chosen), size)):
            rows = ["\t".join([w["q"], w["title"], str(w["year"] or ""), w["kind"], w["culture"], field(w["maker"]), field(w["summary"])]) for w in chosen[start:start + size]]
            (folder / f"{prefix}_{number:02d}.tsv").write_text("\n".join(rows) + "\n")
        log(f"  wrote {len(chosen)} works to {folder} in batches of {size}")


if __name__ == "__main__":
    main()
