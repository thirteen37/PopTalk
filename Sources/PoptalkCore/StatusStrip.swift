/// One muted icon in the overlay's status strip (#57); `help` is its accessibility label.
public struct StatusBadge: Equatable, Sendable {
    public var symbol: String
    public var help: String
}

/// Inactive or degraded subsystems, for the strip under the overlay text. Empty when all is normal.
public enum StatusStrip {
    /// `llm`: the cleanup model's status (`.ready` for providers that don't load in-process).
    public static func badges(_ s: AppStatus, llm: ModelStatus, sources: ContextSources, ocrWarm: Bool,
                              history: Bool) -> [StatusBadge] {
        var b: [StatusBadge] = []
        if s.speech != .ready { b.append(.init(symbol: "waveform.slash", help: "Speech model \(s.speech.title)")) }
        if llm != .ready { b.append(.init(symbol: "text.bubble", help: "Language model \(llm.title): raw dictation")) }
        b += s.missing.map { .init(symbol: "lock", help: "\($0.rawValue) permission missing") }
        if !sources.ocr { b.append(.init(symbol: "text.viewfinder", help: "Screen text (OCR) off")) }
        else if !s.isGranted(.screenRecording) { b.append(.init(symbol: "eye.slash", help: "No Screen Recording permission: no screen text")) }
        else if !ocrWarm { b.append(.init(symbol: "hourglass", help: "Screen text (OCR) warming up")) }
        let off = [("focused text", sources.focusedText), ("nearby text", sources.nearbyText),
                   ("window title", sources.windowTitle), ("screen vocabulary", sources.screenVocabulary)]
            .filter { !$0.1 }.map(\.0)
        if !off.isEmpty { b.append(.init(symbol: "text.badge.xmark", help: "Context off: " + off.joined(separator: ", "))) }
        if history { b.append(.init(symbol: "circle.fill", help: "History recording on")) }
        return b
    }
}
