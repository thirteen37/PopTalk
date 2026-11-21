import Foundation

/// Terminals (#79): ⌘Z there isn't a text undo (Ghostty's reopens a closed tab) and the line's text can't be read
/// over AX, so PopTalk takes its insert back with backspaces, guarded by "no key pressed since, same app frontmost".
public enum Terminal {
    public static let bundleIDs: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "org.alacritty", "io.alacritty", "dev.warp.Warp-Stable", "dev.warp.Warp-Preview",
        "co.zeit.hyper", "org.tabby",
    ]

    public static func contains(_ bundleID: String?) -> Bool { bundleID.map(bundleIDs.contains) ?? false }
}

/// A paste into a terminal: its app's pid, and the hotkey tap's count of key-downs right before the paste.
public struct TerminalStamp: Equatable, Sendable {
    public let app: Int32
    public let keyDowns: Int

    public init(app: Int32, keyDowns: Int) { (self.app, self.keyDowns) = (app, keyDowns) }
}

extension LastInsert {
    /// How many backspaces take this insert back out of its terminal: one per character it received, spacing
    /// included. Nil (leave it alone) unless it was pasted into a terminal, no key was pressed since (the cursor
    /// may have moved), the same app is frontmost, it's within `window` seconds, and it has no newline (the shell
    /// may have run it).
    /// ponytail: one backspace per grapheme; a line editor that deletes by code point would leave part of an emoji.
    public func backspaces(frontmost: Int32?, keyDowns: Int, now: Date = Date(), window: TimeInterval = 60) -> Int? {
        guard let terminal, frontmost == terminal.app, keyDowns == terminal.keyDowns, now.timeIntervalSince(at) < window
        else { return nil }
        let typed = prefix + text
        return typed.contains(where: \.isNewline) ? nil : typed.count
    }
}
