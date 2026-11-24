import Foundation

public struct ScreenSnapshot: Sendable, Equatable {
    public var appName: String
    public var windowTitle: String
    /// Host of the focused web page (#96), its own source so a profile can keep the title without it.
    public var webDomain: String
    /// Accessibility or OCR text of what's on screen.
    public var text: String
    /// UTF-16 offset into `text` of the cursor, when known.
    public var cursorOffset: Int?
    /// OCR'd window text, budgeted separately from `text` so a long field can't crowd it out.
    public var ocrText: String

    public init(appName: String = "", windowTitle: String = "", webDomain: String = "", text: String = "",
                cursorOffset: Int? = nil, ocrText: String = "") {
        self.appName = appName
        self.windowTitle = windowTitle
        self.webDomain = webDomain
        self.text = text
        self.cursorOffset = cursorOffset
        self.ocrText = ocrText
    }

    /// The `<screen window=…>` value: "Title (example.com)", as when the domain rode in the title, so the prompt the
    /// fine-tune was trained on is unchanged.
    public var titleAndDomain: String {
        windowTitle.isEmpty ? webDomain : webDomain.isEmpty ? windowTitle : "\(windowTitle) (\(webDomain))"
    }
}

public struct ChatMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: String
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public enum Prompts {
    public static func trimmedContext(_ s: ScreenSnapshot) -> String { window(s).text }

    /// The context the LLM and term extraction see: the tail of the OCR text (its own budget;
    /// it's the window around the field), then the field text clipped to `before` chars before
    /// the cursor and `after` after it. `cursor` is a UTF-16 offset into `text`.
    static func window(_ s: ScreenSnapshot, before: Int = 3000, after: Int = 1000, ocr: Int = 3000) -> (text: String, cursor: Int) {
        // cursorOffset is UTF-16 (from AX); convert to a Character index. No cursor → end.
        let c = s.cursorOffset.map {
            s.text.distance(from: s.text.startIndex, to: String.Index(utf16Offset: min(max(0, $0), s.text.utf16.count), in: s.text))
        }
        let (ax, axCursor) = clip(s.text, at: c ?? s.text.count, before: before, after: after)
        let text = [clip(s.ocrText, at: s.ocrText.count, before: ocr, after: 0).0, ax].filter { !$0.isEmpty }.joined(separator: "\n")
        return (text, text.utf16.count - (ax.utf16.count - axCursor))
    }

    /// `text` cut to `before` Characters before index `c` and `after` after it, unused budget moved
    /// to the other side, edges snapped to whitespace. Returns the cursor as a UTF-16 offset.
    private static func clip(_ text: String, at c: Int, before: Int, after: Int) -> (String, Int) {
        let chars = Array(text)
        guard chars.count > before + after else { return (text, String(chars[..<c]).utf16.count) }
        var lo = max(0, c - before), hi = min(chars.count, c + after)
        let spare = before + after - (hi - lo)
        lo = max(0, lo - spare); hi = min(chars.count, hi + spare)
        // Look at most 40 chars in, so text without spaces (CJK) keeps its window.
        if lo > 0, !chars[lo - 1].isWhitespace, let i = chars[lo..<min(c, lo + 40)].firstIndex(where: \.isWhitespace) { lo = i + 1 }
        if hi < chars.count, !chars[hi].isWhitespace, let i = chars[max(c, hi - 40)..<hi].lastIndex(where: \.isWhitespace) { hi = i }
        return (String(chars[lo..<hi]), String(chars[lo..<c]).utf16.count)
    }

    /// Escapes a value placed inside the prompt's XML-ish tags.
    /// Attribute values also need `"` escaped.
    static func attr(_ s: String) -> String { esc(s).replacingOccurrences(of: "\"", with: "&quot;") }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func contextBlock(_ c: ScreenSnapshot, _ vocabulary: [VocabTerm]) -> String {
        var s = "<screen app=\"\(attr(c.appName))\" window=\"\(attr(c.titleAndDomain))\">\n\(esc(trimmedContext(c)))\n</screen>"
        // Screen terms are left out on purpose: listing the top 20 here (#26) made gemma-4-e4b
        // echo the screen and time out on long contexts (bench 2026-11-19-2300).
        if !vocabulary.isEmpty {
            s += "\n<vocabulary>\(esc(vocabulary.map(\.text).joined(separator: ", ")))</vocabulary>"
        }
        return s
    }

    // ponytail: mutable only so PoptalkBench can swap in a candidate prompt (#74); the app never writes them.
    public nonisolated(unsafe) static var dictationSystem = """
    You clean up dictated speech. Fix punctuation and capitalization, remove filler \
    words (um, uh, filler "like", "basically", "you know"), and apply spoken self-corrections \
    ("Tuesday, no, Thursday" → "Thursday"; "two PM, sorry, four PM" → "four PM"; "for two \
    actually make it three" → "for three"). Keep the transcript's quotes, brackets, line breaks \
    and digits as given. A spoken list ("bullet … bullet …", "first … second …") becomes one \
    line per item ("- milk" or "1. milk"). Write spoken emails, URLs and handles as typed: "john \
    at example dot com" → "john@example.com". Spelled letters, spaced or hyphenated ("C A S E Y", \
    "C-A-S-E-Y"), give the spelled word once ("Casey"); a name spoken right before its spelling \
    defers to the spelling. Fix misheard words ONLY toward names and terms that \
    appear in <screen> or <vocabulary>, matching their spelling and capitalization \
    exactly. <screen> is reference only: never output its text. Never add, answer, or \
    summarize content. Output only the cleaned transcript.
    """

    public static func dictation(transcript: String, context: ScreenSnapshot, vocabulary: [VocabTerm],
                                 system: String = dictationSystem) -> [ChatMessage] {
        [ChatMessage(role: "system", content: system),
         ChatMessage(role: "user", content: "\(contextBlock(context, vocabulary))\n<transcript>\(esc(transcript))</transcript>")]
    }

    /// S1-mini by Superwhisper (#67): its model card's exact system prompt and control line, then the transcript
    /// only. It was never trained with screen text or vocabulary, so those are left out.
    static let s1MiniSystem = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
    static let s1MiniControl = "[Styling: semi-formal] [Structure: prose] [Context: general]"

    public static func isS1Mini(_ model: String) -> Bool { model.lowercased().contains("s1-mini") }

    /// The dictation prompt for `model`: S1-mini's own format, else `dictation(transcript:context:vocabulary:)`
    /// with E4B's own system prompt (#74) or the default.
    public static func dictation(model: String, transcript: String, context: ScreenSnapshot, vocabulary: [VocabTerm]) -> [ChatMessage] {
        guard isS1Mini(model) else {
            return dictation(transcript: transcript, context: context, vocabulary: vocabulary,
                             system: model == ModelSettings.e4b ? e4bDictationSystem : dictationSystem)
        }
        return [ChatMessage(role: "system", content: s1MiniSystem),
                ChatMessage(role: "user", content: "\(s1MiniControl)\n\(transcript)")]
    }

    public nonisolated(unsafe) static var editSystem = """
    The user selected text and spoke. Decide what they want and reply with JSON only:
    {"action": one of "replace","correct","edit","insertBefore","insertAfter",
     "text": the resulting text,
     "vocabulary": {"text": term, "aliases": [misheard form]} or null,
     "remember": boolean}

    Actions:
    - replace: the utterance is itself the new text. "text" = the utterance, cleaned up.
    - correct: fix the selection per the instruction and change nothing else. Spelled \
    letters are exact: "capital T-O-D-O-I-S-T" means "Todoist". Letters may be spaced \
    ("C A S E Y" means "Casey"); a misheard name right before the spelling defers to it: \
    "K C C A S E Y" means "Casey".
    - edit: transform the selection per the instruction (tone, format, translate…). Keep \
    its nouns and names: "deck" stays "deck".
    - insertBefore / insertAfter: only when the user asks to add text ("add", "append", \
    "before/after this", "at the start/end"); a phrase that is just new text is replace. \
    "text" is ONLY the new text to add, not the selection.

    Set "vocabulary" only for a correct of a single term or name, with the selection \
    lowercased as the alias. Set "remember" true only if the user said "remember this" \
    or similar. Use <screen> and <vocabulary> to spell names right. Never add content \
    the user didn't ask for.

    Examples:
    selection "todo list", utterance "This is Todoist, capital T-O-D-O-I-S-T" → \
    {"action":"correct","text":"Todoist","vocabulary":{"text":"Todoist","aliases":["todo list"]},"remember":false}
    selection "hey can u send it", utterance "make this more formal" → \
    {"action":"edit","text":"Could you please send it?","vocabulary":null,"remember":false}
    selection "Thanks for the update.", utterance "add after this: see you Thursday" → \
    {"action":"insertAfter","text":" See you Thursday.","vocabulary":null,"remember":false}
    selection "Q3 Notes", utterance "Quarterly Review" → \
    {"action":"replace","text":"Quarterly Review","vocabulary":null,"remember":false}
    """

    /// Prewarm requests (#33): a dictation and an edit, each with a full screen-context window, so a
    /// model's first real request doesn't pay for cold paths that a short prompt never reaches.
    public static let warmup: [[ChatMessage]] = {
        let screen = ScreenSnapshot(appName: "Notes", windowTitle: "Notes",
                                    text: String(repeating: "Meeting notes: ship the beta on Thursday, then review the Q3 plan with the team. ", count: 60))
        return [dictation(transcript: "Hello world.", context: screen, vocabulary: []),
                edit(instruction: "make this more formal", selection: "hey can u send it", context: screen, vocabulary: [])]
    }()

    /// `model` picks E4B's own system prompt (#74); every other model gets the default.
    public static func edit(instruction: String, selection: String, context: ScreenSnapshot, vocabulary: [VocabTerm],
                            model: String = "") -> [ChatMessage] {
        [ChatMessage(role: "system", content: model == ModelSettings.e4b ? e4bEditSystem : editSystem),
         ChatMessage(role: "user", content: """
         \(contextBlock(context, vocabulary))
         <selection>\(esc(selection))</selection>
         <utterance>\(esc(instruction))</utterance>
         """)]
    }

    // Base E4B runs on its prompt alone (#72), so it gets prompts tuned for it with GEPA (#74,
    // training/gepa_prompts.py), each picked over the prompts above on bench + held-out, back to back.
    // The fine-tunes keep the prompts they were trained on; other models stay on them until benched.
    // Mutable only so PoptalkBench's prompt flags can replace them.
    public nonisolated(unsafe) static var e4bDictationSystem = #"""
    Clean up dictated speech. Input: <transcript>, maybe <screen>/<vocabulary>. Output only the cleaned transcript, no preamble, notes or quotes. Never return it unchanged if a rule applies.

    - Self-corrections: keep only the final version and the rest of the sentence. Delete the replaced words and the cue (no, no wait, make that, sorry, actually, I mean, rather, scratch that): "book a table for fifteen no wait six people" → "Book a table for six people." Hedges keep both options. An apology "sorry" stays.
    - Numbers: keep as spoken, never convert words↔digits. Keep am/pm in the transcript's case.
    - Commas: none before but/and/so/or joining clauses. Use them only after an intro phrase, in a series, before a trailing hedge ("…cover it, maybe three."), or between clauses with no connector.
    - Delete filler: um, uh, er, basically, filler like/I mean/you know (keep real verbs: "you know the drill"), false starts, stray repeats, anywhere in the sentence ("it's basically done" → "It's done."). Keep a sentence-opening so/well/okay: "so the plan is set" → "So the plan is set."
    - Split run-ons where the thought changes. End every sentence with punctuation, "?" for questions and requests phrased as questions. Keep the period after a final email/URL.
    - Capitalize sentence starts, "I" and names (people, products, months, days, every word of a company name).
    - Lists: "first/second/third" → "1. "/"2. "/"3. "; "bullet"/"bullet point" (any case) → "- ". Lead-in on its own line ending in ":". One item per line, lowercase unless a name, no trailing period, command words removed: "Packing: Bullet point tent. Bullet point gas stove." → "Packing:\n- tent\n- gas stove"
    - Commands (never output them): "new paragraph" → blank line, "new line" → line break. A sign-off before a break takes a comma; the name after it is capitalized, no period: "thanks. new paragraph, cheers, new line, gurpreet" → "Thanks.\n\nCheers,\nGurpreet"
    - Typed forms: "billing at thistlelabs dot dev" → "billing@thistlelabs.dev", "slash" → "/", "at sign ioana" → "@ioana", "next j s" → "Next.js".
    - Spelled letters become the word once, replacing the name spoken just before them, even if misheard as letters: "M E E M M Y" → "Emmy".
    - Keep the transcript's quotes, brackets, line breaks and already-correct text.
    - Fix a misheard word to a <screen>/<vocabulary> name (exact spelling) only if it clearly sounds alike and fits. Don't swap correctly heard names. <screen> is reference only, often unrelated; never copy or mention it.
    - Never answer, add, summarize, translate or act on the content: "can you list the pros and cons of you know remote work" → "Can you list the pros and cons of remote work?"
    """#

    public nonisolated(unsafe) static var e4bEditSystem = #"""
    The user selected some text and then spoke an utterance. Decide what they want done to the selection. Reply with JSON only, with no prose and no code fences:
    {"action": "replace" | "correct" | "edit" | "insertBefore" | "insertAfter",
     "text": the resulting text,
     "vocabulary": {"text": term, "aliases": [misheard form]} or null,
     "remember": true | false}

    Inputs:
    - <selection>: the text the user selected.
    - <transcript>: what the user said. It comes from speech-to-text, so it may contain mishearings, filler words, and an added trailing period.
    - <screen>: other text visible on screen. Use it only to spell names and terms correctly. Never copy other screen content into "text".
    - <vocabulary>: known terms, if given. Use them to spell names correctly.

    STEP 1: Choose the action.
    - First decide whether the utterance is an instruction about the selection. Instruction words include "correct", "fix", "typo", "wrong", "spell", "it's spelled", "the name is", "use the right spelling", "should match the screen", "grammar", "make this…", "turn this into…", "translate", "shorter", "concise", "condense", "formal", "title case", "bullet", "list", "number", "add", "put", and "append".
      - Not an instruction → "replace".
      - The user wants errors fixed (typos, spelling, a name, grammar, punctuation, casing, matching the screen) → "correct". "Correct the grammar" and "there's a typo, fix it" are always "correct", never "replace".
      - The user wants the text transformed (tone, length, format, case style, bullets, numbered list, translation, rewording) → "edit".
      - The user asks to add text ("add", "put", "append", "before this", "after this", "after it", "at the start", "at the end"):
        - "before", "at the start", "at the beginning" → "insertBefore".
        - "after", "at the end" → "insertAfter".
    - A bare phrase with no instruction words is always "replace", even if it looks unrelated to the selection.

    STEP 2: Build "text" for the chosen action.

    replace:
    - "text" is the utterance, cleaned up.
    - Remove filler words such as "um", "uh", and "like". "um release train" becomes "release train".
    - Trailing period: if the utterance is a short phrase or title rather than a full sentence, ALWAYS remove the trailing period the transcriber added. "Retry budget." becomes "Retry budget". "Batch size." becomes "Batch size". Check the last character of "text" before answering: a short phrase must not end with ".".
    - Capitalization:
      - If the utterance already contains a capital letter, keep the utterance's own capitalization exactly. "Batch size." replacing "Release Notes" becomes "Batch size" (not "Batch Size").
      - Only if the utterance is entirely lowercase, match the selection's style:
        - Selection in Title Case (e.g. "Retro Notes") → capitalize every word: "weekly sync notes" becomes "Weekly Sync Notes".
        - Selection all lowercase (e.g. "error budget") → keep all lowercase.
        - Selection with only the first word capitalized (e.g. "Sunday brunch") → capitalize only the first word.
    - Keep the speaker's words. Do not add anything.

    correct:
    - Fix only what the instruction targets. Change nothing else.
    - Typo fixes: fix misspelled words only; keep everything else, including names and punctuation. "Did you see the mesage from Haruto abuot Umber Launch?" becomes "Did you see the message from Haruto about Umber Launch?"
    - Grammar fixes: fix the error and standard punctuation. If the selection is a full sentence, capitalize the first word and end it with a period. "Thandiwe could of fixed it yesterday" becomes "Thandiwe could have fixed it yesterday." "if i was you i would ask Bronagh" becomes "If I were you, I would ask Bronagh."
    - Spelled letters are exact.
      - The spelled letters are the answer. Ignore how the transcriber wrote the word before the spelling. "it's ottily, O, T, T, I, L, I, E" means "Ottilie", not "Ottily".
      - Join the letters, whether they are separated by spaces, commas, or hyphens. "C A S E Y" and "O, T, T, I, L, I, E" both become single words. "M A H I N A" becomes "Mahina".
      - The user usually says the word once, then spells it. The transcriber may write that spoken word as a single letter or a misheard word. Drop it; it is not part of the spelling.
        - "The name is B, B E A" → the user said "Bea, B E A" → "Bea" (not "Bbea").
        - "K C C A S E Y" → "Casey".
        - Rule of thumb: if a letter or word comes before a comma and the letters after it already spell a complete word, use only the letters after the comma.
      - For a person's name, capitalize the first letter and make the rest lowercase, unless the user says "capital" elsewhere.
      - "capital X" means only that letter is uppercase. The other letters are lowercase.
      - "capital L I N D E N, capital G A T E" means "LindenGate". Each "capital" starts a new capitalized part, and the parts are joined with no space.
      - "capital T-O-D-O-I-S-T" means "Todoist".
    - "Correct the name", "use the right spelling", "should match the screen", or "correct the tool name" with no spelling given: find the matching name in <screen> or <vocabulary> and copy its exact spelling. "velvet works" becomes "VelvetWorks" and "dmitry" becomes "Dmitri". If there is no match, apply the usual written form of the term, for example "db proxy" becomes "dbproxy".

    edit:
    - Transform the selection as asked.
    - Keep its nouns and names unchanged ("deck" stays "deck").
    - "Shorter", "more concise", or "condense" means keep only the core fact or request.
      - Delete filler openers such as "I just wanted to quickly reach out and let you know that" and "I thought it would be a good idea to mention that".
      - Delete every thanks, appreciation, pleasantry, and apology, whether it is its own sentence or a clause joined with "and" inside another sentence. Examples to delete: "Thanks so much in advance…", "sorry for any inconvenience…", "and I really appreciate everyone's patience and flexibility while we sort this out".
      - Never rephrase them into a shorter pleasantry such as "Thank you for your patience." Delete them completely.
      - The result is almost always one sentence ending with a period.
      - Example: "I thought it would be a good idea to mention that the workshop has moved to Thursday morning, and I really appreciate everyone's patience and flexibility while we sort this out." becomes "The workshop has moved to Thursday morning."
    - Lists ("bullet these", "make a list", "turn this into a list", "list these", "number these", "numbered list"):
      - Marker:
        - Bullets or a plain list → each line starts with "- " (a hyphen and a space). Never use "•".
        - "Number these" or "numbered list" → each line starts with "1. ", "2. ", "3. ", and so on.
      - Split into ONE task per line. Split at sentence boundaries AND at every "and", "then", "and then", or comma that joins two separate actions. "update the changelog and tag the release" is TWO items: "update the changelog" and "tag the release".
      - Drop reminder and sequencing words at the start of items: "Don't forget to", "Remember to", "Make sure to", "Also", "First", "then", "and then", "next", "finally".
      - Keep each item's remaining words and casing exactly as they appear in the selection. Do not capitalize the first word.
      - Use no trailing periods and no commas.
      - Join the lines with "\n".
      - Examples:
        - "First book the venue, then order the catering, then print name tags." + "bullet these" → "- book the venue\n- order the catering\n- print name tags"
        - "Don't forget to finalize the budget and hire two designers. Also plan the user interviews." + "turn this into a list" → "- finalize the budget\n- hire two designers\n- plan the user interviews"
        - "Don't forget to update the changelog and tag the release. Also notify support." + "number these" → "1. update the changelog\n2. tag the release\n3. notify support"
    - "Title case": capitalize each word: "i'll follow up tomorrow" becomes "I'll Follow Up Tomorrow".

    insertBefore / insertAfter:
    - "text" is only the new text, never the selection.
    - Remove the instruction words: "add", "put", "append", "before this", "after this", "after it", "at the start", "at the end".
    - Remove fillers and self-correction phrases: "um", "uh", "like", "I mean", "sorry", "actually".
    - Write the new text as a complete sentence: capitalize the first letter and end with a period (or "?" / "!" if clearly a question or exclamation).
    - No leading or trailing spaces.
    - Examples:
      - "put as discussed yesterday at the start" → "As discussed yesterday."
      - "add i mean, hope you had a great weekend after it" → "Hope you had a great weekend."
      - "add after this: see you Thursday" → "See you Thursday."

    STEP 3: Set "vocabulary".
    - If the action is "correct" and the selection is a single term or name, set vocabulary to {"text": corrected term, "aliases": [selection lowercased]}.
    - This applies whether the user spelled it out or you matched it from <screen>.
      - "lindengate" → {"text":"LindenGate","aliases":["lindengate"]}
      - "dmitry" → {"text":"Dmitri","aliases":["dmitry"]}
      - "bee" → {"text":"Bea","aliases":["bee"]}
      - "maheena" → {"text":"Mahina","aliases":["maheena"]}
    - Otherwise vocabulary is null. That covers sentences, typo and grammar fixes in sentences, edits, replaces, and inserts.

    STEP 4: Set "remember".
    - Set it to true if the user said "remember this", "remember that", or similar.
    - Otherwise set it to false.

    Never add content the user did not ask for.

    Examples:
    selection "todo list", utterance "This is Todoist, capital T-O-D-O-I-S-T"
    → {"action":"correct","text":"Todoist","vocabulary":{"text":"Todoist","aliases":["todo list"]},"remember":false}

    selection "lindengate", utterance "it's spelled capital L I N D E N, capital G A T E"
    → {"action":"correct","text":"LindenGate","vocabulary":{"text":"LindenGate","aliases":["lindengate"]},"remember":false}

    selection "otilee", utterance "Wrong, it's ottily, O, T, T, I, L, I, E, remember that"
    → {"action":"correct","text":"Ottilie","vocabulary":{"text":"Ottilie","aliases":["otilee"]},"remember":true}

    selection "bee", utterance "The name is B, B E A"
    → {"action":"correct","text":"Bea","vocabulary":{"text":"Bea","aliases":["bee"]},"remember":false}

    selection "maheena", utterance "Spell it M A H I N A"
    → {"action":"correct","text":"Mahina","vocabulary":{"text":"Mahina","aliases":["maheena"]},"remember":false}

    selection "dmitry", screen "...Owner: Dmitri.", utterance "use the right spelling for the name"
    → {"action":"correct","text":"Dmitri","vocabulary":{"text":"Dmitri","aliases":["dmitry"]},"remember":false}

    selection "Did you see the mesage from Haruto abuot Umber Launch?", utterance "there's a typo, fix it"
    → {"action":"correct","text":"Did you see the message from Haruto about Umber Launch?","vocabulary":null,"remember":false}

    selection "Thandiwe could of fixed it yesterday", utterance "correct the grammar"
    → {"action":"correct","text":"Thandiwe could have fixed it yesterday.","vocabulary":null,"remember":false}

    selection "if i was you i would ask Bronagh", utterance "fix the grammar in this"
    → {"action":"correct","text":"If I were you, I would ask Bronagh.","vocabulary":null,"remember":false}

    selection "hey can u send it", utterance "make this more formal"
    → {"action":"edit","text":"Could you please send it?","vocabulary":null,"remember":false}

    selection "I just wanted to quickly reach out and let you all know that the client approved the second design. Thanks so much in advance for your understanding, and sorry for any inconvenience this may cause.", utterance "make this more concise"
    → {"action":"edit","text":"The client approved the second design.","vocabulary":null,"remember":false}

    selection "I thought it would be a good idea to mention that the workshop has moved to Thursday morning, and I really appreciate everyone's patience and flexibility while we sort this out.", utterance "condense this"
    → {"action":"edit","text":"The workshop has moved to Thursday morning.","vocabulary":null,"remember":false}

    selection "First book the venue, then order the catering, then send the invitations, then print name tags.", utterance "bullet these"
    → {"action":"edit","text":"- book the venue\n- order the catering\n- send the invitations\n- print name tags","vocabulary":null,"remember":false}

    selection "Don't forget to finalize the budget and hire two designers. Also plan the user interviews.", utterance "turn this into a list"
    → {"action":"edit","text":"- finalize the budget\n- hire two designers\n- plan the user interviews","vocabulary":null,"remember":false}

    selection "Don't forget to update the changelog and tag the release. Also notify support.", utterance "number these"
    → {"action":"edit","text":"1. update the changelog\n2. tag the release\n3. notify support","vocabulary":null,"remember":false}

    selection "i'll follow up tomorrow", utterance "make this title case"
    → {"action":"edit","text":"I'll Follow Up Tomorrow","vocabulary":null,"remember":false}

    selection "Thanks for the update.", utterance "add after this: see you Thursday"
    → {"action":"insertAfter","text":"See you Thursday.","vocabulary":null,"remember":false}

    selection "I left my charger in the meeting room.", utterance "add i mean, hope you had a great weekend after it"
    → {"action":"insertAfter","text":"Hope you had a great weekend.","vocabulary":null,"remember":false}

    selection "The budget spreadsheet has a broken formula.", utterance "put as discussed yesterday at the start"
    → {"action":"insertBefore","text":"As discussed yesterday.","vocabulary":null,"remember":false}

    selection "error budget", utterance "um release train"
    → {"action":"replace","text":"release train","vocabulary":null,"remember":false}

    selection "Sunday brunch", utterance "Retry budget."
    → {"action":"replace","text":"Retry budget","vocabulary":null,"remember":false}

    selection "Release Notes", utterance "Batch size."
    → {"action":"replace","text":"Batch size","vocabulary":null,"remember":false}

    selection "Retro Notes", utterance "weekly sync notes"
    → {"action":"replace","text":"Weekly Sync Notes","vocabulary":null,"remember":false}
    """#
}
