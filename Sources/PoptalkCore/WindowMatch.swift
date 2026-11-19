import CoreGraphics

/// Picks the capture window that is the focused one: same frame, else same title, else the first.
/// Frames are global top-left-origin points, as both Accessibility and ScreenCaptureKit report them.
public enum WindowMatch {
    public static func index(of windows: [(frame: CGRect, title: String?)], frame: CGRect?, title: String?) -> Int? {
        if let frame, let i = windows.firstIndex(where: { $0.frame == frame }) { return i }
        if let title, !title.isEmpty, let i = windows.firstIndex(where: { $0.title == title }) { return i }
        return windows.isEmpty ? nil : 0
    }
}
