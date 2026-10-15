#!/usr/bin/env python3
"""Step 3: what Wikipedia says each work is about, and what it was made from.

For every catalogued work with an English Wikipedia article:
  - its categories ("Films about revenge", "Indian remakes of American films"), which are the
    richest open source of themes there is;
  - for films and television, the opening section's wikitext, where remakes and inspirations
    are stated in prose with a link to the original.
Writes wikipedia_categories.json and wikipedia_leads.json.

    fetch_wikipedia.py                      films, television and books, as above
    fetch_wikipedia.py --songs [--limit N]  songs: writes songs/song_wiki.json
    fetch_wikipedia.py --songs --sample     a dry run on a handful of well-known songs

For songs, each song is read on one Wikipedia (English if it has an article there, else
Spanish, else French). Its categories give themes ("Songs about revenge", "Canciones sobre la
venganza", "Chanson évoquant la pluie", mapped to English through the categories' own English
interlanguage links) and writers ("Songs written by X"); its opening section gives the songs it
samples, interpolates, covers, recreates, remixes, answers or translates, and the film it was
written for. Titles, names and relations only: no lyrics are read for or kept from any page.
"""
import argparse
import json
import re
import urllib.parse
from collections import defaultdict
from pathlib import Path

import common
from common import DATA, log, wiki_api

SITE = "en.wikipedia.org"

# "...is a remake of the 1991 film ''[[Sleeping with the Enemy]]''": the relation, then the
# first linked title within a clause of it.
RELATIONS = [
    ("remake", r"(?:official |unofficial |uncredited |loose |partial )?remake of"),
    ("remake", r"remade (?:from|as)"),
    ("adaptation", r"(?:loose |loosely |uncredited )?(?:adaptation of|adapted from|based on)"),
    ("inspired", r"(?:heavily |loosely |partly )?(?:inspired by|borrowed from|draws (?:heavily )?(?:on|from)|modell?ed on|plagiari[sz]ed from)"),
    ("homage", r"(?:homage|tribute|spoof|parody) (?:to|of)"),
]
LINK = r"[^.\n]{0,120}?\[\[([^\]|#]+)(?:\|[^\]]*)?\]\]"


def categories(titles):
    result = {}
    for start in range(0, len(titles), 50):
        batch = titles[start:start + 50]
        params = {"action": "query", "prop": "categories", "cllimit": "max", "clshow": "!hidden", "redirects": "1", "titles": "|".join(batch)}
        while True:
            data = wiki_api(SITE, params)
            redirects = {r["to"]: r["from"] for r in data.get("query", {}).get("redirects", [])}
            for page in data.get("query", {}).get("pages", []):
                title = redirects.get(page["title"], page["title"])
                names = [c["title"].removeprefix("Category:") for c in page.get("categories", [])]
                result.setdefault(title, []).extend(names)
            if "continue" not in data:
                break
            params = {**params, **data["continue"]}
        if start % 2000 == 0:
            log("categories", start, "/", len(titles))
    return result


def leads(titles):
    result = {}
    for start in range(0, len(titles), 50):
        batch = titles[start:start + 50]
        data = wiki_api(SITE, {"action": "query", "prop": "revisions", "rvprop": "content", "rvslots": "main", "rvsection": "0",
                               "redirects": "1", "titles": "|".join(batch)})
        redirects = {r["to"]: r["from"] for r in data.get("query", {}).get("redirects", [])}
        for page in data.get("query", {}).get("pages", []):
            try:
                text = page["revisions"][0]["slots"]["main"]["content"]
            except (KeyError, IndexError):
                continue
            found = []
            for relation, phrase in RELATIONS:
                for match in re.finditer(phrase + LINK, text, flags=re.IGNORECASE):
                    target = match.group(1).strip()
                    if not target.lower().startswith(("file:", "image:", "category:")):
                        found.append([relation, target])
            if found:
                result[redirects.get(page["title"], page["title"])] = found
        if start % 2000 == 0:
            log("leads", start, "/", len(titles))
    return result


def main():
    details = json.loads((DATA / "catalog_details.json").read_text())
    base = {work["id"]: work for work in json.loads((DATA / "catalog_base.json").read_text())}
    core_indian = {"Q1568", "Q5137", "Q1617"}

    def wanted(item, info):
        """The works whose themes are worth a request: the same ones the builder will keep,
        less the long tail of American film."""
        work = base[item]
        if work["kind"] in ("sport", "channel"):
            return False
        languages = {e["id"] for e in info.get("language", []) + info.get("worklang", [])}
        if work["kind"] == "film" and "in" in work["cultures"] and not (languages & core_indian) and work["links"] < 8:
            return False
        if work["cultures"] == ["us"] and work["kind"] in ("film", "tv") and work["links"] < 20:
            return False
        return True

    titled = [(item, info["enwiki"]) for item, info in details.items() if isinstance(info.get("enwiki"), str) and wanted(item, info)]
    log("works to read on Wikipedia:", len(titled))

    (DATA / "wikipedia_categories.json").write_text(json.dumps(categories([title for _, title in titled]), ensure_ascii=False))
    screen = [title for item, title in titled if base[item]["kind"] in ("film", "tv")]
    (DATA / "wikipedia_leads.json").write_text(json.dumps(leads(screen), ensure_ascii=False))
    log("done")


# ---------------------------------------------------------------------------------------------
# Songs. Separate functions from the ones above, so the film crawl's requests (which are its
# cache keys) stay exactly as they were.

SONGS = DATA / "songs"
SONG_SITES = {"en": "en.wikipedia.org", "es": "es.wikipedia.org", "fr": "fr.wikipedia.org"}
CATEGORY_NS = {"en": "Category:", "es": "Categoría:", "fr": "Catégorie:"}
# Trees whose members are theme categories even when their names do not say "about".
THEME_TREES = {"en": ("Category:Songs by theme", 0), "fr": ("Catégorie:Chanson par thème", 1)}
# A handful of well-known songs for a dry run, on each of the three Wikipedias.
SAMPLE_SONGS = [("en", "Lose Yourself"), ("en", "Despacito"), ("en", "Tujhe Dekha To"), ("en", "My Way"),
                ("es", "Bésame mucho"), ("fr", "Ne me quitte pas"), ("fr", "Comme d'habitude")]

