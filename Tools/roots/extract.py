"""Streams a kaikki.org (Wiktextract) dictionary file and keeps only what the roots layer needs:
headword, part of speech, a short gloss, the Roman spelling, and every etymology or root link
that reaches Latin, Ancient Greek, Sanskrit or Proto-Indo-European, or one of the languages in
between (Old French, Old Spanish, Prakrit...) through which a chain can be walked to them.

    python3 extract.py <file.jsonl | https://...jsonl> <out.jsonl> [--all]
    python3 extract.py --raw <raw-wiktextract-data.jsonl.gz | its URL> <out folder>

A URL is streamed through curl (and gzip -dc for the .gz raw dump), so the multi-gigabyte files
never land on disk. --all keeps every entry of a root-language file even with no outward link:
those entries are the etyma themselves and carry the meanings. --raw reads the all-language dump
once and writes one <lang>.jsonl per language the roots layer uses into the out folder.
"""
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

USER_AGENT = "CipherLyricsApp/0.2 (personal, non-commercial lyric-writing tool)"

# Wiktionary's etymology templates that say "this word comes from that one".
LINKS = {"inh", "inh+", "bor", "bor+", "lbor", "slbor", "obor", "der", "der+", "uder",
         "learned borrowing", "semi-learned borrowing", "inherited", "borrowed", "derived"}
ROOT = {"root"}
AFFIX = {"af", "affix", "prefix", "suffix", "confix", "compound", "com", "surf"}

# The app's own languages, the four root languages, and the languages between them that a
# chain can pass through. Entries in every one of these are kept from the raw dump.
APP = {"en", "es", "fr", "hi", "gu"}
INTERMEDIATE = {"osp", "fro", "frm", "enm", "ang", "pra", "pi", "inc-ogu", "inc-ohi", "inc-mgu", "inc-pro",
                "iir-pro", "itc-pro", "grk-pro", "gem-pro", "la-vul", "la-lat", "la-med", "la-new", "ML.", "LL.", "VL.", "NL."}
# Template codes some editors use for Latin periods.
LATIN_ALIASES = {"LL.", "VL.", "ML.", "NL.", "CL.", "EL.", "RL."}


def root_language(code):
    """The four root languages, with their period variants folded in."""
    if not code:
        return None
    if code == "la" or code.startswith("la-") or code in LATIN_ALIASES:
        return "la"
    if code == "grc" or code.startswith("grc-") or code == "gkm":
        return "grc"
    if code == "sa" or code.startswith("sa-"):
        return "sa"
    if code == "ine-pro":
        return "ine-pro"
    return None


def kept_language(code):
    """A link worth keeping: to a root language, or to one a chain can pass through."""
    root = root_language(code)
    if root:
        return root
    if code in INTERMEDIATE or (code or "").startswith("pra-"):
        return code
    return None


def clean(term):
    """A linked term as written in the template, without wiki markup, ids or a trailing gloss;
    empty for a bare hyphen or other non-word."""
    if not term:
        return ""
    term = term.split("<")[0].strip()
    if term.startswith("w:") or term.startswith(":"):
        return ""
    term = unicodedata.normalize("NFC", term)
    return term if term.strip("-–*").strip() else ""


def roman_of(entry):
    for form in entry.get("forms", []):
        if "romanization" in (form.get("tags") or []):
            return form.get("form", "")
    return ""


def gloss_of(entry, limit=2):
    found = []
    for sense in entry.get("senses", []):
        for gloss in sense.get("glosses", [])[:1]:
            if gloss and gloss not in found:
                found.append(gloss)
        if len(found) >= limit:
            break
    return found


def links_of(entry):
    """[kind, language, term, transliteration, gloss] for every link worth keeping."""
    links = []
    for template in entry.get("etymology_templates") or []:
        name, args = template.get("name", ""), template.get("args") or {}
        if name in LINKS or name in ROOT:
            source = kept_language(args.get("2", ""))
            if not source:
                continue
            terms = [args.get("3", "")] if name in LINKS else [args.get(str(i), "") for i in range(3, 8)]
            for term in terms:
                term = clean(term)
                if term:
                    kind = "root" if name in ROOT else name.rstrip("+")
                    links.append([kind, source, term, args.get("tr", ""), args.get("t", "") or args.get("5", "") or args.get("gloss", "")])
        elif name == "etymon":
            # {{etymon|hi|:inh|pra:term<id:colour>|...}}: relation markers start with ":",
            # each following "lang:term" is linked by the last marker seen.
            kind = "inh"
            for i in range(2, 10):
                value = args.get(str(i), "")
                if not value:
                    continue
                if value.startswith(":"):
                    kind = value[1:] or kind
                    continue
                lang, _, term = value.partition(":")
                source = kept_language(lang)
                term = clean(term)
                if source and term:
                    gloss = re.search(r"<t:([^>]*)>", value)
                    links.append([kind, source, term, "", gloss.group(1) if gloss else ""])
        elif name in AFFIX:
            # A morpheme split that names a classical part: "tele- + phōnē".
            lang = args.get("1", "")
            for i in range(2, 8):
                part = clean(args.get(str(i), ""))
                source = root_language(args.get(f"lang{i - 1}", "")) or root_language(lang)
                if part and source:
                    links.append(["affix", source, part, args.get(f"tr{i - 1}", ""), args.get(f"t{i - 1}", "")])
    return links


