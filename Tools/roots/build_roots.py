"""Builds Cipher/Resources/roots.tsv: the Latin, Ancient Greek, Sanskrit and Proto-Indo-European
roots behind words in the app's five languages, and every word in those languages that shares one.

    python3 build_roots.py            # reads Tools/data/roots_raw (or Tools/data/roots) from extract.py

Two kinds of family:
  etymon  a classical word a modern word came from: Latin lūx, Greek φωνή, Sanskrit बुद्ध
  root    the deeper root those etyma grow from: PIE *lewk-, the Sanskrit dhatu बुध्

A modern word reaches its etyma directly ({{inh|es|la|lūx}}) or through the languages in between
(Spanish ← Old Spanish ← Latin, Hindi ← Prakrit ← Sanskrit), walked up to three steps. An etymon
belongs to the roots it was seen with: its own dictionary entry's root links, the root of the PIE
word it came from, or the roots named on the same modern word's page. So "lucid" reaches "luz",
"lumière" and Sanskrit रुच् through *lewk-.

Output, one family per line, tab-separated:
  key  kind  lang  form  roman  gloss  roots(key|key)  members(lang:word|...)
Members are ordered commonest first and capped, so a vast root keeps its everyday words.
"""
import collections
import json
import re
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "roots_raw"
LOCAL = ROOT / "data" / "roots"
DATA = ROOT / "data"
OUT = ROOT.parent / "Cipher" / "Resources" / "roots.tsv"
APP = ("en", "es", "fr", "hi", "gu")
CLASSICAL = ("la", "grc", "sa", "ine-pro")
MAX_MEMBERS = 300
MAX_HOPS = 3


def fold(lang, form):
    """The key a form is matched on: no length marks or accents for anything in Latin script or
    Greek, Indic scripts as written."""
    form = unicodedata.normalize("NFC", form.strip())
    if lang.endswith("-pro") and not form.startswith("*"):
        form = "*" + form  # reconstructions are written with and without the asterisk
    if lang not in ("sa", "hi", "gu", "pra", "pi") and not lang.startswith(("pra-", "inc-")):
        stripped = "".join(c for c in unicodedata.normalize("NFD", form) if not unicodedata.combining(c))
        form = unicodedata.normalize("NFC", stripped).lower()
    return f"{lang}:{form}"


SCRIPT = {
    "en": re.compile(r"^[a-zà-öø-ÿ][a-zà-öø-ÿ' .-]*$"), "es": re.compile(r"^[a-zà-öø-ÿ][a-zà-öø-ÿ' .-]*$"),
    "fr": re.compile(r"^[a-zà-öø-ÿœæ][a-zà-öø-ÿœæ' .-]*$"),
    "hi": re.compile(r"^[\u0900-\u097F][\u0900-\u097F ]*$"), "gu": re.compile(r"^[\u0A80-\u0AFF][\u0A80-\u0AFF ]*$"),
}


def is_word(lang, word):
    """A whole word in its own script: not an affix ("-leigh"), not a stray foreign headword."""
    return bool(SCRIPT[lang].match(word)) and not word.endswith("-") and len(word) > 1


def is_affix(key):
    """An affix's key: its form starts or ends with a hyphen (a PIE root also ends with one, but
    roots are never etyma here)."""
    form = key.split(":", 1)[1]
    return form.startswith("-") or form.endswith("-")


def read(lang):
    for folder in (RAW, LOCAL):
        path = folder / f"{lang}.jsonl"
        if path.exists():
            with path.open() as handle:
                return [json.loads(line) for line in handle]
    return []


