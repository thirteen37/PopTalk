import AppKit
import ApplicationServices
import PoptalkCore
import ScreenCaptureKit
import os
import Vision

/// What's on screen at hotkey press: app, window title, focused text (AX), nearby AX text, and OCR
/// around the field when AX is thin. Held in memory for one request only; never persisted or logged.
enum ScreenContext {
    typealias Captured = (snapshot: ScreenSnapshot, profile: ResolvedProfile)

    /// Resolves the press's app profile (#96) before any source is read, and returns it with what was read.
    static func capture() async -> Captured {
        let start = ContinuousClock.now
        defer { Timing.mark("context total", since: start) }
        let (profiles, defaults, cleanup) = (AppProfiles.load(.standard), ContextSources(.standard), CleanupLevel(.standard))
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return (ScreenSnapshot(), ResolvedProfile(sources: defaults, cleanup: cleanup))
        }
        let resolve = { (domain: String?, isPrivate: Bool, isSensitive: Bool) in
            AppProfiles.resolve(bundleID: app.bundleIdentifier, domain: domain, isPrivate: isPrivate, isSensitive: isSensitive,
                                profiles: profiles, defaults: defaults, cleanup: cleanup)
        }
        var snap = ScreenSnapshot(appName: app.localizedName ?? "")
        guard !isSensitive() else { return (snap, resolve(nil, false, true)) }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        exposeTree(axApp, app)
        Timing.mark("context sensitive+exposeTree", since: start)

        var windowFrame: CGRect?
        if let window: AXUIElement = attr(axApp, kAXFocusedWindowAttribute) {
            snap.windowTitle = attr(window, kAXTitleAttribute) ?? ""
            windowFrame = frame(of: window)
        }
        let focused: AXUIElement? = attr(axApp, kAXFocusedUIElementAttribute)
        let isPrivate = CapturePolicy.isPrivateWindow(bundleID: app.bundleIdentifier, title: snap.windowTitle)
        // The page's host, for matching and (if the profile allows) the prompt; not looked up when neither can use it.
        let wantsDomain = AppProfiles.needsDomain(bundleID: app.bundleIdentifier, isPrivate: isPrivate,
                                                  profiles: profiles, defaults: defaults)
        let domain = wantsDomain ? focused.flatMap(webDomain) : nil
        let profile = resolve(domain, isPrivate, false)
        let sources = profile.sources  // #40, #96: a disabled source is never read
        let off = ContextSource.allCases.filter { defaults[$0] && !sources[$0] }.map(\.rawValue)
        Timing.log.info("""
            context profile \(profile.custom ? "custom" : "default", privacy: .public), off: \(off.joined(separator: ","), privacy: .public), \
            cleanup \(profile.cleanup.rawValue, privacy: .public)
            """)
        if sources.webDomain, let domain { snap.webDomain = domain }
        if let focused, sources.focusedText {
            let parent: AXUIElement? = attr(focused, kAXParentAttribute)
            snap.text = attr(focused, kAXValueAttribute) ?? parent.flatMap { attr($0, kAXValueAttribute) } ?? ""
            if let range: AXValue = attr(focused, kAXSelectedTextRangeAttribute) {
                var r = CFRange()
                if AXValueGetValue(range, .cfRange, &r) { snap.cursorOffset = r.location }
            }
        }