ABOUT_SONG = {
    "en": re.compile(r"^(?:.+ )?songs about (.+)$", re.IGNORECASE),
    "es": re.compile(r"^canciones sobre (.+)$", re.IGNORECASE),
    "fr": re.compile(r"^chansons? (?:sur|évoquant|à propos d[eu]) ?(.+)$", re.IGNORECASE),
}
WRITTEN_BY = {
    "en": re.compile(r"^songs (?:written|co-written|composed) by (.+)$|^songs with (?:lyrics|music) by (.+)$", re.IGNORECASE),
    "es": re.compile(r"^canciones (?:escritas|compuestas) por (.+)$", re.IGNORECASE),
    "fr": re.compile(r"^chansons? (?:écrite|composée)s? par (.+)$", re.IGNORECASE),
}
# The film crawl's skip list (build_culture.SKIP_CATEGORY) plus what only songs have: release
# and recording categories, and their Spanish and French counterparts. A skipped category is
# left out of song_wiki.json once its writer or theme has been read from it.
SONG_SKIP = re.compile(
    r"\b(directed by|produced by|scored by|shot in|shot at|screenplays? by|written by|edited by|distributed by|pictures|"
    r"studios|productions|entertainment|films by|introduced in|endings|debuts|articles|stubs|wikipedia|pages|cs1|"
    r"use \w+ dates|commons|templates|singles|song recordings|with (?:lyrics|music) by|composed by|music videos|"
    r"sencillos?|(?:escritas|compuestas|producidas|dirigidos) por|videos musicales|artículos|"
    r"(?:écrite|composée|produite|réalisée?)s? par|clip vidéo|wikipédia|portail)\b|^singles?\b", re.IGNORECASE)

# Whole categories that name a theme, in any of the three languages: (theme, weight).
FIXED_THEMES = {
    "Protest songs": ("protest", 0.8), "Songs based on actual events": ("true events", 0.7),
    "Anti-war songs": ("anti-war", 0.8), "Political songs": ("politics", 0.7),
    "Canciones de protesta": ("protest", 0.8), "Canciones basadas en hechos reales": ("true events", 0.7),
    "Canciones contra la guerra": ("anti-war", 0.8), "Canciones antibélicas": ("anti-war", 0.8),
    "Canciones políticas": ("politics", 0.7), "Canciones navideñas": ("christmas", 0.8), "Villancicos": ("christmas", 0.8),
    "Canciones de amor": ("love", 0.8), "Canciones infantiles": ("childhood", 0.6),
    "Chanson engagée": ("protest", 0.8), "Chanson contestataire": ("protest", 0.8), "Chanson de protestation": ("protest", 0.8),
    "Chanson anti-guerre": ("anti-war", 0.8), "Chanson antimilitariste": ("anti-war", 0.8), "Chanson politique": ("politics", 0.7),
    "Chanson inspirée de faits réels": ("true events", 0.7), "Chanson d'amour": ("love", 0.8), "Chanson à boire": ("drinking", 0.8),
    "Chanson de Noël": ("christmas", 0.8), "Chanson de marins": ("sailors", 0.7), "Chant de marins": ("sailors", 0.7),
    "Chanson paillarde": ("bawdy", 0.7), "Chanson humoristique": ("humour", 0.7), "Chanson érotique": ("sex", 0.7),
    "Chant patriotique": ("patriotism", 0.8), "Chanson patriotique": ("patriotism", 0.8), "Chanson militaire": ("military", 0.7),
    "Chant révolutionnaire": ("revolution", 0.8), "Chanson révolutionnaire": ("revolution", 0.8), "Berceuse": ("lullaby", 0.7),
    "Chanson pour enfants": ("childhood", 0.6), "Chanson féministe": ("feminism", 0.8), "Chanson LGBT": ("lgbt", 0.8),
    "Holiday songs": ("holidays", 0.7), "Christmas songs": ("christmas", 0.8), "Sporting songs": ("sport", 0.7),
    "Work music": ("work", 0.6), "Love themes": ("love", 0.7), "Murder ballads": ("murder", 0.8), "Drinking songs": ("drinking", 0.8),
    "Breakup songs": ("breakup", 0.8), "Diss tracks": ("diss", 0.8), "Patriotic songs": ("patriotism", 0.8),
    "Lullabies": ("lullaby", 0.7), "Feminist songs": ("feminism", 0.8), "LGBTQ-related songs": ("lgbtq", 0.8),
    "Environmental songs": ("environment", 0.8), "Songs against racism and xenophobia": ("racism", 0.8),
    "Civil rights movement songs": ("civil rights", 0.8), "Torch songs": ("unrequited love", 0.6),
    "Chanson caritative": ("charity", 0.6), "Chanson critiquant la société de consommation": ("consumerism", 0.8),
    "Chanson critique envers la religion": ("religion", 0.7), "Chanson d'anniversaire": ("birthdays", 0.7),
    "Chanson de la Première guerre mondiale": ("world war i", 0.8), "Chanson de la Seconde guerre mondiale": ("world war ii", 0.8),
    "Chanson de voyage dans l'espace": ("space travel", 0.8), "Chanson enfantine": ("childhood", 0.6),
    "Chanson ferroviaire": ("trains", 0.8), "Chanson libertaire": ("anarchism", 0.8), "Chanson militante": ("protest", 0.8),
    "Chanson liée à la guerre d'Espagne": ("spanish civil war", 0.8), "Chanson pour un enfant": ("children", 0.7),
    "Chanson populaire lors d'un évènement sportif": ("sport", 0.6), "Chant de Noël": ("christmas", 0.8),
}
# Families of categories ("Chant patriotique allemand", "Hymne national historique").
FIXED_PREFIXES = {"Chant patriotique": ("patriotism", 0.8), "Hymne national": ("national anthem", 0.8),
                  "Canciones patrióticas": ("patriotism", 0.8), "Himnos nacionales": ("national anthem", 0.8),
                  "National anthems": ("national anthem", 0.8)}
