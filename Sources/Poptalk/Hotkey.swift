import AppKit
import CoreGraphics

/// Hold-to-talk on Right Option (keycode 61) via a CGEventTap. Events always pass through.
/// A hold under 150 ms, or one where another key is pressed (⌥+e etc.), is cancelled.
@MainActor
final class Hotkey {
    private static let rightOption: Int64 = 61
    private let onPress: () -> Void, onRelease: () -> Void, onCancel: () -> Void
    private var tap: CFMachPort?
    private var pressedAt: Date?
    private var cancelled = false

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.onCancel = onCancel
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
        case .keyDown where pressedAt != nil && !cancelled:
            cancelled = true
            onCancel()
        case .flagsChanged where event.getIntegerValueField(.keyboardEventKeycode) == Self.rightOption:
            // NX_DEVICERALTKEYMASK: right ⌥ specifically, so a held left ⌥ can't mask the release.
            let rightDown = event.flags.rawValue & 0x40 != 0
            if rightDown, pressedAt == nil {
                pressedAt = Date()
                cancelled = false
                onPress()
            } else if !rightDown, let start = pressedAt {
                pressedAt = nil
                if cancelled { return }
                if Date().timeIntervalSince(start) < 0.15 { onCancel() } else { onRelease() }
            }
        default:
            break
        }
    }
}