def frequencies():
    """How common each word is, per app language, from the frequency lists already on disk."""
    found = {language: {} for language in APP}

    def plain(path, language, word_column, count_column, sep=" "):
        if not path.exists():
            return
        for line in path.open(errors="ignore"):
            fields = line.rstrip("\n").split(sep)
            if len(fields) > max(word_column, count_column):
                try:
                    found[language][fields[word_column]] = float(fields[count_column])
                except ValueError:
                    pass

    plain(DATA / "en_50k.txt", "en", 0, 1)
    plain(DATA / "es_50k.txt", "es", 0, 1)
    plain(DATA / "hi_full.txt", "hi", 0, 1)
    plain(DATA / "gu_words.txt", "gu", 1, 2, sep="\t")
    lexique = DATA / "Lexique383.tsv"
    if lexique.exists():
        rows = lexique.open().read().splitlines()
        header = rows[0].split("\t")
        ortho, films = header.index("ortho"), header.index("freqfilms2")
        for row in rows[1:]:
            fields = row.split("\t")
            try:
                found["fr"][fields[ortho]] = max(found["fr"].get(fields[ortho], 0), float(fields[films]))
            except (ValueError, IndexError):
                pass
    return found


def main():
    freq = frequencies()
    forms = collections.defaultdict(collections.Counter)     # key -> display forms seen
    romans = collections.defaultdict(collections.Counter)
    glosses = collections.defaultdict(collections.Counter)   # key -> glosses from links
    headword_gloss = {}                                       # key -> gloss from the language's own entry
    kinds = {}                                                # key -> "root" | "etymon"
    members = collections.defaultdict(set)                    # key -> {"en:lucid", ...}
    parents = collections.defaultdict(collections.Counter)    # etymon key -> root keys seen with it
    member_gloss = {}
    entries = collections.defaultdict(list)                   # key -> link lists of that entry (any kept language)

    # Every non-app entry: the root languages carry meanings and their own root links, the
    # languages in between carry the next step of a chain.
    languages = sorted({path.stem for folder in (RAW, LOCAL) if folder.exists() for path in folder.glob("*.jsonl")} - set(APP))
    for lang in languages:
        for entry in read(lang):
            key = fold(lang, entry["w"])
            entries[key].append(entry.get("e", []))
            if lang in CLASSICAL:
                forms[key][entry["w"]] += 1
                if entry.get("r"):
                    romans[key][entry["r"]] += 1
                if entry.get("g") and key not in headword_gloss:
                    headword_gloss[key] = entry["g"][0]
                if lang == "ine-pro" and entry.get("p") == "root":
                    kinds[key] = "root"

    def walk(links, depth=0, seen=None):
        """The root-language links a word reaches, directly or through the languages in between."""
        seen = seen if seen is not None else set()
        reached = []
        for link in links:
            kind, source, term = link[0], link[1], link[2]
            if source in CLASSICAL:
                reached.append(link)
            elif depth < MAX_HOPS:
                key = fold(source, term)
                if key in seen:
                    continue
                seen.add(key)
                for own in entries.get(key, []):
                    reached += walk(own, depth + 1, seen)
        return reached

    # A PIE root's page lists what grew from it: Latin lūx, Greek λευκός, English light.
    for lang in CLASSICAL:
        for entry in read(lang):
            if not entry.get("d"):
                continue
            key = fold(lang, entry["w"])
            is_root = lang == "ine-pro" and entry.get("p") == "root" or lang == "sa" and entry.get("p") == "root"
            if is_root:
                kinds[key] = "root"
            for descendant_lang, word in entry["d"]:
                if descendant_lang in CLASSICAL and is_root:
                    child = fold(descendant_lang, word)
                    kinds.setdefault(child, "etymon")
                    forms[child][word] += 1
                    parents[child][key] += 3
                elif descendant_lang in APP and is_root:
                    word = word if descendant_lang in ("hi", "gu") else word.lower()
                    if is_word(descendant_lang, word):
                        members[key].add(f"{descendant_lang}:{word}")

    # The classical words' own links tie an etymon to its roots (and a PIE word to its root).
    for key, link_lists in list(entries.items()):
        lang = key.split(":", 1)[0]
        if lang not in CLASSICAL:
            continue
        for links in link_lists:
            for kind, source, term, tr, gloss in walk(links):
                target = fold(source, term)
                if target == key:
                    continue
                if kind == "root":
                    kinds[target] = "root"
                    forms[target][term] += 1
                    if gloss:
                        glosses[target][gloss] += 1
                    parents[key][target] += 2
                elif source == "ine-pro":
                    # Latin lūx from PIE *lówks: the PIE word's own root becomes this one's too.
                    parents[key][target] += 1
                    kinds.setdefault(target, "etymon")
                    forms[target][term] += 1

    # The modern words.
    for lang in APP:
        for entry in read(lang):
            word = entry["w"].strip()
            if not word or (lang in ("en", "es", "fr") and len(word.split()) > 2):
                continue
            word = word if lang in ("hi", "gu") else word.lower()
            if not is_word(lang, word):
                continue
            member = f"{lang}:{word}"
            if entry.get("g") and member not in member_gloss:
                member_gloss[member] = entry["g"][0]
            etyma, roots = [], []
            for kind, source, term, tr, gloss in walk(entry.get("e", [])):
                key = fold(source, term)
                forms[key][term] += 1
                if tr:
                    romans[key][tr] += 1
                if gloss:
                    glosses[key][gloss] += 1
                if kind == "root":
                    kinds[key] = "root"
                    roots.append(key)
                else:
                    kinds.setdefault(key, "etymon")
                    etyma.append(key)
            # Affixes (-tiō, re-, -ίᾱ) are not origins a writer would stand in, and they would
            # gather the roots of every word they help form.
            etyma = [key for key in etyma if not is_affix(key)]
            for key in set(etyma + roots):
                members[key].add(member)
            # A page's roots belong to its main etymon (the first named), not to every word in
            # the chain, so a homograph's or a compound's other parts do not inherit them.
            if etyma:
                for root in set(roots):
                    if root != etyma[0]:
                        parents[etyma[0]][root] += 1

    def resolved_roots(key, depth=0):
        """An etymon's roots, following a PIE word to its own root."""
        found = []
        for parent, _ in parents[key].most_common(4):
            if kinds.get(parent) == "root":
                found.append(parent)
            elif depth < 2 and parent.startswith("ine-pro:"):
                found += resolved_roots(parent, depth + 1)
        return list(dict.fromkeys(found))[:3]

    def commonness(member):
        lang, word = member.split(":", 1)
        return freq.get(lang, {}).get(word, 0)

    lines, dropped = [], 0
    for key, kind in sorted(kinds.items()):
        if kind == "etymon" and is_affix(key):
            continue
        own = members.get(key, set())
        roots = resolved_roots(key) if kind == "etymon" else []
        if not own and not roots:
            continue
        if len(own) > MAX_MEMBERS:
            dropped += len(own) - MAX_MEMBERS
        ordered = sorted(own, key=lambda m: (-commonness(m), m))[:MAX_MEMBERS]
        lang = key.split(":", 1)[0]
        form = forms[key].most_common(1)[0][0] if forms[key] else key.split(":", 1)[1]
        roman = romans[key].most_common(1)[0][0] if romans[key] else ""
        gloss = headword_gloss.get(key) or (glosses[key].most_common(1)[0][0] if glosses[key] else "")
        if not gloss and kind == "etymon":
            # A word taken over unchanged (Hindi बुद्धि from Sanskrit बुद्धि) keeps the meaning.
            same = [m for m in own if m.split(":", 1)[1] == form and m in member_gloss]
            if same:
                gloss = member_gloss[same[0]]
        clean = lambda text: text.replace("\t", " ").replace("\n", " ").replace("|", "/")
        lines.append("\t".join([key, kind, lang, clean(form), clean(roman), clean(gloss)[:120],
                                "|".join(roots), "|".join(ordered)]))
    OUT.write_text("\n".join(lines) + "\n")
    counts = collections.Counter(line.split("\t")[1] + ":" + line.split("\t")[2] for line in lines)
    words = {m for line in lines for m in line.split("\t")[7].split("|") if m}
    print(f"{len(lines)} families -> {OUT} ({OUT.stat().st_size / 1e6:.1f} MB); {dropped} rare members over the cap left out")
    print("  by kind and language:", dict(counts.most_common()))
    print("  modern words with a root:", dict(collections.Counter(w.split(":")[0] for w in words)))
    print("  with a meaning:", sum(1 for line in lines if line.split("\t")[5]))


if __name__ == "__main__":
    main()
