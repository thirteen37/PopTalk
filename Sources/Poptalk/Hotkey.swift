import AppKit
import CoreGraphics
import PoptalkCore

/// Hold-to-talk on Right Option (keycode 61) via a CGEventTap. Events always pass through.
/// A hold where another key is pressed (⌥+e etc.) is cancelled; a tap under 150 ms calls `onTap`, which cancels too
/// (and accepts a typed-correction offer, #86). A second tap soon after (`HotkeyGesture`) calls `onTap` and then
/// `onDoubleTap` (undo, #109), on its release so ⌥ is up before any keystrokes are sent. A press soon after a tap
/// is `onPress(true)`: held, it's a tap-then-hold, which edits the last insert (#110).
@MainActor
final class Hotkey {
    private static let rightOption: Int64 = 61
    private let onPress: (_ afterTap: Bool) -> Void, onRelease: () -> Void, onCancel: () -> Void, onTap: () -> Void
    private let onDoubleTap: () -> Void
    private var tap: CFMachPort?
    private var gesture = HotkeyGesture()
    /// Key-downs seen from other processes: an insert in a terminal is only taken back if none came since (#79).
    private(set) var keyDowns = 0

    init(onPress: @escaping (_ afterTap: Bool) -> Void, onRelease: @escaping () -> Void, onCancel: @escaping () -> Void,
         onTap: @escaping () -> Void, onDoubleTap: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.onCancel = onCancel
        self.onTap = onTap
        self.onDoubleTap = onDoubleTap
    }

    /// Returns false until Accessibility is granted.
    @discardableResult
    func install() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, ctx in
                let me = Unmanaged<Hotkey>.fromOpaque(ctx!).takeUnretainedValue()
                MainActor.assumeIsolated { me.handle(type, event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        // Ignore keystrokes PopTalk itself posts (⌘C fallback while the key is held).
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            keyDowns += 1
            if gesture.otherKey() { onCancel() }
        case .flagsChanged where event.getIntegerValueField(.keyboardEventKeycode) == Self.rightOption:
            // NX_DEVICERALTKEYMASK: right ⌥ specifically, so a held left ⌥ can't mask the release.
            let rightDown = event.flags.rawValue & 0x40 != 0
            if rightDown, !gesture.isPressed {
                onPress(gesture.press(at: Date()))
            } else if !rightDown {
                switch gesture.release(at: Date()) {
                case .tap: onTap()
                case .doubleTap: onTap(); onDoubleTap()
                case .hold, .editHold: onRelease()
                case nil: break
                }
            }
        default:
            break
        }
    }
}
