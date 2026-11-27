/// One muted icon in the overlay's status strip (#57); `help` is its accessibility label.
public struct StatusBadge: Equatable, Sendable {
    public var symbol: String
    public var help: String
}

/// Inactive or degraded subsystems, for the strip under the overlay text. Empty when all is normal.
public enum StatusStrip {
    /// `llm`: the cleanup model's status (`.ready` for providers that don't load in-process). `sources`: the press's
    /// resolved sources; `appOff`: the ones an app profile turned off (#96, #127).
    public static func badges(_ s: AppStatus, llm: ModelStatus, sources: ContextSources, ocrWarm: Bool,
                              history: Bool, appOff: Set<ContextSource> = []) -> [StatusBadge] {
        var b: [StatusBadge] = []
        if s.speech != .ready { b.append(.init(symbol: "waveform.slash", help: "Speech model \(s.speech.title)")) }
        if llm != .ready { b.append(.init(symbol: "text.bubble", help: "Language model \(llm.title): raw dictation")) }
        b += s.missing.map { .init(symbol: "lock", help: "\($0.rawValue) permission missing") }
        // The domain goes with the title unless a profile split them.
        let shown: [(source: ContextSource, name: String, on: Bool)] = [
            (.focusedText, "focused text", sources.focusedText), (.nearbyText, "nearby text", sources.nearbyText),
            (.ocr, "OCR", sources.ocr), (.windowTitle, "window title", sources.windowTitle),
            (.webDomain, "web domain", sources.webDomain || !sources.windowTitle),
            (.screenVocabulary, "screen vocabulary", sources.screenVocabulary)]
        let inApp = shown.filter { appOff.contains($0.source) }.map(\.name)
        if !inApp.isEmpty, ContextSource.screen.allSatisfy({ !sources[$0] }) {
            b.append(.init(symbol: "eye.slash", help: "Screen reading off in this app"))
        } else {
            if !inApp.isEmpty {
                b.append(.init(symbol: "rectangle.badge.xmark", help: "Off in this app: " + inApp.joined(separator: ", ")))
            }
            if !sources.ocr {
                if !appOff.contains(.ocr) { b.append(.init(symbol: "text.viewfinder", help: "Screen text (OCR) off")) }
            } else if !s.isGranted(.screenRecording) {
                b.append(.init(symbol: "eye.slash", help: "No Screen Recording permission: no screen text"))
            } else if !ocrWarm { b.append(.init(symbol: "hourglass", help: "Screen text (OCR) warming up")) }
            // Screen vocabulary is off by default (#130): not worth a badge.
            let off = shown.filter { !$0.on && ![.ocr, .screenVocabulary].contains($0.source) && !appOff.contains($0.source) }.map(\.name)
            if !off.isEmpty { b.append(.init(symbol: "text.badge.xmark", help: "Context off: " + off.joined(separator: ", "))) }
        }
        if history { b.append(.init(symbol: "circle.fill", help: "History recording on")) }
        return b
    }
}
