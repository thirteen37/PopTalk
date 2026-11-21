import Foundation
import Testing
@testable import PoptalkCore

private let t0 = Date(timeIntervalSince1970: 1000)

@Test func detectsTerminalsByBundleID() {
    for id in ["com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
               "com.github.wez.wezterm", "org.alacritty", "dev.warp.Warp-Stable"] {
        #expect(Terminal.contains(id), "\(id)")
    }
    #expect(!Terminal.contains("com.apple.TextEdit"))
    #expect(!Terminal.contains(nil))
}

@Test func backspacesCountWhatTheTerminalReceived() {
    let stamp = TerminalStamp(app: 42, keyDowns: 7)
    let ins = LastInsert(target: "ghostty", text: "café 👍🏽 ok", at: t0, prefix: " ", terminal: stamp)
    #expect(ins.backspaces(frontmost: 42, keyDowns: 7, now: t0 + 5) == 10)  // graphemes plus the leading space
}

@Test func backspacesRefusedUnlessUntouched() {
    let ins = LastInsert(target: "ghostty", text: "hello", at: t0, terminal: TerminalStamp(app: 42, keyDowns: 7))
    #expect(ins.backspaces(frontmost: 42, keyDowns: 8, now: t0 + 5) == nil)  // a key pressed since
    #expect(ins.backspaces(frontmost: 9, keyDowns: 7, now: t0 + 5) == nil)  // another app frontmost
    #expect(ins.backspaces(frontmost: nil, keyDowns: 7, now: t0 + 5) == nil)
    #expect(ins.backspaces(frontmost: 42, keyDowns: 7, now: t0 + 61) == nil)  // too late
    // Not typed into a terminal: never by backspaces.
    #expect(LastInsert(target: "mail", text: "hello", at: t0).backspaces(frontmost: 42, keyDowns: 7, now: t0 + 1) == nil)
}

@Test func backspacesRefusedForNewlines() {
    // The shell may already have run it.
    for text in ["ls\n", "one\ntwo", "a\r\nb"] {
        let ins = LastInsert(target: "ghostty", text: text, at: t0, terminal: TerminalStamp(app: 42, keyDowns: 7))
        #expect(ins.backspaces(frontmost: 42, keyDowns: 7, now: t0 + 1) == nil)
    }
}
