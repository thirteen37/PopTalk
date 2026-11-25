import AppKit
import ApplicationServices
import PoptalkCore

/// Reads the selection in the frontmost app and writes text back via paste
/// (FluidVoice-style "reliable paste"), always restoring the user's clipboard.
@MainActor
enum TextIO {
    enum Key: CGKeyCode { case c = 8, v = 9, z = 6, delete = 51, left = 123, right = 124 }

    static func selectedText() async -> String? {
        let start = ContinuousClock.now
        defer { Timing.mark("selection", since: start) }
        guard !ScreenContext.isSensitive() else { return nil }  // never ⌘C out of a password field or manager
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let element = focused {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success {
                let s = value as? String ?? ""
                return s.isEmpty ? nil : s
            }
        }
        // AX unsupported (Electron, some browsers, terminals): copy and see if the clipboard changed.
        let pb = NSPasteboard.general
        return await ClipboardGuard.withPreserved(pb) {
            let before = pb.changeCount
            press(.c, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(150))
            guard pb.changeCount != before, let s = pb.string(forType: .string), !s.isEmpty else { return nil }
            return s
        }
    }

    static func replaceSelection(_ s: String) async { await paste(s) }
    /// Pastes `s`. Returns false if nothing is focused at all: the paste is still sent, but `s` stays on
    /// the clipboard so it isn't lost. Any focused element (including Electron/terminal fields that don't
    /// report a settable value) gets the normal paste-and-restore, so the user's clipboard survives.
    static func insert(_ s: String) async -> Bool {
        guard focusedElement() != nil else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            press(.v, flags: .maskCommand)
            return false
        }
        await paste(s)
        return true
    }

    static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    /// Where the focused field is, for the overlay to avoid (#78): the caret (or selection) bounds, else the
    /// element's frame; AX coordinates (top-left origin). Geometry only. Bounded by the process-wide AX timeout.
    static func focusedRect() -> CGRect? {
        guard let el = focusedElement() else { return nil }
        func get<T>(_ v: CFTypeRef?, _ type: AXValueType, _ out: T) -> T? {
            guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
            var out = out
            return AXValueGetValue(v as! AXValue, type, &out) ? out : nil
        }
        var range: CFTypeRef?, bounds: CFTypeRef?, pos: CFTypeRef?, size: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let range,
           AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, range,
                                                      &bounds) == .success,
           let r = get(bounds, .cgRect, CGRect.zero), r.height > 0 {
            return r
        }
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
              let p = get(pos, .cgPoint, CGPoint.zero), let s = get(size, .cgSize, CGSize.zero), s.height > 0
        else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// The field's whole text, when the app exposes it.
    static func value(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// The end of the field's selection (the caret, after a paste), in UTF-16 units like AX ranges.
    static func caret(in el: AXUIElement) -> Int? {
        var v: CFTypeRef?, r = CFRange()
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return r.location + r.length
    }

    /// Selects the last occurrence of `s` in `field`; true only if the selection then reads back as exactly `s`.
    static func selectLast(_ s: String, in field: AXUIElement) -> Bool {
        guard let v = value(of: field), let r = v.range(of: s, options: .backwards) else { return false }
        let ns = NSRange(r, in: v)  // AX ranges count UTF-16 units
        return select(location: ns.location, length: ns.length, expecting: s, in: field)
    }

    /// Selects the UTF-16 range in `field`; true only if the selection then reads back as exactly `s`.
    static func select(location: Int, length: Int, expecting s: String, in field: AXUIElement) -> Bool {
        var cf = CFRange(location: location, length: length)
        guard let range = AXValueCreate(.cfRange, &cf),
              AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, range) == .success
        else { return false }
        var sel: CFTypeRef?
        return AXUIElementCopyAttributeValue(field, kAXSelectedTextAttribute as CFString, &sel) == .success
            && sel as? String == s
    }

    static func insertAfterSelection(_ s: String) async {
        press(.right)
        await paste(s)
    }

    static func insertBeforeSelection(_ s: String) async {
        press(.left)
        await paste(s)
    }

    /// ⌘Z, once right ⌥ is up (#109): sent while it's still down it could arrive as ⌥⌘Z.
    static func undo() async {
        await rightOptionUp()
        press(.z, flags: .maskCommand)
    }

    /// Waits (≤300 ms) for right ⌥ to be up, so keystrokes sent next aren't modified by it. The double tap fires on the
    /// release, so it's normally up already and this returns at once; kept for a quick third press.
    private static func rightOptionUp() async {
        let start = ContinuousClock.now
        while CGEventSource.keyState(.hidSystemState, key: 61), ContinuousClock.now - start < .milliseconds(300) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        Timing.mark("right ⌥ release wait", since: start)
    }

    /// Deletes `n` characters before the cursor, then pastes `s` if any: PopTalk's edit of its insert in a terminal (#79).
    /// #89: one backspace of the burst got lost (Ghostty, plain zsh). So: wait for right ⌥ to be up (`rightOptionUp`;
    /// held, the deletes would be ⌥⌫, delete a word), then space the deletes. The undo was Esc, held as it fired.
    /// ponytail: cause not pinned (the held Esc, a delete in flight through the overlay's key tap as it was torn
    /// down, which #111 removed, or the app dropping a burst). If one still goes missing, slow the deletes.
    static func retype(deleting n: Int, then s: String) async {
        await rightOptionUp()
        for _ in 0..<n {
            press(.delete)
            try? await Task.sleep(for: .milliseconds(3))
        }
        if !s.isEmpty { await paste(s) }
    }

    private static func paste(_ s: String) async {
        let pb = NSPasteboard.general
        await ClipboardGuard.withPreserved(pb) {
            ClipboardGuard.setTemporary(s, on: pb)
            press(.v, flags: .maskCommand)
            // Give the target app time to read the pasteboard before restoring it.
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    static func press(_ key: Key, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key.rawValue, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}
