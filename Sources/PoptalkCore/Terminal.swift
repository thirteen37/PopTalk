import Foundation

/// Terminals (#79): ⌘Z there isn't a text undo (Ghostty's reopens a closed tab) and the line's text can't be read
/// over AX, so PopTalk takes its insert back with backspaces, guarded by "no key pressed since, same app frontmost".
public enum Terminal {
    public static let bundleIDs: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "org.alacritty", "io.alacritty", "dev.warp.Warp-Stable", "dev.warp.Warp-Preview",
        "co.zeit.hyper", "org.tabby", "com.superlogical.rex",
    ]

    public static func contains(_ bundleID: String?) -> Bool { bundleID.map(bundleIDs.contains) ?? false }

    /// Whether the app at `url` is a terminal (#92): a listed bundle ID, an Info.plist that opens Unix executables as
    /// a shell (`declaresShell`), or an executable that exports libghostty symbols (`exportsGhostty`). Reads the
    /// executable, which can be hundreds of MB (~1 s for 500 MB): call off the main thread, and cache the answer.
    public static func detect(bundleID: String?, at url: URL) -> Bool {
        if contains(bundleID) { return true }
        guard let bundle = Bundle(url: url) else { return false }
        if declaresShell(bundle.infoDictionary ?? [:]) { return true }
        guard let exe = bundle.executableURL, let data = try? Data(contentsOf: exe, options: .alwaysMapped) else { return false }
        return exportsGhostty(data)
    }

    /// An Info.plist `CFBundleDocumentTypes` entry with the Shell role for `public.unix-executable` (Ghostty, Terminal).
    public static func declaresShell(_ info: [String: Any]) -> Bool {
        (info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []).contains {
            $0["CFBundleTypeRole"] as? String == "Shell"
                && ($0["LSItemContentTypes"] as? [String] ?? []).contains("public.unix-executable")
        }
    }

    /// Whether an executable's bytes contain a `_ghostty_` symbol name: Ghostty and apps built on libghostty(-vt),
    /// such as Herdr.
    /// ponytail: a byte search, so any binary merely containing the string "_ghostty_" counts as a terminal; parse the
    /// Mach-O export trie if that ever misfires.
    public static func exportsGhostty(_ data: Data) -> Bool {
        let needle = Array("_ghostty_".utf8)
        return data.withUnsafeBytes { hay in
            needle.withUnsafeBytes { memmem(hay.baseAddress, hay.count, $0.baseAddress, $0.count) != nil }
        }
    }
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
