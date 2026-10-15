#!/bin/sh
# Compiles the lexicon tool against the app's own Engine sources and rebuilds
# Cipher/Resources/lexicon.bin and signs.tsv from the raw data in Tools/data.
#
#   Tools/build_lexicon.sh          rebuild the lexicon
#   Tools/build_lexicon.sh eval     score the Hindi/Gujarati script readers against Wiktionary
set -e
cd "$(dirname "$0")/.."
ENGINE=Cipher/Engine
BIN="${TMPDIR:-/tmp}/cipher-lexgen"
swiftc -O -o "$BIN" \
  $ENGINE/Phoneme.swift $ENGINE/Language.swift $ENGINE/IndicG2P.swift $ENGINE/SpanishG2P.swift \
  $ENGINE/FrenchG2P.swift $ENGINE/LexiconFormat.swift Tools/lexgen/*.swift
# The translation tables come out of the WikDict SQLite files.
for pair in es fr; do
  [ -f Tools/data/${pair}_en.tsv ] || sqlite3 -separator "$(printf '\t')" Tools/data/${pair}-en.sqlite3 \
    "select written_rep, trans_list from simple_translation" > Tools/data/${pair}_en.tsv
done
if [ "$1" = "eval" ]; then
  "$BIN" eval Tools/data
else
  "$BIN" build Tools/data Cipher/Resources
fi
