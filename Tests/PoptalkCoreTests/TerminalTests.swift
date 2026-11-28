import Foundation
import Testing
@testable import PoptalkCore

private let t0 = Date(timeIntervalSince1970: 1000)

@Test func detectsTerminalsByBundleID() {
    for id in ["com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
               "com.github.wez.wezterm", "org.alacritty", "dev.warp.Warp-Stable", "com.superlogical.rex"] {
        #expect(Terminal.contains(id), "\(id)")
    }
    #expect(!Terminal.contains("com.apple.TextEdit"))
    #expect(!Terminal.contains(nil))
}

@Test func detectsShellHandlersByInfoPlist() {
    let shell: [String: Any] = ["CFBundleTypeRole": "Shell", "LSItemContentTypes": ["public.unix-executable"]]
    let folders: [String: Any] = ["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.directory"]]
    #expect(Terminal.declaresShell(["CFBundleDocumentTypes": [folders, shell]]))  // Ghostty's
    #expect(!Terminal.declaresShell(["CFBundleDocumentTypes": [folders]]))
    #expect(!Terminal.declaresShell(["CFBundleDocumentTypes": [["CFBundleTypeRole": "Shell", "LSItemContentTypes": ["public.directory"]]]]))
    #expect(!Terminal.declaresShell([:]))  // Herdr's, Beeper's
}

@Test func detectsLibghosttyExports() {
    #expect(Terminal.exportsGhostty(Data("\0\0_main\0_ghostty_terminal_new\0".utf8)))
    #expect(!Terminal.exportsGhostty(Data("\0_main\0_ghostty\0ghostty_\0".utf8)))
    #expect(!Terminal.exportsGhostty(Data()))
}

@Test func detectsTerminalBundles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    func app(_ name: String, docs: [[String: Any]] = [], exe: String = "_main") throws -> URL {
        let url = dir.appendingPathComponent("\(name).app"), macOS = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleExecutable": name, "CFBundleIdentifier": "test.\(name)", "CFBundleDocumentTypes": docs]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(exe.utf8).write(to: macOS.appendingPathComponent(name))
        return url
    }
    let plain = try app("Plain")
    #expect(!Terminal.detect(bundleID: "test.Plain", at: plain))
    #expect(Terminal.detect(bundleID: "com.apple.Terminal", at: plain))
    let shell = try app("Shell", docs: [["CFBundleTypeRole": "Shell", "LSItemContentTypes": ["public.unix-executable"]]])
    #expect(Terminal.detect(bundleID: "test.Shell", at: shell))
    #expect(Terminal.detect(bundleID: "test.Vt", at: try app("Vt", exe: "_ghostty_terminal_new")))
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
