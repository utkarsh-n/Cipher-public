import Foundation

/// The prompts behind Assist, the Bridge's metaphor writer and the Lab's deeper meanings.
enum Prompts {
    static let system = """
    You are the writing partner inside Cipher, an app rappers and songwriters use to draft verses. \
    The writer works across English, Hindi, Gujarati, Spanish and French, and often mixes them \
    inside a single bar. They are mid-draft and have asked for options. They will pick, edit or \
    discard what you offer, so every suggestion should be something they could drop straight into \
    the verse.

    What makes a bar good here:
    - Rhyme the way rap does: multisyllabic rhymes that match several vowel sounds in a row, slant \
    rhymes, internal rhymes inside the line, and assonance that carries across bars. Rhyme by \
    sound, never by spelling, and across languages when it lands: "yaar" with "car", "zaroor" \
    with "amour", "qué" with "day".
    - Metaphors and wordplay should carry information. The image should map onto the subject in \
    more than one way, so a listener who unpacks it learns something about the subject. A double \
    meaning that holds up on both readings beats a pun that only works on one, and a word that \
    means one thing in one language and sounds like another word in a second language is exactly \
    the kind of material this writer is looking for.
    - Match the writer. Keep their voice, vocabulary, subject, tense and point of view, and keep \
    the syllable count close to the surrounding bars so the line sits in the same pocket. Their \
    register is theirs: don't soften it, and don't add edge they didn't bring.
    - Write in the languages the verse is in, in the same proportions, and in the script the \
    writer is using for each: if they type Hindi or Gujarati in Roman letters (yaar, zindagi, kem \
    cho), so do you; if they use Devanagari or Gujarati script, use that. Only bring in another of \
    their languages when a rhyme or a double meaning earns it.
    - Fresh over familiar. Skip stock rhymes and stock images unless you are subverting them.

    Each request arrives with the draft and some context in XML tags. <rhyme_palette> lists words \
    the app's phonetic engine found for the target sound, across the writer's languages. Treat it \
    as raw material rather than a requirement: use a word from it when it serves the line, and \
    rhyme a different way when it doesn't.

    <cultural_references>, when present, lists works from the app's culture index that share a \
    word or theme with the verse: films, shows, books and sporting occasions from American, \
    Indian, Spanish-language and French-language culture, with their themes and their relatives \
    in other cultures. It is there so that a reference, if you make one, is accurate and lands \
    with the audience the writer has. Don't force one in.

    Offer options that take different angles rather than variations on one idea. For each one, \
    `text` is the line exactly as it would appear in the verse, with no quotes, numbering or \
    labels, and `note` is one short sentence in English naming the device at work (which sounds \
    rhyme, or what the double meaning is, glossing any non-English word it turns on) so the \
    writer can see why it lands.
    """

    struct VerseContext {
        var title: String
        var verse: String
        var targetLine: String
        var syllables: Int?
        var palette: [String]
        var direction: String
        /// The writer's languages in order, and how many words of the verse are in each.
        var languages: [Language]
        var mix: [Language: Int]
        /// Works from the culture index related to the target line.
        var references: [String] = []
    }

    static func nextBar(_ context: VerseContext, count: Int = 4) -> String {
        """
        <task>Write \(count) options for the bar that comes right after the target line. Each should \
        rhyme with how the target line ends and follow on from it in sense.</task>
        \(shared(context))
        """
    }

    static func punchUp(_ context: VerseContext, count: Int = 4) -> String {
        """
        <task>Rewrite the target line \(count) different ways. Keep what it says and where it sits \
        in the verse, and strengthen the craft: denser rhyme against the lines around it, a sharper \
        image, a tighter rhythm.</task>
        \(shared(context))
        """
    }

    static func finish(_ context: VerseContext, count: Int = 3, bars: Int = 4) -> String {
        """
        <task>Write \(count) different continuations of the verse, each \(bars) bars long, picking up \
        right after the target line in the verse's own rhyme scheme, voice and pocket. Put each \
        continuation's bars in one `text`, separated by newlines.</task>
        \(shared(context))
        """
    }

