import Foundation

public struct ScreenSnapshot: Sendable, Equatable {
    public var appName: String
    public var windowTitle: String
    /// Accessibility or OCR text of what's on screen.
    public var text: String
    /// UTF-16 offset into `text` of the cursor, when known.
    public var cursorOffset: Int?
    /// OCR'd window text, budgeted separately from `text` so a long field can't crowd it out.
    public var ocrText: String

    public init(appName: String = "", windowTitle: String = "", text: String = "", cursorOffset: Int? = nil, ocrText: String = "") {
        self.appName = appName
        self.windowTitle = windowTitle
        self.text = text
        self.cursorOffset = cursorOffset
        self.ocrText = ocrText
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
        var s = "<screen app=\"\(attr(c.appName))\" window=\"\(attr(c.windowTitle))\">\n\(esc(trimmedContext(c)))\n</screen>"
        // Screen terms are left out on purpose: listing the top 20 here (#26) made gemma-4-e4b
        // echo the screen and time out on long contexts (bench 2026-11-19-2300).
        if !vocabulary.isEmpty {
            s += "\n<vocabulary>\(esc(vocabulary.map(\.text).joined(separator: ", ")))</vocabulary>"
        }
        return s
    }

    static let dictationSystem = """
    You clean up dictated speech. Fix punctuation and capitalization, remove filler \
    words (um, uh, filler "like", "basically", "you know"), and apply spoken self-corrections \
    ("Tuesday, no, Thursday" → "Thursday"; "two PM, sorry, four PM" → "four PM"; "for two \
    actually make it three" → "for three"). Fix misheard words ONLY toward names and terms that \
    appear in <screen> or <vocabulary>, matching their spelling and capitalization \
    exactly. <screen> is reference only: never output its text. Never add, answer, or \
    summarize content. Output only the cleaned transcript.
    """

    public static func dictation(transcript: String, context: ScreenSnapshot, vocabulary: [VocabTerm]) -> [ChatMessage] {
        [ChatMessage(role: "system", content: dictationSystem),
         ChatMessage(role: "user", content: "\(contextBlock(context, vocabulary))\n<transcript>\(esc(transcript))</transcript>")]
    }

    /// S1-mini by Superwhisper (#67): its model card's exact system prompt and control line, then the transcript
    /// only. It was never trained with screen text or vocabulary, so those are left out.
    static let s1MiniSystem = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
    static let s1MiniControl = "[Styling: semi-formal] [Structure: prose] [Context: general]"

    public static func isS1Mini(_ model: String) -> Bool { model.lowercased().contains("s1-mini") }

    /// The dictation prompt for `model`: S1-mini's own format, else `dictation(transcript:context:vocabulary:)`.
    public static func dictation(model: String, transcript: String, context: ScreenSnapshot, vocabulary: [VocabTerm]) -> [ChatMessage] {
        guard isS1Mini(model) else { return dictation(transcript: transcript, context: context, vocabulary: vocabulary) }
        return [ChatMessage(role: "system", content: s1MiniSystem),
                ChatMessage(role: "user", content: "\(s1MiniControl)\n\(transcript)")]
    }

    static let editSystem = """
    The user selected text and spoke. Decide what they want and reply with JSON only:
    {"action": one of "replace","correct","edit","insertBefore","insertAfter",
     "text": the resulting text,
     "vocabulary": {"text": term, "aliases": [misheard form]} or null,
     "remember": boolean}

    Actions:
    - replace: the utterance is itself the new text. "text" = the utterance, cleaned up.
    - correct: fix the selection per the instruction and change nothing else. Spelled \
    letters are exact: "capital T-O-D-O-I-S-T" means "Todoist".
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

    public static func edit(instruction: String, selection: String, context: ScreenSnapshot, vocabulary: [VocabTerm]) -> [ChatMessage] {
        [ChatMessage(role: "system", content: editSystem),
         ChatMessage(role: "user", content: """
         \(contextBlock(context, vocabulary))
         <selection>\(esc(selection))</selection>
         <utterance>\(esc(instruction))</utterance>
         """)]
    }
}