# Spanish and French subjects whose category has no English counterpart. Leading articles are
# removed before the lookup; whatever is still unmapped is logged so this can grow.
SUBJECT_EN = {
    # Spanish
    "venganza": "revenge", "traición": "betrayal", "soledad": "loneliness", "drogas": "drugs", "dinero": "money",
    "prisión": "prison", "brutalidad policial": "police brutality", "violencia": "violence", "violencia doméstica": "domestic violence",
    "infidelidad": "infidelity", "guerra": "war", "amistad": "friendship", "angustia": "anguish", "felicidad": "happiness",
    "educación": "education", "escuela": "school", "lluvia": "rain", "naturaleza": "nature", "noche": "night",
    "paternidad": "fatherhood", "primavera": "spring", "prostitución": "prostitution", "riqueza": "wealth", "celos": "jealousy",
    "ojos": "eyes", "sueños": "dreams", "muerte": "death", "mujeres": "women", "música": "music", "músicos": "musicians",
    "nostalgia": "nostalgia", "madres": "mothers", "padres": "fathers", "hijos": "children", "hermanos": "siblings",
    "familias": "family", "suicidio": "suicide", "sexualidad": "sexuality", "depresión": "depression", "despedidas": "parting",
    "alcohol": "alcohol", "baile": "dancing", "cannabis": "cannabis", "cielo": "heaven", "diablo": "the devil",
    "infierno": "hell", "mar": "the sea", "matrimonio": "marriage", "miedo": "fear", "tiempo": "time", "verano": "summer",
    "consumismo": "consumerism", "espacio exterior": "outer space", "dios": "god", "jesús": "jesus", "belleza": "beauty",
    "besos": "kissing", "bullying": "bullying", "caballos": "horses", "perros": "dogs", "gatos": "cats", "pájaros": "birds",
    "lobos": "wolves", "zorros": "foxes", "animales": "animals", "automóviles": "cars", "trenes": "trains", "barcos": "ships",
    "carreteras": "roads", "calles": "streets", "caminar": "walking", "camiones": "trucks", "criminales": "criminals",
    "crímenes": "crime", "cumpleaños": "birthdays", "discotecas": "nightclubs", "fiestas": "parties", "flores": "flowers",
    "comida": "food", "incendios": "fire", "infancia": "childhood", "juguetes": "toys", "luna": "the moon", "tierra": "earth",
    "trastornos mentales": "mental illness", "maltrato infantil": "child abuse", "migraciones": "immigration",
    "militares": "soldiers", "mineros": "miners", "minería": "mining", "monstruos": "monsters", "montañas": "mountains",
    "policías": "police", "playas": "beaches", "ríos": "rivers", "teléfonos": "telephones", "llamadas telefónicas": "phone calls",
    "televisión": "television", "ropa": "clothing", "relojes": "clocks", "sonreír": "smiling", "religión": "religion",
    "economía": "economics", "historia": "history", "raza y etnia": "race", "agresión sexual": "sexual assault",
    "adolescentes": "teenagers", "celebridades": "celebrity", "actores": "actors", "abogados": "lawyers", "jueces": "judges",
    "toreros": "bullfighters", "marineros": "sailors", "vih/sida": "hiv/aids", "accidentes automovilísticos": "car crashes",
    "pandemia de covid-19": "covid-19 pandemic", "guerra de vietnam": "vietnam war", "domingos": "sunday", "sábados": "saturday",
    "lunes": "monday", "estaciones": "seasons", "bares": "bars", "papas": "popes", "películas": "films", "planetas": "planets",
    "plantas": "plants", "vuelos espaciales": "spaceflight", "personajes de ficción": "fictional characters",
    "pueblos indígenas": "indigenous peoples", "sexo oral": "oral sex", "nalgas": "buttocks", "jeans": "jeans",
    "disc jockeys": "disc jockeys", "oficiales militares": "military officers", "personajes históricos": "historical figures",
    # French
    "amour": "love", "arme nucléaire": "nuclear weapons", "avortement": "abortion", "immigration": "immigration",
    "dépression": "depression", "maladie": "illness", "maladie mentale": "mental illness", "mer": "the sea", "pluie": "rain",
    "prostitution": "prostitution", "sexualité": "sexuality", "voiture": "cars", "corps humain": "the body", "vélo": "cycling",
    "fesses": "buttocks", "mort": "death", "guerre": "war", "solitude": "loneliness", "trahison": "betrayal",
    "nostalgie": "nostalgia", "drogue": "drugs", "drogues": "drugs", "alcool": "alcohol", "enfance": "childhood",
    "liberté": "freedom", "femmes": "women", "femme": "women", "argent": "money", "suicide": "suicide", "prison": "prison",
    "racisme": "racism", "religion": "religion", "dieu": "god", "paris": "paris", "france": "france", "nuit": "night",
    "été": "summer", "hiver": "winter", "automne": "autumn", "printemps": "spring", "mère": "mothers", "père": "fathers",
    "famille": "family", "amitié": "friendship", "jalousie": "jealousy", "vengeance": "revenge", "rêve": "dreams",
    "rêves": "dreams", "temps": "time", "vieillesse": "old age", "danse": "dancing", "musique": "music", "train": "trains",
    "lune": "the moon", "soleil": "the sun", "ville": "cities", "exil": "exile", "pauvreté": "poverty", "travail": "work",
    "adolescence": "adolescence", "enfance maltraitée": "child abuse", "école": "school", "seconde guerre mondiale": "world war ii",
    "shoah": "the holocaust", "guerre du vietnam": "vietnam war", "violence conjugale": "domestic violence", "mariage": "marriage",
    "narcissisme": "narcissism", "sport": "sport", "téléphone": "telephones", "animaux": "animals", "vacances": "holidays",
}