    static func forge(_ context: VerseContext, count: Int = 4) -> String {
        """
        <task>The target line is a pile of fragments the writer jotted down: images, rhyme words, \
        half-analogies written "a : b ::" and chains written "a : b : c". Write \(count) different \
        single bars that turn those fragments into one coherent line, keeping their images and \
        sounds, and rhyming with the line before it when there is one.</task>
        \(shared(context))
        """
    }

    static func metaphors(_ first: String, _ second: String, commonGround: [String], languages: [Language], count: Int = 5) -> String {
        var parts = ["""
        <task>The writer wants to connect two ideas in a bar. Write \(count) options, each a single \
        bar or a two-line couplet (put the line break in `text`), that describe the first idea \
        through the second or the second through the first. The connection should hold in more than \
        one respect, not just on the surface. In `note`, say what maps onto what.</task>
        <first_idea>\(first)</first_idea>
        <second_idea>\(second)</second_idea>
        \(languageLine(languages))
        """]
        if !commonGround.isEmpty {
            parts.append("<common_ground>Words the app found between the two ideas, as optional raw material: \(commonGround.joined(separator: ", "))</common_ground>")
        }
        return parts.joined(separator: "\n")
    }

    /// What a word means, what it stands for, and what it can be mistaken for.
    /// The next steps of an association chain, the way this writer moves.
    static func leaps(centre: String, trail: [String], languages: [Language]) -> String {
        var lines = ["""
        <task>A lyricist is in an associative burst, hopping word to word. Give the next hops from the \
        current word: ten to fourteen, each a word or short phrase a rapper could put in a bar. Make \
        the moves this writer makes, not dictionary neighbours: an idiom or title twisted around the \
        word ("if you can dodge a wrench" becoming "if you can dodge a hex"), a reference (film, \
        album, wrestling, tech, law, science) the word lives in, the word re-segmented into other \
        words ("pagal" heard as "pa's gal" or "Pascal"), reversed ("this time" to "time this"), a \
        register jump (street to courtroom to lab), a pun across the writer's languages ("koi mil \
        gaya" to "talking fish"), or a sense drift ("tape" to "roll" to "reel"). `move` names the \
        move in two words; `why` is at most eight words on why it lands; `weight` is 1 for a hop \
        that stays tight to the word and 0 for a lateral leap, spread across the range. Put tight \
        hops first. Keep the chain so far in mind and don't repeat it, but a hop that loops back to \
        an earlier step in a new way is welcome.</task>
        <word>\(centre)</word>
        """]
        if !trail.isEmpty { lines.append("<chain_so_far>\(trail.joined(separator: " : "))</chain_so_far>") }
        lines.append("""
        <this_writers_chains>pagal : paa's gal : pascal : my krazy life : sony leaks
        sunshine : sweet heart : bleeding heart : organ failure : edge node : bleeding edge : bloodstone : seerstone
        Tape : Roll : Reel : Dispenser : Film : Wound up : Preset story : rewound : Looping
        Zipperhead : Bapesta : Stoner : Planet of the Apes : Caesar : Gorillaz Inc : Plastic Beach : Sanitized Alcatraz : SF
        might : mite : smite : willpower : enforceable contract : this time : time this : stopwatch
        koi mil gaya : talking fish : alien : babelfish : magic bhai</this_writers_chains>
        """)
        lines.append(languageLine(languages))
        return lines.joined(separator: "\n")
    }

