import AppKit
import PoptalkCore

/// Small non-activating HUD at the bottom of the screen ("glyph capsule", #63). While an outcome is shown,
/// bare Esc undoes it and bare Return accepts a vocabulary or cleanup offer; those keys are consumed only then.
/// It moves off the focused field, and can be dragged elsewhere (remembered per display; right-click resets, #78).
@MainActor
final class Overlay {
    private let panel: DragPanel
    /// Holds the current `Capsule` view, inside the glass (macOS 26+) or the HUD material.
    private let container = NSView()
    private var hideWork: DispatchWorkItem?
    private var keys: KeyCatcher?
    /// Bumped on every show/hide, so a fade-out that finishes after a newer show doesn't hide it.
    private var generation = 0
    /// The focused field or caret (AppKit coordinates), read once per press when the overlay first shows.
    private var field: CGRect?
    private var fieldRead = false

    init() {
        panel = DragPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 48),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        container.frame = NSRect(x: 0, y: 0, width: 360, height: 48)
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        if #available(macOS 26, *) {
            // Regular, untinted glass: the clear variant gets faint over bright or busy windows, and the state
            // tint already lives in the glyph tile, the verb and the undo bar.
            let glass = NSGlassEffectView(frame: container.frame)
            glass.style = .regular
            glass.cornerRadius = Capsule.radius
            glass.contentView = container
            panel.contentView = glass
        } else {
            let blur = Material(frame: container.frame)
            blur.material = .hudWindow
            blur.state = .active
            blur.addSubview(container)
            panel.contentView = blur
        }
        panel.onDrop = { [unowned self] in
            guard let screen = panel.screen, let key = Self.key(screen) else { return }
            let a = OverlayPlacement.anchor(of: panel.frame, visible: screen.visibleFrame)
            Self.anchors[key] = [a.x, a.y]
            field = nil  // placed by hand: don't move it off the field again this press
        }
        panel.onReset = { [unowned self] in
            guard let screen = panel.screen else { return }
            if let key = Self.key(screen) { Self.anchors[key] = nil }
            panel.setFrame(place(panel.frame.size, on: screen), display: true, animate: true)
        }
    }

    /// Dragged anchors (`OverlayPlacement.anchor`) by display UUID; Settings → General resets them all.
    private static var anchors: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: OverlayPlacement.anchorsKey) as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: OverlayPlacement.anchorsKey) }
    }

    private static func key(_ screen: NSScreen) -> String? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func place(_ size: CGSize, on screen: NSScreen) -> NSRect {
        let a = Self.key(screen).flatMap { Self.anchors[$0] }.flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        return OverlayPlacement.frame(size: size, visible: screen.visibleFrame, field: field, anchor: a)
    }

    /// Shown under the recording text until the next recording, e.g. "raw — model loading" (#39).
    private var note: String?

    /// Inactive subsystems for the strip in the footer of recording and outcome states (#57); set by `AppDelegate`.
    var statusStrip: () -> [StatusBadge] = { [] }

    /// The last live transcript, kept on screen while working after release.
    private var preview: String?

    func showRecording(note: String? = nil) {
        self.note = note
        preview = nil
        fieldRead = false  // a new press
        show(Self.recordingHUD(preview: nil, note: note, strip: statusStrip()), for: nil)
    }
    /// Provisional live transcript; long text keeps its tail so the latest words stay visible. `cleaned` (#43): the
    /// latest speculative result, run on `input`; stale (greyed) once the transcript has moved on from it.
    func showPreview(_ text: String, cleaned: LivePreview.Shown? = nil, input: String? = nil) {
        preview = text
        show(Self.recordingHUD(preview: text, cleaned: cleaned, input: input, note: note, strip: statusStrip()), for: nil)
    }
    /// `heard`: the final transcript; without it, the last preview (once) stays up above a small "Working…".
    func showWorking(heard: String? = nil) {
        defer { preview = nil }
        show(Self.workingHUD(heard ?? preview), for: nil)
    }
    func showError(_ msg: String) { show(Self.errorHUD(msg), for: 3) }
    func showNotice(_ msg: String) { show(Self.noticeHUD(msg), for: 2) }

    /// "⏎ clean up now" after a raw insert. Return runs `onAccept` if `isValid()` still holds; any other
    /// key, or Return once invalid, passes through and dismisses the offer.
    func showCleanupOffer(isValid: @escaping () -> Bool, onAccept: @escaping () -> Void) {
        let seconds = max(Self.outcomeSeconds, 6)
        show(Self.cleanupOfferHUD(seconds: seconds), for: seconds)
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
                     undo: (() async -> Bool)?, vocabularyOffer: VocabTerm?, onAccept: @escaping () -> Void) {
        show(Self.outcomeHUD(text, heard: heard, result: result, edit: edit, undo: undo != nil,
                             vocabulary: vocabularyOffer?.text, strip: statusStrip(), seconds: Self.outcomeSeconds),
             for: Self.outcomeSeconds)
        keys = KeyCatcher { [weak self] code, flags in
            switch OutcomeKeys.action(code: code, flags: flags.rawValue, canUndo: undo != nil, canAccept: vocabularyOffer != nil) {
            // Defer: showing a new state tears down this tap, which mustn't happen inside its callback.
            case .undo:
                // False: it couldn't be undone safely and has said so (#79).
                DispatchQueue.main.async { Task { if await undo?() == true { self?.show(Self.confirmHUD("Undone"), for: 1) } } }
                return true
            case .accept:
                DispatchQueue.main.async { onAccept(); self?.show(Self.confirmHUD("Added “\(vocabularyOffer!.text)”"), for: 1.5) }
                return true
            case nil: return false
            }
        }
    }

    func hide() {
        hideWork?.cancel()
        keys = nil
        preview = nil
        fieldRead = false
        generation += 1
        let g = generation
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == g else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: - States

    /// With a cleaned preview (#43): the raw transcript small on top, words the cleanup dropped struck through; the
    /// cleaned text below, the words it changed underlined in the accent colour (an edit: "Correct →" Todoist).
    static func recordingHUD(preview: String?, cleaned: LivePreview.Shown? = nil, input: String? = nil, note: String?,
                             strip: [StatusBadge]) -> HUD {
        var h = HUD(glyph: .levels, tint: .systemRed, note: note, strip: strip)
        if let preview, let cleaned {
            let stale = input != preview
            // Marks index `input`, which is `preview` when not stale.
            (h.heard, h.heardMarks) = stale ? tail(preview, []) : tail(input!, cleaned.rawMarks)
            h.heardTail = true
            h.act = cleaned.act
            h.actTint = .systemIndigo
            if cleaned.act == nil {
                (h.main, h.mainMarks) = tail(cleaned.text, cleaned.marks)
                h.tail = true
            } else {
                (h.main, h.mainMarks) = (cleaned.text, cleaned.marks.map { NSRange($0, in: cleaned.text) })
            }
            if stale { h.mainColor = .secondaryLabelColor }
        } else if let preview {
            h.main = PreviewText.tail(preview, limit: previewLimit)
            h.tail = true
        } else {
            h.glyph = .symbol("mic")
            h.main = "Listening…"
            h.mainColor = .secondaryLabelColor
        }
        return h
    }

    /// Characters of live text kept: well over `Capsule.maxLines` at the max width, so a cut never shortens the block.
    private static let previewLimit = 600

    /// `PreviewText.tail` of `text`, with `marks` (ranges in `text`) moved into the cut string.
    private static func tail(_ text: String, _ marks: [Range<String.Index>]) -> (String, [NSRange]) {
        let cut = PreviewText.tail(text, limit: previewLimit)
        let ns = marks.map { NSRange($0, in: text) }
        guard cut != text else { return (cut, ns) }
        let dropped = text.utf16.count - (cut.utf16.count - 1)  // "…" is one UTF-16 unit
        return (cut, ns.filter { $0.location >= dropped }.map { NSRange(location: $0.location - dropped + 1, length: $0.length) })
    }

    static func workingHUD(_ text: String?) -> HUD {
        guard let text, !text.isEmpty else {
            return HUD(glyph: .spinner, main: "Working…", mainColor: .secondaryLabelColor)
        }
        return HUD(glyph: .spinner, main: PreviewText.tail(text, limit: previewLimit), mainColor: .secondaryLabelColor,
                   tail: true, label: "Working…")
    }

    static func errorHUD(_ msg: String) -> HUD {
        HUD(glyph: .symbol("exclamationmark.triangle"), tint: .systemOrange, act: msg)
    }

    static func noticeHUD(_ msg: String) -> HUD { HUD(glyph: .symbol("arrow.down.to.line"), main: msg) }

    static func confirmHUD(_ msg: String) -> HUD { HUD(glyph: .symbol("checkmark"), act: msg) }

    static func cleanupOfferHUD(seconds: TimeInterval) -> HUD {
        HUD(glyph: .symbol("sparkle"), tint: .systemGreen, act: "Model ready", keys: [("⏎", "clean up now")], timer: seconds)
    }

    /// A dictation (result, not `edit`), an edit (`edit`: "Corrected Todoist") or a raw insert's cleanup (no result:
    /// "Cleaned up").
    static func outcomeHUD(_ text: String, heard: String?, result: String?, edit: Bool, undo: Bool,
                           vocabulary: String?, strip: [StatusBadge], seconds: TimeInterval) -> HUD {
        let lines = OutcomeText.lines(heard: heard, result: result, label: text, edit: false)
        var h = HUD(glyph: .symbol("checkmark"), tint: .systemBlue, heard: lines.heard, strip: strip)
        if let r = lines.result, edit {
            (h.glyph, h.tint, h.act, h.main) = (.symbol("pencil"), .systemIndigo, text, r)
        } else if let r = lines.result {
            (h.main, h.label) = (r, text)
        } else {
            (h.glyph, h.tint, h.act) = (.symbol("arrow.uturn.backward"), .systemTeal, text)
        }
        if undo { h.keys.append(("esc", "undo")) }
        if let v = vocabulary { h.keys.append(("⏎", "add “\(v)” to vocabulary")) }
        if undo || vocabulary != nil { h.timer = seconds }
        return h
    }

    // MARK: - Panel

    private func show(_ hud: HUD, for seconds: TimeInterval?) {
        hideWork?.cancel()
        keys = nil
        generation += 1
        let view = Capsule.view(hud)
        let size = view.frame.size
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        if !fieldRead {
            fieldRead = true
            field = TextIO.focusedRect().map { OverlayPlacement.appKit($0, primaryHeight: NSScreen.screens[0].frame.maxY) }
        }
        // Mid-drag, follow the drag (bottom-centre under the mouse) instead of the placement.
        let target = panel.dragging
            ? NSRect(x: round(panel.frame.midX - size.width / 2), y: panel.frame.minY, width: size.width, height: size.height)
            : place(size, on: screen)
        let appearing = !panel.isVisible
        // Bottom-anchored and centred, so it stays put while the panel animates to the new size.
        let old = appearing ? size : container.bounds.size
        view.setFrameOrigin(NSPoint(x: round((old.width - size.width) / 2), y: 0))
        view.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        container.subviews.forEach { $0.removeFromSuperview() }
        container.addSubview(view)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if appearing {
            panel.setFrame(target.offsetBy(dx: 0, dy: reduceMotion ? 0 : -6), display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        } else {
            let fade = CATransition()
            fade.duration = 0.18
            container.layer?.add(fade, forKey: "fade")
        }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = panel.dragging ? 0 : appearing ? 0.22 : 0.18
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        })
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// What the capsule shows: a tinted glyph tile, then the heard line, the main line and a footer.
struct HUD {
    enum Glyph { case symbol(String), levels, spinner }
    var glyph: Glyph
    /// `.secondaryLabelColor` means neutral: a grey tile (working, notices, confirmations).
    var tint: NSColor = .secondaryLabelColor
    var heard: String?
    /// Live preview (#43): `heard` kept to its end like `tail`, with the words the cleanup dropped struck through.
    var heardTail = false
    var heardMarks: [NSRange] = []
    /// The action verb in the tint (or `actTint`), in front of `main` ("Corrected" Todoist).
    var act: String?
    var actTint: NSColor?
    var main = ""
    /// Words of `main` the cleanup changed, underlined (#43).
    var mainMarks: [NSRange] = []
    var mainColor: NSColor = .labelColor
    /// Live preview: wrapped up to `Capsule.maxLines`, newest words at the bottom, the top fades (#82). Otherwise
    /// the text is cut in the middle to the same cap (`OutcomeText.fit`).
    var tail = false
    /// Footer text in the tint ("raw — model loading").
    var note: String?
    var label: String?
    var keys: [(cap: String, text: String)] = []
    var strip: [StatusBadge] = []
    /// The undo/accept window: a bar along the bottom edge drains over it.
    var timer: TimeInterval?
}

/// Lays out a `HUD` as a fixed-size view (frames, not constraints, so the panel size is known up front).
@MainActor
enum Capsule {
    static let radius: CGFloat = 16
    static let maxWidth: CGFloat = 640
    /// Insets: 10 left, 28 glyph, 10 gap, body, 14 right.
    private static let bodyX: CGFloat = 48, maxBody = maxWidth - bodyX - 14

    static func view(_ hud: HUD) -> NSView {
        let root = Flipped()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var y: CGFloat = 15, bodyW: CGFloat = 0
        var placed: [(NSView, CGSize)] = []
        func place(_ p: (NSView, CGSize), gap: CGFloat = 3) {
            let (v, size) = p
            if !placed.isEmpty { y += gap }
            v.frame = NSRect(origin: NSPoint(x: bodyX, y: y), size: size)
            root.addSubview(v)
            placed.append((v, size))
            y += size.height
            bodyW = max(bodyW, size.width)
        }

        // Marks index the whole text, so they're dropped once `fitted` cuts it.
        if let h = hud.heard {
            func heard(_ t: String) -> NSAttributedString {
                let s = NSMutableAttributedString(attributedString: attr(t, 11.5, .regular, .secondaryLabelColor))
                for r in t == h ? hud.heardMarks : [] {
                    s.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.tertiaryLabelColor], range: r)
                }
                return s
            }
            place(hud.heardTail ? block(heard(h)) : fitted(h, heard))
        }
        func main(_ body: String) -> NSAttributedString {
            let main = NSMutableAttributedString()
            if let a = hud.act { main.append(attr(a, 13, .semibold, hud.actTint ?? hud.tint)) }
            guard !body.isEmpty else { return main }
            let at = main.length + (hud.act == nil ? 0 : 1)
            main.append(attr((hud.act == nil ? "" : " ") + body, 13, .medium, hud.mainColor))
            for r in body == hud.main ? hud.mainMarks : [] {
                main.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: NSColor.controlAccentColor,
                                    .foregroundColor: hud.mainColor == .labelColor ? NSColor.controlAccentColor : hud.mainColor],
                                   range: NSRange(location: r.location + at, length: r.length))
            }
            return main
        }
        place(hud.tail ? block(main(hud.main)) : fitted(hud.main, main))

        // Footer: label (or note) on the left, a flexible space, then keycaps and the status strip.
        var right: [(NSView, CGSize)] = hud.keys.map(keycap)
        right += hud.strip.compactMap(badge)
        let leftText = hud.label.map { attr($0, 11, .regular, .secondaryLabelColor) }
            ?? hud.note.map { attr($0, 11, .regular, hud.tint) }
        if leftText != nil || !right.isEmpty {
            // 12 between items, 7 between strip symbols.
            let gaps: [CGFloat] = right.indices.map { i in
                i == 0 ? 0 : right[i].0 is NSImageView && right[i - 1].0 is NSImageView ? 7 : 12
            }
            let rightW = zip(right, gaps).reduce(0) { $0 + $1.0.1.width + $1.1 }
            let left = leftText.map { s -> NSTextField in
                let f = NSTextField(labelWithAttributedString: s)
                f.lineBreakMode = .byTruncatingTail
                return f
            }
            let leftNat = left.map { ceil($0.fittingSize.width) } ?? 0
            let spacer: CGFloat = left != nil && !right.isEmpty ? 12 : 0
            let footW = min(max(bodyW, leftNat + spacer + rightW), maxBody)
            bodyW = footW
            let row = Flipped()
            let h: CGFloat = 18
            if let left {
                left.frame = NSRect(x: 0, y: (h - left.fittingSize.height) / 2,
                                    width: min(leftNat, footW - spacer - rightW), height: left.fittingSize.height)
                row.addSubview(left)
            }
            var x = footW - rightW
            for ((v, s), g) in zip(right, gaps) {
                x += g
                v.frame = NSRect(x: x, y: (h - s.height) / 2, width: s.width, height: s.height)
                row.addSubview(v)
                x += s.width
            }
            place((row, CGSize(width: footW, height: h)), gap: 6)
        }

        let width = max(160, bodyX + bodyW + 14)
        let height = max(48, y + 10)
        root.frame = NSRect(x: 0, y: 0, width: width, height: height)

        // Glyph tile.
        let neutral = hud.tint == .secondaryLabelColor
        let tile = Box(NSRect(x: 10, y: 10, width: 28, height: 28),
                       neutral ? .quaternaryLabelColor : hud.tint.withAlphaComponent(0.14), radius: 8)
        root.addSubview(tile)
        switch hud.glyph {
        case .symbol(let name):
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let v = NSImageView(image: img)
                v.contentTintColor = hud.tint
                v.frame = NSRect(x: (28 - img.size.width) / 2, y: (28 - img.size.height) / 2,
                                 width: img.size.width, height: img.size.height)
                tile.addSubview(v)
            }
        case .levels:
            for i in 0..<3 {
                let bar = Box(NSRect(x: 8.25 + CGFloat(i) * 4.5, y: 7, width: 2.5, height: 14), hud.tint, radius: 1.25)
                if !reduceMotion {
                    let a = CAKeyframeAnimation(keyPath: "transform")
                    a.values = [0.35, 1, 0.35].map { s in
                        NSValue(caTransform3D: CATransform3DConcat(CATransform3DMakeScale(1, s, 1),
                                                                   CATransform3DMakeTranslation(0, 14 * (1 - s) / 2, 0)))
                    }
                    a.duration = 0.9
                    a.repeatCount = .infinity
                    a.timeOffset = 0.3 * Double(i)
                    a.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
                    bar.animation = a
                }
                tile.addSubview(bar)
            }
        case .spinner:
            let s = NSProgressIndicator(frame: NSRect(x: 6, y: 6, width: 16, height: 16))
            s.style = .spinning
            s.controlSize = .small
            s.isDisplayedWhenStopped = true
            if !reduceMotion { s.startAnimation(nil) }
            tile.addSubview(s)
        }

        // Undo-window bar: drains left to right over the window; static with Reduce Motion.
        if let t = hud.timer {
            let bar = Box(NSRect(x: 14, y: height - 2, width: width - 28, height: 2), hud.tint.withAlphaComponent(0.55), radius: 1)
            if !reduceMotion {
                let a = CABasicAnimation(keyPath: "transform.scale.x")
                (a.fromValue, a.toValue, a.duration) = (1, 0, t)
                a.timingFunction = CAMediaTimingFunction(name: .linear)
                a.fillMode = .forwards
                a.isRemovedOnCompletion = false
                bar.animation = a
            }
            root.addSubview(bar)
        }
        return root
    }

    private static func attr(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 1.5
        return NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p])
    }

    /// Wrapped text keeping its end in view, at most `maxLines` tall (`TailText`, #82). The height follows the line
    /// count, so it only changes when a line is added, not on every partial.
    private static func block(_ s: NSAttributedString) -> (NSView, CGSize) {
        let fit = s.boundingRect(with: CGSize(width: maxBody - 4, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin)
        return (TailText(s), CGSize(width: min(ceil(fit.width) + 4, maxBody), height: min(ceil(fit.height), cap(s))))
    }

    /// `text` built by `build`, wrapped, cut in the middle to `maxLines` so its start and end stay readable (#82).
    private static func fitted(_ text: String, _ build: (String) -> NSAttributedString) -> (NSView, CGSize) {
        let limit = cap(build(text))
        return wrapping(build(OutcomeText.fit(text) { wrapping(build($0)).1.height <= limit }))
    }

    static let maxLines = 4

    /// Height of `maxLines` lines in `s`'s font and paragraph style.
    private static func cap(_ s: NSAttributedString) -> CGFloat {
        let style = s.length > 0 ? s.attributes(at: s.length - 1, effectiveRange: nil) : [:]
        let lines = NSAttributedString(string: Array(repeating: "X", count: maxLines).joined(separator: "\n"), attributes: style)
        return ceil(lines.boundingRect(with: CGSize(width: maxBody, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height)
    }

    private static func wrapping(_ s: NSAttributedString) -> (NSView, CGSize) {
        let f = NSTextField(wrappingLabelWithString: "")
        f.attributedStringValue = s
        f.isSelectable = false
        let fit = f.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: maxBody, height: .greatestFiniteMagnitude))
        let size = CGSize(width: ceil(min(fit.width, maxBody)), height: ceil(fit.height))
        f.preferredMaxLayoutWidth = size.width
        return (f, size)
    }

    /// "esc undo": a small rounded key, then what it does.
    private static func keycap(_ key: (cap: String, text: String)) -> (NSView, CGSize) {
        let cap = NSTextField(labelWithAttributedString: attr(key.cap, 10.5, .semibold, .labelColor))
        let capFit = cap.fittingSize
        let keyW = max(18, ceil(capFit.width) + 6), keyH: CGFloat = 17
        let box = Box(NSRect(x: 0, y: 0, width: keyW, height: keyH), .quaternaryLabelColor, radius: 5)
        cap.frame = NSRect(x: (keyW - capFit.width) / 2, y: (keyH - capFit.height) / 2, width: capFit.width, height: capFit.height)
        box.addSubview(cap)
        let text = NSTextField(labelWithAttributedString: attr(key.text, 11, .regular, .secondaryLabelColor))
        let textFit = text.fittingSize
        let row = Flipped()
        row.addSubview(box)
        text.frame = NSRect(x: keyW + 5, y: (keyH - textFit.height) / 2, width: ceil(textFit.width), height: textFit.height)
        row.addSubview(text)
        return (row, CGSize(width: keyW + 5 + ceil(textFit.width), height: keyH))
    }

    /// A muted ~11 pt SF Symbol with an accessibility label. No tooltips: PopTalk never activates, so they wouldn't show.
    private static func badge(_ b: StatusBadge) -> (NSView, CGSize)? {
        guard let img = NSImage(systemSymbolName: b.symbol, accessibilityDescription: b.help)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) else { return nil }
        let v = NSImageView(image: img)
        v.contentTintColor = .tertiaryLabelColor
        v.setAccessibilityLabel(b.help)
        return (v, img.size)
    }
}