# Lead-sentence phrases that tie a song to another work, read as "this song ... the target".
# Forward only: a page saying it "was sampled by" another song is left to that song's own page.
# The relation names are the ones build_songs.relation_for() reads.
LANGUAGES_EN = r"(?:Spanish|French|English|Hindi|Urdu|Tamil|Telugu|Punjabi|Bengali|Marathi|Gujarati|Italian|Portuguese|German)"
SONG_RELATIONS = {
    "en": [
        ("version of", r"\b" + LANGUAGES_EN + r"[- ](?:language )?(?:[a-z]+ )?(?:version|adaptation|translation|rendition|cover) of\b"),
        ("samples", r"\bsampl(?:es|ing)\b(?! (?:were|was|are|is|have|has)\b)"),
        ("samples", r"\bsampled from\b|\ba sample (?:of|from)\b"),
        ("interpolates", r"\binterpolat(?:es|ing|ions? (?:of|from))\b"),
        ("interpolates", r"\b(?:contains?|containing|features?|featuring|includes?|including|uses?|using|borrows?) (?:musical |lyrical )?elements (?:of|from)\b"),
        ("cover of", r"\bcover(?: version)? of\b"),
        ("recreation of", r"\brecreat(?:ed|ion|ing)(?: version)? (?:of|from)\b|\brecreated (?:version|song) of\b|\bremake of\b"),
        ("remix of", r"\bremix(?:ed version)? of\b"),
        ("answer song to", r"\banswer (?:song|record) (?:to|for)\b|\bin answer to\b"),
        ("written for", r"\b(?:written|composed|created|recorded|commissioned) (?:specifically |especially |originally |exclusively )?"
                        r"for the (?:\d{4} )?(?:[\w'-]+ ){0,3}?(?:film|movie|motion picture)\b"),
        ("from the film", r"\b(?:song|track|number|single|ghazal|qawwali|duet|bhajan|lullaby|theme) (?:in|for) the "
                          r"(?:\d{4} )?(?:[\w-]+ ){0,3}?(?:film|movie|motion picture)\b|\bfrom the (?:\d{4} )?(?:[\w-]+ ){0,4}?"
                          r"(?:film|movie|motion picture)\b"),
        ("from the film", r"\bfrom the soundtrack (?:album )?(?:of|to|for) the (?:\d{4} )?(?:[\w-]+ ){0,3}?(?:film|movie)\b"),
        ("based on", r"\b(?:loosely |partly |musically )?based on\b"),
        ("inspired by", r"\b(?:heavily |loosely |partly )?(?:inspired by|lifted from|copied from|borrowed from|plagiari[sz]ed from)\b"),
    ],
    "es": [
        ("version of", r"\bversión (?:en (?:español|castellano|inglés|francés|italiano|portugués|hindi)|española|inglesa|francesa|italiana) (?:de|del)\b"),
        ("version of", r"\badaptación (?:al (?:español|castellano|inglés|francés) )?(?:de|del)\b"),
        ("cover of", r"\b(?:es|fue) (?:una|un) (?:nueva )?(?:versión|cover) (?:de|del)\b|\bcover (?:de|del)\b"),
        ("samples", r"\b(?:contiene|incluye|utiliza|usa|toma) (?:un |una |varios |varias )?(?:samples?|muestras?|sampleos?) (?:de|del)\b|\bsamplea\b"),
        ("interpolates", r"\binterpola\b|\binterpolaci[oó]n (?:de|del)\b|\bcontiene elementos (?:de|del)\b"),
        ("remix of", r"\b(?:remix|remezcla) (?:de|del)\b"),
        ("answer song to", r"\bcanci[oó]n (?:de )?respuesta a\b"),
        ("written for", r"\b(?:compuesta|escrita|grabada|creada) (?:especialmente |originalmente )?para la pel[ií]cula\b"),
        ("from the film", r"\b(?:tema|canci[oó]n) (?:principal )?de la pel[ií]cula\b|\bbanda sonora (?:original )?de la pel[ií]cula\b"),
        ("based on", r"\bbasada en\b"),
        ("inspired by", r"\binspirada (?:en|por)\b"),
    ],
    "fr": [
        ("version of", r"\b(?:adaptation|version) (?:française|francophone|en français|anglaise|en anglais|espagnole|en espagnol|italienne) (?:de |du |d['’])"),
        ("version of", r"\badaptation (?:de |du |d['’])"),
        ("cover of", r"\b(?:une |la )reprise (?:de |du |d['’])"),
        ("samples", r"\b(?:contient|utilise|reprend|comporte) (?:un |une |des )?(?:samples?|échantillons?|extraits?) (?:de |du |d['’])"),
        ("interpolates", r"\binterpol\w* (?:de |du |d['’])"),
        ("remix of", r"\bremix (?:de |du |d['’])"),
        ("answer song to", r"\bchanson[- ]réponse (?:à|au)\b|\bréponse à la chanson\b"),
        ("written for", r"\b(?:écrite|composée|enregistrée|créée) (?:spécialement |originellement |à l['’]origine )?pour le film\b"),
        ("from the film", r"\b(?:bande originale|chanson|thème) du film\b"),
        ("based on", r"\bbasée sur\b"),
        ("inspired by", r"\binspirée (?:de |par |d['’])"),
    ],
}
SONG_RELATIONS = {site: [(name, re.compile(pattern, re.IGNORECASE)) for name, pattern in rules] for site, rules in SONG_RELATIONS.items()}
FILM_RELATIONS = {"written for", "from the film"}
# Relations whose phrases also introduce people, places and feelings: only a title is taken.
LOOSE_RELATIONS = {"inspired by", "based on"}
# "remix of the song by X", "versión del tema grabada por", "reprise de la chanson par": the
# phrase is about this song when no title follows the noun.
SELF_REFERENCE = {
    "en": re.compile(r"\s*(?:the|this|that) (?:song|track|single|record|recording|tune|composition)\b", re.IGNORECASE),
    "es": re.compile(r"\s*(?:(?:la|esta) )?canci[oó]n\b|\s*(?:(?:el|este) )?(?:tema|sencillo)\b", re.IGNORECASE),
    "fr": re.compile(r"\s*(?:(?:la|cette) )?chanson\b|\s*(?:(?:le|ce) )?(?:titre|morceau|single)\b", re.IGNORECASE),
}
# Quotation marks around a song title, in any of the three languages.
QUOTED = re.compile(r"[\"“«„]\s*([^\"“”«»„\n]{1,120}?)\s*[\"”»]")
# French and Spanish Wikipedia italicise song titles rather than quoting them.
ITALIC = re.compile(r"''(?!')([^\n]{1,120}?)''(?!')")
LANGUAGE_NAME = re.compile(LANGUAGES_EN + r"(?: language)?")
ANY_LINK = re.compile(r"(''\s*)?\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]")
NOT_A_WORK = re.compile(r"^(?:[a-z]{2,3}|file|image|category|categoría|catégorie|archivo|fichier|imagen|wikt|wiktionary|template|"
                        r"plantilla|modèle|wikipedia|wikipédia|help|ayuda|aide|portal|portail|commons|special|especial|spécial|"
                        r"anexo|user|usuario|utilisateur):|^(?:lists? of|anexo)\b|^\d{1,4}(?: in .*)?$", re.IGNORECASE)
