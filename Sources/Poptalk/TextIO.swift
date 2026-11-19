import AppKit
import ApplicationServices
import PoptalkCore

/// Reads the selection in the frontmost app and writes text back via paste
/// (FluidVoice-style "reliable paste"), always restoring the user's clipboard.
@MainActor
enum TextIO {
    enum Key: CGKeyCode { case c = 8, v = 9, z = 6, left = 123, right = 124 }

    static func selectedText() async -> String? {
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
        guard hasFocusedElement() else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            press(.v, flags: .maskCommand)
            return false
        }
        await paste(s)
        return true
    }

    private static func hasFocusedElement() -> Bool {
        var focused: CFTypeRef?
        return AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                             &focused) == .success && focused != nil
    }


    static func insertAfterSelection(_ s: String) async {
        press(.right)
        await paste(s)
    }

    static func insertBeforeSelection(_ s: String) async {
        press(.left)
        await paste(s)
    }

    static func undo() { press(.z, flags: .maskCommand) }

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