        let fieldChars = snap.text.count
        Timing.mark("context focused field \(fieldChars) chars", since: start)
        let nearby = !sources.nearbyText ? [] : focused.map(nearbyText) ?? []
        for t in nearby { snap.text += (snap.text.isEmpty ? "" : "\n") + t }
        let nearbyChars = snap.text.count - fieldChars
        Timing.mark("context nearby \(nearbyChars) chars", since: start)
        let wantsOCR = sources.ocr && NearbyText.needsOCR(fieldChars: fieldChars, nearbyChars: nearbyChars)
        // Counts only (#88): not wanted (off, private window, or enough text), not warm, not run (no permission or failed), ran.
        var ocrState = wantsOCR ? "not run" : "not wanted"
        // A cold Vision load (~14 s) would stall the request: go without OCR until the prewarm finishes (#39).
        // OCR may have been off at launch, so start the prewarm now if it never ran.
        if wantsOCR, !ocrWarm.withLock({ $0 }) { prewarmOCR(); ocrState = "not warm" }
        else if wantsOCR, CGPreflightScreenCaptureAccess(), let ocr = await ocrFocusedWindow(
            pid: app.processIdentifier, frame: windowFrame, title: snap.windowTitle, field: focused.flatMap(frame)) {
            snap.ocrText = ocr  // own budget in Prompts.window (#25)
            ocrState = "ran"
        }
        Timing.mark("context ocr done: \(ocrState), \(snap.ocrText.count) chars", since: start)
        return (sources.apply(snap), profile)
    }

    /// Chromium and Electron build their AX tree only when asked. Skips attributes already on, so it's
    /// once per process; the first press after enabling may still see a thin tree and fall back to OCR.
    private static func exposeTree(_ axApp: AXUIElement, _ app: NSRunningApplication) {
        let isElectron = app.bundleURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(
                "Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
        for name in CapturePolicy.axEnableAttributes(bundleID: app.bundleIdentifier, isElectron: isElectron) {
            if (attr(axApp, name) as Bool?) == true { return }
            if AXUIElementSetAttributeValue(axApp, name as CFString, kCFBooleanTrue) == .success { return }
        }
    }

    /// Host of the page containing `el`: the nearest `AXWebArea` ancestor's `AXURL`.
    private static func webDomain(_ el: AXUIElement) -> String? {
        var node: AXUIElement? = el
        for _ in 0..<64 {
            guard let n = node else { return nil }
            if (attr(n, kAXRoleAttribute) as String?) == "AXWebArea" {
                return (attr(n, kAXURLAttribute) as URL?)?.host()
            }
            node = attr(n, kAXParentAttribute)
        }
        return nil
    }

    /// Static text around the focused field (a chat thread above a compose box, labels), nearest first.
    /// ponytail: caps are guesses; tune them against capture latency on #23.
    private static func nearbyText(_ focused: AXUIElement) -> [String] {
        let end = ContinuousClock.now + .milliseconds(200)
        let names = [kAXRoleAttribute, kAXValueAttribute, kAXChildrenAttribute] as CFArray
        return NearbyText.collect(
            from: focused, maxUp: 8, maxDepth: 12, maxNodes: 600, maxChars: 3000,
            parent: { el in
                (attr(el, kAXRoleAttribute) as String?) == kAXWindowRole ? nil : attr(el, kAXParentAttribute)
            },
            visit: { el in
                var v: CFArray?  // one round trip per node
                guard AXUIElementCopyMultipleAttributeValues(el, names, [], &v) == .success,
                      let vals = v as? [Any], vals.count == 3 else { return (nil, []) }
                let role = vals[0] as? String
                let text = role == kAXStaticTextRole || role == kAXTextAreaRole ? vals[1] as? String : nil
                return (text, vals[2] as? [AXUIElement] ?? [])
            },
            expired: { ContinuousClock.now > end })
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero, size = CGSize.zero
        guard let p: AXValue = attr(el, kAXPositionAttribute), let s: AXValue = attr(el, kAXSizeAttribute),
              AXValueGetValue(p, .cgPoint, &origin), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// A password field is focused or a password manager is frontmost (see `CapturePolicy.isSensitive`).
    static func isSensitive() -> Bool {
        let focused: AXUIElement? = attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
        return CapturePolicy.isSensitive(subrole: focused.flatMap { attr($0, kAXSubroleAttribute) },
                                         bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    /// The first accurate-OCR request in a process loads Vision's models (~14 s measured); pay that at launch.
    private static let ocrWarm = OSAllocatedUnfairLock(initialState: false)
    static var isOCRWarm: Bool { ocrWarm.withLock { $0 } }
    private static let ocrPrewarmStarted = OSAllocatedUnfairLock(initialState: false)

    /// Runs once per process; later calls are no-ops.
    static func prewarmOCR() {
        guard ocrPrewarmStarted.withLock({ started in defer { started = true }; return !started }) else { return }
        Task.detached(priority: .utility) {
            let start = ContinuousClock.now
            defer { ocrWarm.withLock { $0 = true } }  // also when the prewarm gives up: OCR then loads on use, as before
            let size = CGSize(width: 240, height: 60)
            guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(origin: .zero, size: size))
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: "Poptalk", attributes: [.font: NSFont.systemFont(ofSize: 32)]).draw(at: CGPoint(x: 10, y: 10))
            NSGraphicsContext.current = nil
            guard let image = ctx.makeImage() else { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: image).perform([request])
            Timing.mark("ocr prewarm", since: start)
        }
    }

    /// `SCShareableContent` window order isn't front-to-back, so match the AX focused window.
    /// OCRs a band around the focused field (`field`, global points), or the whole window without one.
    private static func ocrFocusedWindow(pid: pid_t, frame: CGRect?, title: String, field: CGRect?) async -> String? {
        let start = ContinuousClock.now
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return nil }
        Timing.mark("ocr shareableContent", since: start)
        let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
        guard let i = WindowMatch.index(of: windows.map { ($0.frame, $0.title) }, frame: frame, title: title)
        else { return nil }
        let window = windows[i]
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        guard let shot = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        else { return nil }
        Timing.mark("ocr screenshot", since: start)
        let px = CGFloat(shot.width) / window.frame.width
        let crop = NearbyText.ocrCrop(field: field, window: window.frame)
        let image = shot.cropping(to: CGRect(x: crop.minX * px, y: crop.minY * px,
                                             width: crop.width * px, height: crop.height * px)) ?? shot

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        Timing.mark("ocr vision", since: start)
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
