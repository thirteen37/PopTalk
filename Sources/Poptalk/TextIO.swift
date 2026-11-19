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
    /// Pastes `s`. Returns false if no focused editable field was found: the paste is still sent
    /// (Electron and terminals often hide their fields from AX) but `s` stays on the clipboard so it isn't lost.
    static func insert(_ s: String) async -> Bool {
        guard focusedIsEditable() else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            press(.v, flags: .maskCommand)
            return false
        }
        await paste(s)
        return true
    }

    private static func focusedIsEditable() -> Bool {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success, let focused else { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(focused as! AXUIElement, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
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
            pb.clearContents()
            pb.setString(s, forType: .string)
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