    /// "smoke : fire ::" — pairs that hold the same relation, strict to loose.
    static func analogies(_ query: AnalogyQuery, languages: [Language]) -> String {
        var lines = ["""
        <task>A writer has set up an analogy and wants it completed with other pairs that hold the \
        same relation, for a verse. Work out what the relation actually is (smoke : fire is what \
        a thing gives off : its source) and return twelve to sixteen pairs that hold it, in three \
        bands: `strictness` "strict" for pairs where the relation is exact and literal (vapor : \
        water, steam : kettle), "close" for pairs that hold it with a small stretch (sweat : \
        labor, rumor : scandal), "loose" for lateral leaps a rapper could still land (echo : \
        shout, shadow : body). Prefer concrete, sayable words; mix in the writer's other \
        languages where a pair sounds better there (write it in that language's own script, with \
        the Roman spelling in the note for Hindi and Gujarati). `left` and `right` are the two \
        words; `note` is a few words in English on why the pair holds, or what it could carry in \
        a line. Strict first, then close, then loose.</task>
        <analogy>\(query.a) : \(query.b) :: \(query.c.map { $0 + " : ?" } ?? "? : ?")</analogy>
        """]
        if let c = query.c {
            lines.append("<note>The writer has already chosen \"\(c)\" for the left side: every pair must start with it, and only `right` varies.</note>")
        }
        lines.append(languageLine(languages))
        return lines.joined(separator: "\n")
    }

    static func meanings(word: String, roman: String, gloss: String, language: Language, languages: [Language], references: [String] = []) -> String {
        var lines = ["""
        <task>Unpack one word for a writer who rhymes and puns across languages. Return three lists.

        `literal`: the closest everyday words for the same sense in each of the writer's other \
        languages, one or two per language. `note` is the shade of meaning that sets that word \
        apart (register, warmth, formality), in a few words.

        `symbolic`: six to eight things this word stands for or calls to mind: what it is a symbol \
        of, the images and idioms it lives in, and what it means in the cultures that use it, \
        including where those cultures disagree. `image` is the association in a few words; `note` \
        is one sentence on why, and on how a line could use it.

        `wordplay`: words or short phrases in any of the writer's languages that sound like this \
        word, or like part of it, but mean something else: the raw material for a bilingual pun. \
        `note` says what the other word means and what the collision suggests. Only include ones \
        that genuinely sound alike when spoken; five good ones beat ten strained ones.

        For every word you return, `language` is its language's English name, `word` is the word \
        in its own script, and `roman` is how it is written in Roman letters if that script is not \
        Roman (otherwise an empty string). Write every `note` in English.</task>
        <word>\(word)</word>
        <word_language>\(language.name)</word_language>
        """]
        if !roman.isEmpty { lines.append("<romanized>\(roman)</romanized>") }
        if !gloss.isEmpty { lines.append("<dictionary_meaning>\(gloss)</dictionary_meaning>") }
        if !references.isEmpty {
            lines.append("<cultural_references>\n\(references.joined(separator: "\n"))\n</cultural_references>")
        }
        lines.append(languageLine(languages))
        return lines.joined(separator: "\n")
    }

    private static func languageLine(_ languages: [Language]) -> String {
        "<writer_languages>\(languages.map(\.name).joined(separator: ", ")) (in the writer's order of preference)</writer_languages>"
    }

    private static func shared(_ context: VerseContext) -> String {
        var parts: [String] = []
        let title = context.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { parts.append("<song_title>\(title)</song_title>") }
        parts.append("<verse>\n\(context.verse)\n</verse>")
        parts.append("<target_line>\(context.targetLine)</target_line>")
        let mix = context.languages.compactMap { language in context.mix[language].map { "\(language.name) \($0) words" } }
        if !mix.isEmpty { parts.append("<verse_languages>\(mix.joined(separator: ", "))</verse_languages>") }
        parts.append(languageLine(context.languages))
        if let syllables = context.syllables {
            parts.append("<syllables>The bars around it run about \(syllables) syllables.</syllables>")
        }
        if !context.palette.isEmpty {
            parts.append("<rhyme_palette>\(context.palette.joined(separator: ", "))</rhyme_palette>")
        }
        if !context.references.isEmpty {
            parts.append("<cultural_references>\n\(context.references.joined(separator: "\n"))\n</cultural_references>")
        }
        let direction = context.direction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direction.isEmpty { parts.append("<direction>\(direction)</direction>") }
        return parts.joined(separator: "\n")
    }
}
