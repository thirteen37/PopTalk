import Foundation

/// A file holding the app's pid while it records or processes, so `scripts/install.zsh` waits instead of
/// quitting it mid-dictation. A fixed path (not $TMPDIR, which differs per process); the script treats a
/// marker whose pid isn't a running PopTalk as stale.
public enum BusyMarker {
    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Caches/io.lyx.poptalk/busy")
    }

    public static func set(_ busy: Bool, at url: URL = url()) {
        if busy {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "\(getpid())\n".write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