def lines(source):
    if source.startswith("http"):
        curl = subprocess.Popen(["curl", "-sS", "-L", "--compressed", "-A", USER_AGENT, source], stdout=subprocess.PIPE)
        stream = curl.stdout
        unzip = None
        if source.endswith(".gz"):
            unzip = subprocess.Popen(["gzip", "-dc"], stdin=curl.stdout, stdout=subprocess.PIPE)
            curl.stdout.close()
            stream = unzip.stdout
        for raw in stream:
            yield raw
        for process in (unzip, curl):
            if process:
                process.wait()
        if curl.returncode not in (0, None):
            raise SystemExit(f"curl failed with {curl.returncode} for {source}")
    elif source.endswith(".gz"):
        unzip = subprocess.Popen(["gzip", "-dc", source], stdout=subprocess.PIPE)
        yield from unzip.stdout
        unzip.wait()
    else:
        with open(source, "rb") as handle:
            yield from handle


def descendants_of(entry, limit=400):
    """[lang, word] for every descendant a root's page lists in the root languages or the app's
    languages: a PIE root's page names Latin lūx, Greek λευκός and English light under it."""
    found, stack = [], list(entry.get("descendants") or [])
    while stack and len(found) < limit:
        item = stack.pop()
        if not isinstance(item, dict):
            continue
        stack += item.get("descendants") or []
        code = item.get("lang_code", "")
        language = root_language(code) or (code if code in APP else None)
        word = clean(item.get("word", ""))
        if language and word:
            found.append([language, word])
    return found


def record(entry, links):
    found = {"w": unicodedata.normalize("NFC", entry.get("word", "")), "l": entry.get("lang_code", ""),
             "p": entry.get("pos", ""), "g": gloss_of(entry), "r": roman_of(entry), "e": links}
    if root_language(entry.get("lang_code", "")):
        descendants = descendants_of(entry)
        if descendants:
            found["d"] = descendants
    return found


def is_inflection(entry):
    senses = entry.get("senses") or []
    return bool(senses) and all(sense.get("form_of") or "form-of" in (sense.get("tags") or []) for sense in senses)


def wanted(code):
    return code in APP or bool(root_language(code)) or code in INTERMEDIATE or code.startswith("pra-")


# Every lang_code in a raw line, read without parsing it.
LANG_CODE = re.compile(rb'"lang_code":\s*"([^"]+)"')


def raw(source, folder):
    """One pass over the all-language dump: every app-language entry with a kept link, and every
    entry of a root or in-between language (those carry the meanings and the next link)."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    sinks, kept, seen = {}, {}, 0
    for line in lines(source):
        seen += 1
        if seen % 1_000_000 == 0:
            print(f"{seen:,} read; kept " + ", ".join(f"{k} {v:,}" for k, v in sorted(kept.items())), file=sys.stderr, flush=True)
        # A line carries the entry's own lang_code and also those of its translations and
        # descendants (Latin lūx lists Spanish luz), in no fixed order, so the raw text only
        # says whether a language we want is mentioned at all; the parsed entry says whose it is.
        if not any(wanted(code.decode()) for code in LANG_CODE.findall(line)):
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        code = entry.get("lang_code", "")
        root = root_language(code)
        is_app = code in APP
        if not wanted(code):
            continue
        links = links_of(entry)
        if is_app and not links:
            continue
        if not is_app and not links and is_inflection(entry):
            # "lūcis, genitive of lūx": the lemma carries the meaning and the links.
            continue
        name = root or code
        if name not in sinks:
            sinks[name] = open(folder / f"{name.replace('.', '')}.jsonl", "w")
        sinks[name].write(json.dumps(record(entry, links), ensure_ascii=False) + "\n")
        kept[name] = kept.get(name, 0) + 1
    for sink in sinks.values():
        sink.close()
    print(f"{seen:,} entries read; kept " + ", ".join(f"{k} {v:,}" for k, v in sorted(kept.items())), file=sys.stderr)


def main():
    if sys.argv[1] == "--raw":
        raw(sys.argv[2], sys.argv[3])
        return
    source, out = sys.argv[1], sys.argv[2]
    keep_all = "--all" in sys.argv
    kept = seen = 0
    with open(out, "w") as sink:
        for line in lines(source):
            seen += 1
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            links = links_of(entry)
            if not links and not keep_all:
                continue
            sink.write(json.dumps(record(entry, links), ensure_ascii=False) + "\n")
            kept += 1
    print(f"{source}: {seen} entries read, {kept} kept -> {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