# An unlinked quotation right after one of these words is a lyric, a slogan or a non-song work
# ("samples the line "...""), never a song title, so it is not kept.
NOT_A_TITLE = re.compile(
    r"\b(?:lines?|lyrics?|words|phrases?|chorus|hook|refrain|verses?|bars?|couplets?|catchphrase|slogan|chant|mantra|"
    r"exclamation|shout|cry|vocal|letras?|frases?|estribillo|coro|versos?|paroles?|vers|réplique|cri|"
    r"poems?|novel|book|story|speech|saying|prayer|quote|quotation|motto|essay|"
    r"poemas?|novela|libro|cuento|discurso|poèmes?|roman|livre|conte|discours|citation)\s*[:,]?\s*(?:''+\s*)?$", re.IGNORECASE)
# A quotation the sentence itself calls a song ("the 1990 song "Tamma tamma"") is a title even
# in sentence case, as Indian film song titles often are on English Wikipedia.
SONG_NOUN = re.compile(r"\b(?:songs?|tracks?|singles?|number|ghazal|qawwali|bhajan|hit|anthem|ballad|tune|canci[oó]n|tema|"
                       r"chanson|titre|morceau)\s*[:,]?\s*(?:''+\s*)?$", re.IGNORECASE)
SMALL_WORDS = {"a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet", "as", "at", "by", "from", "in", "into", "of",
               "off", "on", "onto", "out", "over", "up", "with", "to", "vs", "via", "per", "than", "till", "upon", "de", "la", "el"}


def batched(titles, size=50, budget=6000):
    """Groups of at most 50 titles whose joined URL stays short enough for the API to take."""
    batch, length = [], 0
    for title in titles:
        cost = len(urllib.parse.quote(title)) + 3
        if batch and (len(batch) == size or length + cost > budget):
            yield batch
            batch, length = [], 0
        batch.append(title)
        length += cost
    if batch:
        yield batch


def site_pages(site, params, titles, label):
    """Every page a titles query returns, batch by batch with continuation, each with the titles
    that were asked for and led to it (through normalisation and redirects)."""
    for number, batch in enumerate(batched(list(titles))):
        query = {**params, "redirects": "1", "titles": "|".join(batch)}
        moved = {}
        while True:
            data = wiki_api(SONG_SITES[site], query)
            body = data.get("query", {})
            moved.update({entry["from"]: entry["to"] for entry in body.get("normalized", []) + body.get("redirects", [])})
            asked = defaultdict(list)
            for title in batch:
                final = moved.get(title, title)
                asked[moved.get(final, final)].append(title)
            for page in body.get("pages", []):
                yield page, asked.get(page["title"], [page["title"]])
            if "continue" not in data:
                break
            query = {**query, **data["continue"]}
        if number % 40 == 0 and len(titles) > 50:
            log(" ", label, site, number * 50, "/", len(titles))


def song_categories(site, titles):
    """Title -> its visible categories, without the namespace; titles with no page are left out."""
    result = {}
    params = {"action": "query", "prop": "categories", "cllimit": "max", "clshow": "!hidden"}
    for page, asked in site_pages(site, params, titles, "categories"):
        if page.get("missing") or page.get("invalid"):
            continue
        names = [entry["title"].removeprefix(CATEGORY_NS[site]) for entry in page.get("categories", [])]
        for title in asked:
            result.setdefault(title, []).extend(names)
    return {title: list(dict.fromkeys(names)) for title, names in result.items()}


def song_leads(site, titles):
    """(title, wikitext of its opening section), one page at a time."""
    params = {"action": "query", "prop": "revisions", "rvprop": "content", "rvslots": "main", "rvsection": "0"}
    for page, asked in site_pages(site, params, titles, "leads"):
        try:
            text = page["revisions"][0]["slots"]["main"]["content"]
        except (KeyError, IndexError):
            continue
        for title in asked:
            yield title, text


def english_links(site, categories):
    """Category -> the English Wikipedia category it links to, or None."""
    result = {}
    params = {"action": "query", "prop": "langlinks", "lllang": "en", "lllimit": "max"}
    for page, asked in site_pages(site, params, [CATEGORY_NS[site] + name for name in categories], "langlinks"):
        links = [link["title"] for link in page.get("langlinks", []) if link.get("lang") == "en"]
        for title in asked:
            name = title.removeprefix(CATEGORY_NS[site])
            if links or name not in result:
                result[name] = links[0].removeprefix("Category:") if links else None
    return result


def wikidata_ids(site, titles):
    """Title -> the Wikidata id of the article it leads to, where there is one."""
    result = {}
    params = {"action": "query", "prop": "pageprops", "ppprop": "wikibase_item"}
    for page, asked in site_pages(site, params, titles, "wikidata ids"):
        item = page.get("pageprops", {}).get("wikibase_item")
        if item:
            for title in asked:
                result[title] = item
    return result


def theme_tree(site, root, depth, limit=None):
    """The categories under a theme root, `depth` levels below its direct subcategories.
    `limit` caps how many of them are opened in turn (for a dry run)."""
    found, queue, opened = set(), [(root, 0)], 0
    while queue:
        category, level = queue.pop(0)
        params = {"action": "query", "generator": "categorymembers", "gcmtitle": category, "gcmtype": "subcat",
                  "gcmlimit": "max", "prop": "categoryinfo"}
        while True:
            data = wiki_api(SONG_SITES[site], params)
            for page in data.get("query", {}).get("pages", []):
                name = page["title"].removeprefix(CATEGORY_NS[site])
                if name in found:
                    continue
                found.add(name)
                if level < depth and page.get("categoryinfo", {}).get("subcats") and (limit is None or opened < limit):
                    queue.append((page["title"], level + 1))
                    opened += 1
            if "continue" not in data:
                break
            params = {**params, **data["continue"]}
    return found


def clean_theme(text):
    text = re.sub(r"\s*\([^)]*\)", "", text).strip().lower()
    text = re.sub(r"^(?:the|a|an) ", "", text)
    return re.sub(r"\s+", " ", text).replace("\t", " ").replace("|", "/").replace(":", " -")


