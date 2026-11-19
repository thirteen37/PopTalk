import AppKit
import ApplicationServices
import PoptalkCore
import ScreenCaptureKit
import Vision

/// What's on screen at hotkey press: app, window title, focused text (AX), OCR when AX is thin.
/// Held in memory for one request only; never persisted or logged.
enum ScreenContext {
    static func capture() async -> ScreenSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ScreenSnapshot() }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var snap = ScreenSnapshot(appName: app.localizedName ?? "")

        if let window: AXUIElement = attr(axApp, kAXFocusedWindowAttribute) {
            snap.windowTitle = attr(window, kAXTitleAttribute) ?? ""
        }
        if let focused: AXUIElement = attr(axApp, kAXFocusedUIElementAttribute) {
            let parent: AXUIElement? = attr(focused, kAXParentAttribute)
            snap.text = attr(focused, kAXValueAttribute) ?? parent.flatMap { attr($0, kAXValueAttribute) } ?? ""
            if let range: AXValue = attr(focused, kAXSelectedTextRangeAttribute) {
                var r = CFRange()
                if AXValueGetValue(range, .cfRange, &r) { snap.cursorOffset = r.location }
            }
        }

        if snap.text.count < 200, CGPreflightScreenCaptureAccess(), let ocr = await ocrFrontWindow(pid: app.processIdentifier) {
            snap.text += (snap.text.isEmpty ? "" : "\n") + ocr
        }
        return snap
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private static func ocrFrontWindow(pid: pid_t) async -> String? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowLayer == 0 })
        else { return nil }
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