/// Dragged by hand with left-drag, reset with right-click. Borderless and non-activating, so it never becomes key or
/// activates PopTalk: the target app keeps focus.
private final class DragPanel: NSPanel {
    var onDrop: () -> Void = {}
    var onReset: () -> Void = {}
    private(set) var dragging = false
    /// The mouse relative to the bottom-centre at mouse-down, so a size change mid-drag stays under the mouse.
    private var grab: NSPoint?

    override func sendEvent(_ e: NSEvent) {
        let m = NSEvent.mouseLocation
        switch e.type {
        case .leftMouseDown: grab = NSPoint(x: m.x - frame.midX, y: m.y - frame.minY)
        case .leftMouseDragged:
            guard let grab else { break }
            dragging = true
            setFrameOrigin(NSPoint(x: round(m.x - grab.x - frame.width / 2), y: round(m.y - grab.y)))
        case .leftMouseUp:
            if dragging { onDrop() }
            (dragging, grab) = (false, nil)
        case .rightMouseDown: onReset()
        default: super.sendEvent(e)
        }
    }
}

private final class Flipped: NSView {
    override var isFlipped: Bool { true }
}

/// A rounded fill in a dynamic colour, drawn (not a layer colour) so it follows light and dark.
/// `animation` starts once the view is on screen.
private final class Box: NSView {
    let color: NSColor, radius: CGFloat
    var animation: CAAnimation?

