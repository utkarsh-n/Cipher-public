#!/usr/bin/env python3
"""Step 7: hinges. The two-word phrases a word lives in, so one half can stay while the other
swaps: sweet heart -> bleeding heart -> bleeding edge -> edge node.

Sources: adjacent content words in the public-domain concordance, the words of every title,
theme and motif in the culture index, and the theme names themselves. Writes
../../Cipher/Resources/hinges.tsv: left <TAB> right <TAB> weight, sorted by left word.
"""
import re
import unicodedata
from collections import Counter

from common import ROOT, log

RESOURCES = ROOT.parent / "Cipher" / "Resources"
OUT = RESOURCES / "hinges.tsv"
STOP = set("""the a an and or of to in on at by for with from as is are was were be been it its this that these those
i you he she we they me him her us them my your his our their not no so do did does have has had but if then than
there here what which who whom when where why how all any some such very too also just only into onto over under
up down out off about after before between through during without within de la le les el los las un una une des du
et y en que con por para al del se su lo ka ki ke ko se me ne par hai hain tha thi ne ni nu no ma che chhe ane to
aur ye yeh wo woh hi bhi jo na tu tum hum main ho jab tab ya shall doth hath thee thou thy will would could should
may might must can said says saith upon unto like more most much many every each own other another same been being
having did done made make makes went gone come came go goes get got let lets one two three first last next still
yet ever never again once while though although because thus hence whom whose mine thine yours hers ours theirs
him herself himself itself myself yourself ourselves themselves against toward towards around along across
est sont ont fait était être avoir cette ces son sa ses leur leurs nous vous ils elles qui quoi dont où mais
era eran fue fueron son está están este esta esto ese esa eso aquel sus nos les""".split())
WORD = re.compile(r"[^\W\d_]+(?:['’][^\W\d_]+)?")


def words(text):
    return [w.lower() for w in WORD.findall(unicodedata.normalize("NFC", text))]


def main():
    pairs = Counter()
    lines = RESOURCES / "culture-lines.tsv"
    seen = 0
    for line in open(lines, encoding="utf-8"):
        fields = line.rstrip("\n").split("\t")
        if len(fields) < 6:
            continue
        tokens = words(fields[5])
        seen += 1
        for left, right in zip(tokens, tokens[1:]):
            if left in STOP or right in STOP or len(left) < 3 or len(right) < 3:
                continue
            pairs[(left, right)] += 1
    log("concordance lines read:", seen, " distinct pairs:", len(pairs))
    from_lines = {pair: count for pair, count in pairs.items() if count >= 2}

    # Titles, themes and motifs: a phrase that names a work or an idea is a hinge in its own right.
    titled = Counter()
    for line in open(RESOURCES / "culture-works.tsv", encoding="utf-8"):
        fields = line.rstrip("\n").split("\t")
        if len(fields) < 15:
            continue
        weight = (int(fields[4]) if fields[4].isdigit() else 0) / 100
        phrases = [fields[5], fields[6]] + [t.split(":")[0] for t in fields[10].split("|")] + fields[11].split("|")
        for phrase in phrases:
            tokens = words(phrase)
            for left, right in zip(tokens, tokens[1:]):
                if left in STOP or right in STOP or len(left) < 3 or len(right) < 3:
                    continue
                titled[(left, right)] += 1 + weight
    for line in open(RESOURCES / "culture-themes.tsv", encoding="utf-8"):
        tokens = words(line.split("\t")[0])
        for left, right in zip(tokens, tokens[1:]):
            if left not in STOP and right not in STOP:
                titled[(left, right)] += 2

    rows = {}
    for pair, count in from_lines.items():
        rows[pair] = min(1.0, 0.3 + 0.1 * count)
    for pair, count in titled.items():
        rows[pair] = max(rows.get(pair, 0), min(1.0, 0.5 + 0.1 * count))
    ordered = sorted(rows.items(), key=lambda item: (item[0][0].encode("utf-8"), item[0][1].encode("utf-8")))
    OUT.write_text("\n".join(f"{left}\t{right}\t{weight:.2f}" for (left, right), weight in ordered) + "\n", encoding="utf-8")
    log(f"{len(ordered)} hinges -> {OUT.name} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