def strip_article(text):
    return re.sub(r"^(?:el|la|los|las|le|les|un|una|une|des|del|du)\s+|^l['’]", "", text.strip(), flags=re.IGNORECASE)


def subject_themes(subject, weight):
    """'cities in the United States' -> that, and also simply 'cities'."""
    found = [(clean_theme(subject), weight)]
    head = re.split(r" (?:in|of|during|from|by) (?:the )?[A-Z0-9]", subject)[0]
    if head != subject:
        found.append((clean_theme(head), round(weight - 0.1, 2)))
    return found


def fixed_theme(category):
    if category in FIXED_THEMES:
        return FIXED_THEMES[category]
    return next((theme for prefix, theme in FIXED_PREFIXES.items() if category.startswith(prefix)), None)


def english_themes(category, tree):
    """The themes an English category names, if it names any."""
    if fixed_theme(category):
        return [fixed_theme(category)]
    if category.lower().startswith("lists of"):
        return []  # "Lists of songs about a topic"
    about = ABOUT_SONG["en"].match(category)
    if about:
        return subject_themes(about.group(1), 0.9)
    if category in tree and not category.lower().startswith(("lists of", "songs by")):
        stripped = re.sub(r"(?:-related)? songs$", "", category, flags=re.IGNORECASE)
        if stripped != category:
            return [(clean_theme(stripped), 0.8)]
    return []


def foreign_theme_categories(site, categories, tree):
    """The Spanish or French categories worth mapping to an English theme."""
    return [c for c in categories if not fixed_theme(c) and (ABOUT_SONG[site].match(c) or c in tree)]


def foreign_themes(site, category, english, tree, unmapped):
    """The English themes a Spanish or French category names: through its English
    interlanguage link, else the hand map; logged when neither knows it."""
    if fixed_theme(category):
        return [fixed_theme(category)]
    about = ABOUT_SONG[site].match(category)
    if not about and category not in tree:
        return []
    linked = english.get(category)
    if linked:
        found = english_themes(linked, {linked} if re.search(r"\bsongs$", linked, re.IGNORECASE) else set())
        if found:
            return found
    if about:
        subject = strip_article(about.group(1))
        if subject.lower() in SUBJECT_EN:
            return [(clean_theme(SUBJECT_EN[subject.lower()]), 0.9)]
        if subject[:1].isupper():
            return [(clean_theme(subject), 0.8)]  # a person or place, named alike in English ("Eva Perón")
    unmapped[site].add(category)
    return []


def writers_from(site, categories):
    found = []
    for category in categories:
        match = WRITTEN_BY[site].match(category)
        if match:
            name = re.sub(r"\s*\([^)]*\)$", "", next(group for group in match.groups() if group)).strip()
            if name and name not in found:
                found.append(name)
    return found