    init(_ frame: NSRect, _ color: NSColor, radius: CGFloat) {
        self.color = color
        self.radius = radius
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
    override func viewDidMoveToWindow() {
        guard window != nil, let animation else { return }
        wantsLayer = true
        layer?.add(animation, forKey: "motion")
    }
}

/// Wrapped text that keeps its end in view: when too tall, it's bottom-anchored and the top fades out (#82).
private final class TailText: NSView {
    let text: NSAttributedString
    init(_ text: NSAttributedString) {
        self.text = text
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text.string)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // 2 pt in from each side, like an NSTextField's text.
        let w = bounds.width - 4
        let h = ceil(text.boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude), options: .usesLineFragmentOrigin).height)
        let r = NSRect(x: 2, y: bounds.height - h, width: w, height: h)
        guard h > bounds.height, let ctx = NSGraphicsContext.current?.cgContext else {
            return text.draw(with: r, options: .usesLineFragmentOrigin)
        }
        ctx.clip(to: bounds)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        text.draw(with: r, options: .usesLineFragmentOrigin)
        let fade: CGFloat = 14
        let g = CGGradient(colorsSpace: nil, colors: [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
        ctx.setBlendMode(.destinationOut)
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: fade), options: [])
        ctx.endTransparencyLayer()
    }
}

/// The pre-macOS 26 material, with a hairline border that follows light and dark.
private final class Material: NSVisualEffectView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        wantsLayer = true
        layer?.cornerRadius = Capsule.radius
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        viewDidChangeEffectiveAppearance()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = NSColor.separatorColor.cgColor }
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
