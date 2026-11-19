import Foundation

public struct ScreenSnapshot: Sendable, Equatable {
    public var appName: String
    public var windowTitle: String
    /// Accessibility or OCR text of what's on screen.
    public var text: String
    /// UTF-16 offset into `text` of the cursor, when known.
    public var cursorOffset: Int?

    public init(appName: String = "", windowTitle: String = "", text: String = "", cursorOffset: Int? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.text = text
        self.cursorOffset = cursorOffset
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
    public static func trimmedContext(_ s: ScreenSnapshot, maxChars: Int = 4000) -> String {
        let chars = Array(s.text)
        guard chars.count > maxChars else { return s.text }
        guard let offset = s.cursorOffset else { return String(chars.suffix(maxChars)) }
        // cursorOffset is UTF-16 (from AX); convert to a Character index.
        let cursor = s.text.distance(from: s.text.startIndex,
                                     to: String.Index(utf16Offset: min(max(0, offset), s.text.utf16.count), in: s.text))
        let start = min(max(0, cursor - maxChars / 2), chars.count - maxChars)
        return String(chars[start..<start + maxChars])
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
        if !vocabulary.isEmpty {
            s += "\n<vocabulary>\(esc(vocabulary.map(\.text).joined(separator: ", ")))</vocabulary>"
        }
        return s
    }

    static let dictationSystem = """
    You clean up dictated speech. Fix punctuation and capitalization, remove filler \
    words (um, uh, filler "like"), and apply spoken self-corrections ("Tuesday, no, \
    Thursday" → "Thursday"; "two PM, sorry, four PM" → "four PM"). Fix misheard words ONLY toward names and terms that \
    appear in <screen> or <vocabulary>, matching their spelling and capitalization \
    exactly. Never add, answer, or summarize content. Output only the cleaned text.
    """

    public static func dictation(transcript: String, context: ScreenSnapshot, vocabulary: [VocabTerm]) -> [ChatMessage] {
        [ChatMessage(role: "system", content: dictationSystem),
         ChatMessage(role: "user", content: "\(contextBlock(context, vocabulary))\n<transcript>\(esc(transcript))</transcript>")]
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
    - edit: transform the selection per the instruction (tone, format, translate…).
    - insertBefore / insertAfter: "text" is ONLY the new text to add, not the selection.

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

    public static func edit(instruction: String, selection: String, context: ScreenSnapshot, vocabulary: [VocabTerm]) -> [ChatMessage] {
        [ChatMessage(role: "system", content: editSystem),
         ChatMessage(role: "user", content: """
         \(contextBlock(context, vocabulary))
         <selection>\(esc(selection))</selection>
         <utterance>\(esc(instruction))</utterance>
         """)]
    }
}
