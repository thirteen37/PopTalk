import AppKit
import PoptalkCore

/// Small non-activating HUD at the bottom of the screen. While an outcome is shown,
/// Esc undoes it and Return accepts a vocabulary offer; those two keys are consumed only then.
@MainActor
final class Overlay {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
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
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -14),
        ])
        panel.contentView = blur
    }

    func showRecording() { show("● Listening…", for: nil) }
    func showWorking() { show("Working…", for: nil) }
    func showError(_ msg: String) { show("⚠️ \(msg)", for: 3) }

    func showOutcome(_ text: String, undo: (() -> Void)?, vocabularyOffer: VocabTerm?, onAccept: @escaping () -> Void) {
        var parts = [text]
        if undo != nil { parts.append("esc to undo") }
        if let v = vocabularyOffer { parts.append("⏎ add “\(v.text)” to vocabulary") }
        show(parts.joined(separator: "  ·  "), for: 4)
        keys = KeyCatcher { [weak self] code in
            switch code {
            // Defer: showing a new state tears down this tap, which mustn't happen inside its callback.
            case 53 where undo != nil:
                DispatchQueue.main.async { undo?(); self?.show("Undone", for: 1) }
                return true
            case 36 where vocabularyOffer != nil:
                DispatchQueue.main.async { onAccept(); self?.show("Added “\(vocabularyOffer!.text)”", for: 1.5) }
                return true
            default: return false
            }
        }
    }

    func hide() {
        hideWork?.cancel()
        keys = nil
        panel.orderOut(nil)
    }

    private func show(_ text: String, for seconds: TimeInterval?) {
        hideWork?.cancel()
        keys = nil
        label.stringValue = text
        let width = min(max(label.intrinsicContentSize.width + 40, 160), 640)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main!
        let f = screen.visibleFrame
        panel.setFrame(NSRect(x: f.midX - width / 2, y: f.minY + 50, width: width, height: 44), display: true)
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
    private let handler: (Int64) -> Bool

    init(handler: @escaping (Int64) -> Bool) {
        self.handler = handler
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, ctx in
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyCatcher>.fromOpaque(ctx!).takeUnretainedValue()
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                let consumed = MainActor.assumeIsolated { me.handler(code) }
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