def plain_lead(text):
    """The opening section as prose: no references, comments, templates, files or bold, and
    nothing set apart as a quotation or a verse (blockquote, poem, q), where lyrics would sit."""
    text = re.sub(r"<ref[^>]*/>|<ref[^>]*>.*?</ref>|<!--.*?-->", "", text, flags=re.S)
    text = re.sub(r"<(blockquote|poem|q|score)\b[^>]*>.*?</\1\s*>", " ", text, flags=re.S | re.IGNORECASE)
    # Inline templates that wrap a title keep it; an interlanguage link becomes a plain link.
    text = re.sub(r"\{\{(?:ill|interlanguage link)\|([^{}|]+)(?:\|[^{}]*)?\}\}", r"[[\1]]", text, flags=re.IGNORECASE)
    text = re.sub(r"\{\{(?:lang\|[\w-]+|lang-[\w-]+|nowrap|nobr|small|transl\|[\w-]+)\|([^{}|]*)(?:\|[^{}]*)?\}\}", r"\1", text,
                  flags=re.IGNORECASE)
    kept, depth, index = [], 0, 0
    while index < len(text):
        pair = text[index:index + 2]
        if pair == "{{":
            depth, index = depth + 1, index + 2
        elif pair == "}}" and depth:
            depth, index = depth - 1, index + 2
        else:
            if not depth:
                kept.append(text[index])
            index += 1
    text = "".join(kept)
    text = re.sub(r"\[\[(?:File|Image|Archivo|Imagen|Fichier):(?:[^\[\]]|\[\[[^\]]*\]\])*\]\]", "", text, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", "", text).replace("&nbsp;", " ").replace("'''", "")
    return re.sub(r"\[\[([^\]|]*\|)?([^\]|]+)\]\]", unlink_prose, text)


def unlink_prose(match):
    """A link on a common noun or a language ("[[Contrafactum|lyrical adaptation]]", "[[Hindi]]-language")
    is prose, not a work: its words are kept so the relation phrases can read through it. A
    quoted or italicised link is a title and stays."""
    display, target = match.group(2), (match.group(1) or "")[:-1] or match.group(2)
    if re.search(r"(?:[\"“«„]\s*|'')$", match.string[max(0, match.start() - 3):match.start()]):
        return match.group()
    if display[:1].islower() or LANGUAGE_NAME.fullmatch(display) or target == display + " language":
        return display
    return match.group()


def link_target(raw):
    target = re.sub(r"\s+", " ", raw.replace("_", " ")).strip()
    if not target or NOT_A_WORK.match(target):
        return None
    return target[0].upper() + target[1:]


def title_shaped(site, title, introduced=False):
    """Whether an unlinked quotation reads as a song title rather than a quoted line: it starts
    with a capital, and on English Wikipedia (which capitalises titles) every word but the
    small ones is capitalised too, unless the sentence has just called it a song. Quoted
    lyrics are written in sentence case mid-sentence."""
    words = re.findall(r"[^\W\d_][\w'’-]*", title)
    if not words or not words[0][0].isupper():
        return False
    if site == "en" and not introduced:
        return all(word[0].isupper() or word.lower() in SMALL_WORDS for word in words[1:])
    return True


def clause_targets(site, relation, clause):
    """The works a clause names: every quoted title (linked or not) for a song relation, else the
    first link that is not an artist ("by [[X]]", "[[X]]'s"). A film relation wants the film,
    which is italicised. Each target is (title, linked). An unlinked quotation is kept only when
    it is shaped like a title and does not follow "the line", "the phrase", "the poem" and the
    like, so no quoted lyric is ever kept as a title."""
    found = []
    if relation not in FILM_RELATIONS:
        # Quotation marks inside a link are a nickname ("[[Tameka Cottle|Tameka "Tiny" Cottle]]"),
        # not a title; they are blanked for the search, at the same length.
        bare = re.sub(r"\[\[[^\]]*\]\]", lambda m: re.sub(r"[\"“”«»„]", "_", m.group()), clause)
        spans = list(QUOTED.finditer(bare)) + (list(ITALIC.finditer(bare)) if site != "en" else [])
        previous = 0
        for match in sorted(spans, key=lambda match: match.start()):
            if match.start() < previous:
                continue  # an italic span inside a quoted one
            before, previous = clause[previous:match.start()], match.end()
            inner = clause[match.start(1):match.end(1)]
            link = re.search(r"\[\[([^\]|#]+)", inner)
            if link:
                target = link_target(link.group(1))
                if target:
                    found.append((target, True))
            else:
                title = re.sub(r"''+", "", inner).strip(" ,.")
                lead_in = re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", before)
                if 1 < len(title) <= 80 and len(title.split()) <= 12 and not NOT_A_TITLE.search(lead_in) \
                        and title_shaped(site, title, bool(SONG_NOUN.search(lead_in))):
                    found.append((title, False))
        if found:
            return found[:4]
    links = list(ANY_LINK.finditer(clause))
    if relation in FILM_RELATIONS:
        links.sort(key=lambda match: (not match.group(1), match.start()))  # italic links first
    for match in links:
        before, after = clause[:match.start()], clause[match.end():]
        if re.search(r"\b(?:by|par|por)\s*$", before, re.IGNORECASE) or re.match(r"['’]s\b", after):
            continue
        if relation in LOOSE_RELATIONS and not match.group(1):
            continue  # "inspired by Gaga's fear of men and her [[Latino (demonym)|Latino]] lovers"
        target = link_target(match.group(2))
        if target and relation in FILM_RELATIONS:
            # "''[[Dilwale Dulhania Le Jayenge (soundtrack)|...]]''": the film, not its album.
            target = re.sub(r" \((?:\d{4} )?(?:soundtrack|album|bande originale|banda sonora)\)$", "", target)
        if target:
            return [(target, True)]
    return []


def song_relations(site, text, own):
    """[relation, target title, linked] for each tie the opening section states."""
    text = plain_lead(text)
    own_title = re.sub(r"\s*\([^)]*\)$", "", own).lower()  # "Halo (Beyoncé song)" is called "Halo" in its lead
    # Phrases are looked for outside link targets ("[[8 Mile: Music from and Inspired by ...|soundtrack]]").
    search = re.sub(r"\[\[([^\]|]*)(\|?)", lambda m: "[[" + "#" * len(m.group(1)) + m.group(2), text)
    matches = sorted(((m.start(), m.end(), name) for name, pattern in SONG_RELATIONS[site] for m in pattern.finditer(search)),
                     key=lambda item: (item[0], -item[1]))
    kept = []
    for start, end, name in matches:
        if kept and start < kept[-1][1]:
            continue  # "Spanish-language cover of" is one phrase, not two
        kept.append((start, end, name))
    found = []
    for position, (start, end, name) in enumerate(kept):
        if name in FILM_RELATIONS and position and kept[position - 1][2] not in FILM_RELATIONS:
            between = re.sub(r"\[\[[^\]]*\]\]", "", QUOTED.sub("", text[kept[position - 1][1]:start]))
            if not re.search(r"\.(?=\s|$)|\n|;", between):
                continue  # "a version of "X" from the film Y": Y is X's film, not this song's
        limit = kept[position + 1][0] if position + 1 < len(kept) else len(text)
        window = text[end:min(limit, end + 160)]
        # The clause ends at the sentence's end; titles and links may hold full stops of their own.
        masked = re.sub(r"\[\[[^\]]*\]\]", lambda m: "x" * len(m.group()), window)
        masked = ITALIC.sub(lambda m: "x" * len(m.group()), QUOTED.sub(lambda m: "x" * len(m.group()), masked))
        stop = re.search(r"\.(?=\s|$)|\n|;", masked)
        clause = window[:stop.start()] if stop else window
        itself = SELF_REFERENCE[site].match(clause)
        if itself and not re.match(r"\s*[:,]?\s*(?:[\"“«„]|''|\[\[)", clause[itself.end():]):
            continue  # "a new remix of the song by [[100 gecs]]": a remix of this song, not of another
        targets = clause_targets(site, name, clause)
        if targets and targets[0][0].lower() in (own.lower(), own_title):
            continue  # "a remixed version of "Own", with elements of ...": about this song itself
        for target, linked in targets:
            if target.lower() not in (own.lower(), own_title) and [name, target, linked] not in found:
                found.append([name, target, linked])
    return found


def load_songs(limit, sites):
    """(qid, site, title) for every song with an article on one of the given Wikipedias,
    best-known first, and every site title known for any song or film (for linking)."""
    catalog = json.loads((SONGS / "song_catalog.json").read_text()) if (SONGS / "song_catalog.json").exists() else {}
    details = json.loads((SONGS / "song_details.json").read_text()) if (SONGS / "song_details.json").exists() else {}
    known = {site: {} for site in SONG_SITES}
    songs = []
    for item in dict.fromkeys(list(catalog) + list(details)):
        wikis = {}
        for source in (catalog.get(item, {}), details.get(item, {})):
            for code, title in (source.get("wikis") or {}).items():
                if isinstance(title, str) and title:
                    wikis[code.removesuffix("wiki")] = title
        for code, title in wikis.items():
            if code in known:
                known[code][title] = item
        site = next((code for code in SONG_SITES if code in wikis), None)
        if site not in sites:
            continue  # read on a Wikipedia this run leaves out
        if site:
            links = max(catalog.get(item, {}).get("links") or 0, details.get(item, {}).get("sitelinks") or 0)
            songs.append((links, item, site, wikis[site]))
    songs.sort(key=lambda song: (-song[0], song[1]))
    return [(item, site, title) for _, item, site, title in songs[:limit]], known


def known_films(known):
    """Add the film, television and book articles already catalogued, so a lead's "written for
    the film" link needs no lookup."""
    path = DATA / "catalog_details.json"
    if not path.exists():
        return
    for item, info in json.loads(path.read_text()).items():
        for key, site in (("enwiki", "en"), ("eswiki", "es"), ("frwiki", "fr")):
            if isinstance(info.get(key), str):
                known[site].setdefault(info[key], item)


def count_requests():
    """Count this run's API calls, and how many of them the cache answered."""
    counts = {"asked": 0, "cached": 0}
    fetch = common.fetch

    def counting(url, params=None, **options):
        counts["asked"] += 1
        counts["cached"] += common.cache_path(url, params)[1].exists()
        return fetch(url, params, **options)
    common.fetch = counting
    return counts


def songs_main(args):
    SONGS.mkdir(parents=True, exist_ok=True)
    requests = count_requests()
    sites = [site for site in args.sites.split(",") if site in SONG_SITES]
    if args.sample:
        songs, known = [(None, site, title) for site, title in SAMPLE_SONGS], {site: {} for site in SONG_SITES}
    else:
        songs, known = load_songs(args.limit, sites)
        if not songs:
            log("no songs with a Wikipedia article in", SONGS, "- run the song catalogue and details first, or use --sample")
            return
    songs = [song for song in songs if song[1] in sites]
    log("songs to read on Wikipedia:", len(songs), {site: sum(1 for s in songs if s[1] == site) for site in sites})

    trees = {}
    for site, (root, depth) in THEME_TREES.items():
        if site in sites:
            trees[site] = theme_tree(site, root, depth, args.tree_limit)
            log("theme tree", site, len(trees[site]), "categories")

    pages = {}  # (site, title) -> record
    for site in sites:
        titles = list(dict.fromkeys(title for _, s, title in songs if s == site))
        if not titles:
            continue
        cats = song_categories(site, titles)
        relations = {title: song_relations(site, text, title) for title, text in song_leads(site, titles)}
        log(site, len(cats), "pages with categories,", len(relations), "with an opening section")
        for title in titles:
            if title not in cats and title not in relations:
                continue  # no such page
            pages[(site, title)] = {"site": site, "categories": cats.get(title, []), "themes": [],
                                    "writers": writers_from(site, cats.get(title, [])), "relations": relations.get(title, [])}

    # Themes. Spanish and French theme categories are put into English through their own
    # interlanguage links, each asked once.
    english, unmapped, theme_map = {}, defaultdict(set), defaultdict(dict)
    for site in ("es", "fr"):
        wanted = sorted({c for (s, _), page in pages.items() if s == site
                         for c in foreign_theme_categories(site, page["categories"], trees.get(site, set()))})
        if wanted:
            english[site] = english_links(site, wanted)
    for (site, _), page in pages.items():
        themes = {}
        for category in page["categories"]:
            if site == "en":
                found = english_themes(category, trees.get("en", set()))
            else:
                found = foreign_themes(site, category, english.get(site, {}), trees.get(site, set()), unmapped)
                if category in english.get(site, {}):
                    theme_map[site][category] = [english[site][category], [phrase for phrase, _ in found]]
            for phrase, weight in found:
                if 2 < len(phrase) <= 48:
                    themes[phrase] = max(themes.get(phrase, 0), weight)
        page["themes"] = sorted(([phrase, weight] for phrase, weight in themes.items()), key=lambda pair: (-pair[1], pair[0]))
        page["categories"] = [c for c in page["categories"] if not SONG_SKIP.search(c) and not WRITTEN_BY[site].match(c)]
    for site, names in unmapped.items():
        log(f"{len(names)} {site} theme categories with no English theme (extend SUBJECT_EN or FIXED_THEMES):",
            "; ".join(sorted(names)[:40]))

    # Wikidata ids: for the sample songs themselves, and for every linked target the catalogues
    # do not already name.
    if not args.sample:
        known_films(known)
    wanted = defaultdict(set)
    for (site, title), page in pages.items():
        if args.sample:
            wanted[site].add(title)
        for _, target, linked in page["relations"]:
            if linked and target not in known[site]:
                wanted[site].add(target)
    if not args.no_resolve:
        for site, titles in wanted.items():
            known[site].update(wikidata_ids(site, sorted(titles)))
    for (site, _), page in pages.items():
        page["relations"] = [[name, target, known[site].get(target) if linked else None] for name, target, linked in page["relations"]]

    result = {}
    for item, site, title in songs:
        page = pages.get((site, title))
        item = item or known[site].get(title)
        if page and item and item not in result:
            result[item] = page
    out = args.out or SONGS / ("song_wiki.dryrun.json" if args.sample else "song_wiki.json")
    out.write_text(json.dumps(result, ensure_ascii=False))
    # Spanish and French theme category -> [its English category, the themes taken from it], to
    # check the mapping and grow the hand map.
    (out.parent / (out.stem + ".theme_map.json")).write_text(json.dumps(
        {site: dict(sorted(mapping.items())) for site, mapping in theme_map.items()}, ensure_ascii=False, indent=1))
    log(f"done: {len(result)} songs -> {out.name};", sum(1 for page in result.values() if page["themes"]), "with themes,",
        sum(1 for page in result.values() if page["writers"]), "with writers,",
        sum(1 for page in result.values() if page["relations"]), "with relations",
        f"({sum(len(page['relations']) for page in result.values())} relations);",
        f"{requests['asked']} API calls, {requests['asked'] - requests['cached']} of them over the network")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--songs", action="store_true", help="read song articles instead of films, television and books")
    parser.add_argument("--limit", type=int, default=None, help="songs: read only the N best-known songs")
    parser.add_argument("--sample", action="store_true", help="songs: a dry run on a handful of well-known songs")
    parser.add_argument("--sites", default="en,es,fr", help="songs: which Wikipedias to read (default en,es,fr)")
    parser.add_argument("--tree-limit", type=int, default=None, help="songs: open at most N subcategories of the theme trees")
    parser.add_argument("--no-resolve", action="store_true", help="songs: do not look up Wikidata ids of linked targets")
    parser.add_argument("--out", type=Path, default=None,
                        help="songs: where to write (default songs/song_wiki.json; with --sample, song_wiki.dryrun.json)")
    arguments = parser.parse_args()
    if arguments.songs:
        songs_main(arguments)
    else:
        main()
