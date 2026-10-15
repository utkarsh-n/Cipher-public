# Tagging a batch of works

Cipher is a lyric-writing app. A writer looks up a word and sees which films, shows and books
are *about* it, what those works have come to stand for, how they feel, and which works in
other cultures are their siblings. Wikidata and Wikipedia supply the facts; this pass supplies
the judgement, for the best-known works, from the tagger's own knowledge.

## Input

`Tools/data/culture/tag_batches/batch_NN.tsv`, one work per line, tab-separated:

    Wikidata id, title, year, kind (film / tv / book / song), culture, maker, one-line description

Cultures: `us` American and English-language, `in` Indian, `es` Spanish-language,
`fr` French-language.

## Output

`Tools/data/culture/tags/batch_NN.jsonl`: one JSON object per line, one line per work you
actually know.

    {"q": "Q47703", "themes": ["family loyalty", "power", "corruption", "immigrant ambition", "succession"], "motifs": ["oranges", "closed door", "the kissed ring"], "meaning": "power as a family business that damns whoever inherits it", "mood": ["operatic", "ominous"], "siblings": [{"title": "Sarkar", "year": 2005, "relation": "remade as", "strength": 0.9}, {"title": "Dharmatma", "year": 1975, "relation": "inspired", "strength": 0.8}]}

- `q`: the id from the input line, unchanged.
- `themes`: 4 to 6. What the work is about, as short lowercase phrases a lyricist would type
  or think: "revenge", "forbidden love", "caste", "class war", "exile", "fame". Ideas rather
  than plot. One to three words each, most central first, in English.
- `motifs`: 2 to 4. Concrete images, symbols or metaphors the work is remembered for:
  "green light", "the last train", "rain", "mirror", "white whale". One to three words each.
- `meaning`: at most 12 words, lowercase, without the title. What the work has come to stand
  for, the shorthand people reach for when they invoke it.
- `mood`: 2 or 3 single words for how it feels: "melancholy", "swaggering", "feverish".
- `siblings`: 0 to 4 works strongly related to this one, **above all across cultures**:
  remakes (credited or not), adaptations of the same source, works that borrow its story,
  style or music, and its counterpart in another culture. Bollywood and Hollywood borrowing
  from each other, in either direction, is exactly what this is for; so are French and
  Spanish-language originals and their American remakes.
  - `title`: the common English or romanised title, as English Wikipedia has it. `year`: its release year.
  - `relation`, read as "this work is ... the sibling": `remake of`, `remade as`, `based on`,
    `adapted as`, `inspired by`, `inspired`, `counterpart`.
  - `strength`: 1.0 official remake or adaptation; 0.8 acknowledged heavy borrowing;
    0.6 clear thematic or stylistic sibling; 0.4 loose kinship.
  - Leave `[]` when nothing real comes to mind. A wrong sibling is worse than none.

## Rules

- Your own knowledge only. No web search, no other files.
- Skip a work you do not recognise with confidence: omit its line. The description and maker
  are there to tell works with the same title apart. Do not guess from the title.
- Valid JSON on every line; no code fence, no trailing commas, no blank lines.
- Do not copy text from the works; themes and meanings are your own words.
- When the file is written, check that every line parses and carries all six keys, then
  report how many works you tagged, how many you skipped, and the three cross-cultural
  sibling pairs you are surest of.

## Songs

Batches can also hold songs (kind `song`; maker is the performer; the description names the
album or film, the writers and the language). Tag them the same way, with these differences:

- **Never quote or paraphrase lyrics, not even a hook or a title drop.** Themes and meaning say
  what the song is about in your own words; nothing in any field may be a line from the song.
- `themes`: what the song is about: "heartbreak", "hustle", "hometown pride", "police
  violence", "longing for the beloved". For a film song, what the song is about, not the film.
- `motifs`: images and symbols the song is known for as ideas ("rain", "the moon", "a train
  leaving", "diamonds"), never words sung in it.
- `meaning`: what the song has come to stand for: "the anthem of a summer", "a wedding staple",
  "the sound of 1970s Bombay cabaret".
- `mood`: how it feels and moves: "swaggering", "aching", "euphoric", "menacing".
- `siblings`, read as "this song ... the sibling": `samples`, `sampled by`, `interpolates`,
  `cover of`, `covered as`, `version of` (a translated or re-language version), `other
  version`, `inspired by` (borrowed its tune or hook), `inspired`, `answer song to`,
  `counterpart`. Bollywood songs built on Western, Arabic, Turkish or Latin originals, the hip-hop
  records that sampled Indian film songs, and Spanish or French versions of English hits are what
  this is for. Strength: 1.0 credited sample, cover or version; 0.8 well-documented borrowing;
  0.6 clear kinship; 0.4 loose. A sibling outside the four cultures is fine: give its title and
  year as English Wikipedia has them.
- Skip a regional or older song you are not sure of rather than guess.
