import AppKit
import PoptalkCore

/// Small non-activating HUD at the bottom of the screen. While an outcome is shown,
/// bare Esc undoes it and bare Return accepts a vocabulary or cleanup offer; those keys are consumed only then.
@MainActor
final class Overlay {
    private let panel: NSPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?
    private var keys: KeyCatcher?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -14),
        ])
        panel.contentView = blur
    }

    /// Shown after the recording text until the next recording, e.g. "raw — model loading" (#39).
    private var note: String?
    private func noted(_ s: String) -> String { note.map { "\(s)  ·  \($0)" } ?? s }

    /// Inactive subsystems for the strip under recording and outcome text (#57); set by `AppDelegate`.
    var statusStrip: () -> [StatusBadge] = { [] }

    func showRecording(note: String? = nil) { self.note = note; show(noted("● Listening…"), for: nil, strip: true) }
    /// Provisional live transcript; long text keeps its tail so the latest words stay visible.
    func showPreview(_ text: String) { show(noted("● " + PreviewText.tail(text, limit: 400)), for: nil, strip: true) }
    func showWorking() { show("Working…", for: nil) }
    func showError(_ msg: String) { show("⚠️ \(msg)", for: 3) }
    func showNotice(_ msg: String) { show(msg, for: 2) }

    /// "⏎ clean up now" after a raw insert. Return runs `onAccept` if `isValid()` still holds; any other
    /// key, or Return once invalid, passes through and dismisses the offer.
    func showCleanupOffer(isValid: @escaping () -> Bool, onAccept: @escaping () -> Void) {
        show("Model ready  ·  ⏎ clean up now", for: max(Self.outcomeSeconds, 6))
        keys = KeyCatcher { [weak self] code, flags in
            if OutcomeKeys.action(code: code, flags: flags.rawValue, canUndo: false, canAccept: true) == .accept, isValid() {
                DispatchQueue.main.async { onAccept() }
                return true
            }
            DispatchQueue.main.async { self?.hide() }
            return false
        }
    }

    /// How long an outcome (and its undo/accept keys) stays up: the "Undo window" setting, read per show.
    static var outcomeSeconds: TimeInterval { OutcomeKeys.undoWindow(.standard) }

    /// `heard`/`result`: the transcript and the text applied, shown above the label (#56); `edit` puts the label
    /// in front of the result as its action.
    func showOutcome(_ text: String, heard: String? = nil, result: String? = nil, edit: Bool = false,
                     undo: (() -> Void)?, vocabularyOffer: VocabTerm?, onAccept: @escaping () -> Void) {
        let lines = OutcomeText.lines(heard: heard, result: result, label: text, edit: edit)
        var parts = lines.label.isEmpty ? [] : [lines.label]
        if undo != nil { parts.append("esc to undo") }
        if let v = vocabularyOffer { parts.append("⏎ add “\(v.text)” to vocabulary") }
        let out = NSMutableAttributedString()
        func line(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: Self.centered]))
        }
        if let h = lines.heard { line(h, size: 11, weight: .regular, color: .secondaryLabelColor) }
        if let r = lines.result { line(r, size: 13, weight: .medium, color: .labelColor) }
        if !parts.isEmpty {
            let footer = lines.result == nil ? (CGFloat(13), NSFont.Weight.medium, NSColor.labelColor) : (11, .regular, .secondaryLabelColor)
            line(parts.joined(separator: "  ·  "), size: footer.0, weight: footer.1, color: footer.2)
        }
        appendStrip(to: out)
        show(out, for: Self.outcomeSeconds)
        keys = KeyCatcher { [weak self] code, flags in
            switch OutcomeKeys.action(code: code, flags: flags.rawValue, canUndo: undo != nil, canAccept: vocabularyOffer != nil) {
            // Defer: showing a new state tears down this tap, which mustn't happen inside its callback.
            case .undo:
                DispatchQueue.main.async { undo?(); self?.show("Undone", for: 1) }
                return true
            case .accept:
                DispatchQueue.main.async { onAccept(); self?.show("Added “\(vocabularyOffer!.text)”", for: 1.5) }
                return true
            case nil: return false
            }
        }
    }

    func hide() {
        hideWork?.cancel()
        keys = nil
        panel.orderOut(nil)
    }

    private static let centered = { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()

    private func show(_ text: String, for seconds: TimeInterval?, strip: Bool = false) {
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: Self.centered])
        if strip { appendStrip(to: out) }
        show(out, for: seconds)
    }

    /// A last line of ~10 pt muted SF Symbols, each with an accessibility label. No tooltips: the panel
    /// ignores the mouse.
    private func appendStrip(to out: NSMutableAttributedString) {
        let badges = statusStrip()
        guard !badges.isEmpty else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            .applying(.init(hierarchicalColor: .tertiaryLabelColor))
        out.append(NSAttributedString(string: "\n"))
        for b in badges {
            guard let img = NSImage(systemSymbolName: b.symbol, accessibilityDescription: b.help)?
                    .withSymbolConfiguration(config) else { continue }
            let a = NSTextAttachment()
            a.image = img
            out.append(NSAttributedString(attachment: a))
            out.append(NSAttributedString(string: "  "))
        }
        out.addAttribute(.paragraphStyle, value: Self.centered, range: NSRange(location: 0, length: out.length))
    }

    private func show(_ text: NSAttributedString, for seconds: TimeInterval?) {
        hideWork?.cancel()
        keys = nil
        label.attributedStringValue = text
        let fit = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: 600, height: CGFloat.greatestFiniteMagnitude))
        let width = min(max(fit.width + 40, 160), 640)
        let height = max(44, ceil(fit.height) + 24)
        label.preferredMaxLayoutWidth = width - 28
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.midX - width / 2, y: f.minY + 50, width: width, height: height), display: true)
        panel.orderFrontRegardless()
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Active key-down tap that lets `handler` consume specific keys; torn down on deinit.
@MainActor
private final class KeyCatcher {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: (Int64, CGEventFlags) -> Bool

    init(handler: @escaping (Int64, CGEventFlags) -> Bool) {
        self.handler = handler
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, ctx in
                let me = Unmanaged<KeyCatcher>.fromOpaque(ctx!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) } }
                }
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                let consumed = MainActor.assumeIsolated { me.handler(code, event.flags) }
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    isolated deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
