import AppKit
import AVFoundation
import PoptalkCore
import PoptalkMLX
import PoptalkSpeech
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    let store = VocabularyStore()
    private let recorder = AudioRecorder()
    let status = StatusModel()
    private var transcriber: Transcriber? { didSet { syncSpeech() } }
    private var loadingTranscriber = false { didSet { syncSpeech() } }
    private var transcriberError: String? { didSet { syncSpeech() } }
    private var hotkey: Hotkey!

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.register()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        status.onChange = { [weak self] in self?.updateIcon() }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // Set on the system-wide element, this is the process-wide AX timeout (default ~6 s): a hung app can't freeze us.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        ScreenContext.prewarmOCR()
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        loadTranscriber()
        prepareModels()
        // Text fields save on every keystroke: wait for a pause before loading what was typed.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settingsWork?.cancel()
                let work = DispatchWorkItem { self?.prepareModels() }
                self?.settingsWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            }
        }
        hotkey = Hotkey(onPress: { [weak self] in self?.pressed() },
                        onRelease: { [weak self] in self?.released() },
                        onCancel: { [weak self] in self?.cancelled() })
        installHotkeyWhenTrusted()  // also checks permissions
        if let tab = status.value.launchTab { openSettings(at: tab) }
    }

    private func syncSpeech() {
        status.value.speech = transcriber != nil ? .ready : loadingTranscriber ? .loading
            : transcriberError.map { .failed($0) } ?? .loading
    }

    private func updateIcon() {
        let attention = status.value.needsAttention
        // Template PNGs copied into Contents/Resources by install.zsh; SF Symbols if missing (e.g. `swift run`).
        let image = Bundle.main.image(forResource: attention ? "MenuBarAttention" : "MenuBar")
            ?? NSImage(systemSymbolName: attention ? "exclamationmark.triangle" : "waveform", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = attention ? "Poptalk needs attention" : "Poptalk"
        statusItem.button?.image = image
    }

    /// Loads (or, after a failure, retries loading) the speech model; the last error is kept for the overlay and Settings.
    private func loadTranscriber() {
        guard transcriber == nil, !loadingTranscriber else { return }
        loadingTranscriber = true
        Task {
            defer { loadingTranscriber = false }
            do { transcriber = try await Transcriber(); transcriberError = nil } catch {
                transcriberError = error.localizedDescription
            }
        }
    }

    /// MLX models of the current selection and their load state; a press before `.ready` skips the model.
    private var modelStatus: [String: ModelStatus] = [:] { didSet { status.value.models = modelStatus } }
    private var settingsWork: DispatchWorkItem?

    /// Loads and prewarms the selected MLX models in the background, unloading any others; on a repeat
    /// call, only retries failed loads (so presses and unrelated settings changes are cheap).
    private func prepareModels() {
        let ids = Settings.selection.mlxModels
        let todo = ids.filter { modelStatus[$0]?.isFailed ?? true }
        guard Set(ids) != Set(modelStatus.keys) || !todo.isEmpty else { return }
        modelStatus = modelStatus.filter { ids.contains($0.key) }
        Task { await MLXProvider.keepOnly(ids) }
        for id in todo {
            modelStatus[id] = .loading
            Task {
                do {
                    try await MLXProvider.prepare(id) { f in
                        Task { @MainActor [weak self] in
                            // Progress hops can land late: never step back from ready or for a deselected model.
                            if let s = self?.modelStatus[id], s != .ready { self?.modelStatus[id] = ModelStatus(downloaded: f) }
                        }
                    }
                    if modelStatus[id] != nil { modelStatus[id] = .ready }
                } catch {
                    if modelStatus[id] != nil { modelStatus[id] = .failed(error.localizedDescription) }
                }
            }
        }
    }

    /// The selected provider's completion function. MLX models still loading throw `ModelLoading`.
    private func makeComplete() async throws -> Pipeline.Complete {
        let sel = Settings.selection
        let base = sel.provider == "mlx" ? try await MLXProvider.make(preload: []).0
            : try Providers.make(sel.provider, baseURL: Settings.baseURL).0
        guard sel.provider == "mlx" else { return base }
        let ready = Set(modelStatus.filter { $0.value == .ready }.keys)
        return { model, messages, json, timeout in
            guard ready.contains(model) else { throw Pipeline.ModelLoading() }
            return try await base(model, messages, json, timeout)
        }
    }

    /// The event tap needs Accessibility; retry until the user grants it.
    private func installHotkeyWhenTrusted() {
        status.value.hotkeyInstalled = hotkey.install()
        status.refreshPermissions()
        if status.value.hotkeyInstalled { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installHotkeyWhenTrusted() }
    }

    private let overlay = Overlay()
    private var contextTask: Task<ScreenSnapshot, Never>?
    private var selectionTask: Task<String?, Never>?
    private var startWork: DispatchWorkItem?
    private var previewTask: Task<Void, Never>?
    private var recording = false
    private var busy = false
    private var targetPID: pid_t?

    private func pressed() {
        guard !busy else { return }  // one request at a time
        loadTranscriber()  // retries after a failed load
        prepareModels()  // likewise for the MLX models
        do { try recorder.start(deviceUID: Settings.inputDeviceUID) } catch {
            overlay.showError("Microphone unavailable"); return
        }
        recording = true
        targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Hotkey cancels holds under 150 ms; only then read the selection (may post ⌘C), OCR and show the HUD.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Timing.log.info("press: capture start")
            contextTask = Task { await ScreenContext.capture() }
            selectionTask = Task { await TextIO.selectedText() }
            overlay.showRecording()
            startPreview()
        }
        startWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func cancelled() {
        guard recording else { return }
        recording = false
        _ = recorder.stop()
        startWork?.cancel()
        previewTask?.cancel()
        previewTask = nil
        // Don't cancel selectionTask: its clipboard guard must finish waiting before it restores.
        contextTask?.cancel()
        overlay.hide()
    }

    private func released() {
        guard recording else { return }
        recording = false
        // Released right at 150 ms, before the delayed start ran: run it now and stop the scheduled copy.
        if let work = startWork, !work.isCancelled, contextTask == nil { work.perform(); work.cancel() }
        startWork = nil
        let preview = previewTask
        previewTask = nil
        preview?.cancel()
        let samples = recorder.stop()
        Timing.log.info("release: key up")
        let (ctx, sel) = (contextTask, selectionTask)
        (contextTask, selectionTask) = (nil, nil)
        guard AudioGate.hasSpeech(samples) else { overlay.hide(); return }
        guard let transcriber else {
            overlay.showError(transcriberError.map { "Speech model failed to load (retrying): \($0)" } ?? "Speech model still loading…")
            return
        }
        busy = true
        overlay.showWorking()
        let store = store
        Task {
            defer { busy = false }
            let t0 = ContinuousClock.now
            let snapshot = await ctx?.value ?? ScreenSnapshot()
            Timing.mark("release: context awaited", since: t0)
            let selection = await sel?.value
            Timing.mark("release: selection awaited", since: t0)
            await preview?.value  // an in-flight preview must not interleave with the final pass on the actor
            Timing.mark("release: preview drained", since: t0)
            let transcript: String
            do {
                transcript = try await transcriber.transcribe(
                    samples, boost: Pipeline.boostTerms(saved: store.terms, context: snapshot))
            } catch {
                overlay.showError("Transcription failed"); return
            }
            Timing.mark("release: transcribed", since: t0)
            // Built per press, so settings changes apply to the next one. A provider that can't start (e.g.
            // Apple Intelligence off) still dictates raw.
            let complete: Pipeline.Complete
            do { complete = try await makeComplete() } catch { complete = { _, _, _, _ in throw error } }
            let models = Settings.selection
            let pipeline = Pipeline(complete: complete, vocabulary: store,
                                    cleanupModel: models.cleanupModel, editModel: models.editModel)
            Timing.mark("release: provider ready", since: t0)
            let result = await pipeline.run(Request(transcript: transcript, selection: selection, context: snapshot))
            Timing.mark("release: pipeline done", since: t0)
            await apply(result, cursorKnown: snapshot.cursorOffset != nil)
            Timing.mark("release: applied", since: t0)
        }
    }

    /// While held, re-transcribes the growing recording (no boosting) for the overlay only.
    /// The loop is sequential, so a slow pass delays the next tick instead of overlapping it.
    /// ponytail: re-runs the whole buffer each tick; window the tail if long dictations get slow.
    private func startPreview() {
        guard let transcriber else { return }
        previewTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let samples = recorder.snapshot()
                guard !Task.isCancelled, AudioGate.hasSpeech(samples),
                      let text = try? await transcriber.transcribe(samples, boost: []),
                      !Task.isCancelled, !text.isEmpty else { continue }
                overlay.showPreview(text)
            }
        }
    }

    /// Where Poptalk last pasted; spaces the next dictation when the cursor position is unknown.
    private var lastInsert: LastInsert<AXUIElement>?

    private func apply(_ result: PipelineResult, cursorKnown: Bool) async {
        let text: String
        switch result.outcome {
        case .nothing: overlay.hide(); return
        case .error(let msg): overlay.showError(msg); return
        case .insert(let s, _), .replaceSelection(let s, _), .insertBefore(let s), .insertAfter(let s): text = s
        }
        // Focus moved while we worked: don't paste into the wrong app; leave the result on the clipboard.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text.trimmingCharacters(in: .whitespaces), forType: .string)
            overlay.showError("App changed — result copied to clipboard")
            return
        }
        let label: String
        var pasted = true
        let field = TextIO.focusedElement()
        switch result.outcome {
        case .insert(let s, let l):
            // With a known cursor the pipeline already spaced it.
            let space = cursorKnown ? "" : field.flatMap { lastInsert?.space(before: s, into: $0) } ?? ""
            pasted = await TextIO.insert(space + s)
            label = pasted ? l : "No text field found — copied to clipboard"
        case .replaceSelection(let s, let l): await TextIO.replaceSelection(s); label = l
        case .insertBefore(let s): await TextIO.insertBeforeSelection(s); label = "Inserted"
        case .insertAfter(let s): await TextIO.insertAfterSelection(s); label = "Inserted"
        case .nothing, .error: return
        }
        lastInsert = pasted ? field.map { LastInsert(target: $0, text: text) } : nil
        let shown = result.remembered.map { "\(label) · saved “\($0.text)”" } ?? label
        let store = store
        // No confirmed paste: ⌘Z could undo something unrelated (e.g. a Finder move).
        overlay.showOutcome(shown, undo: pasted ? { [weak self] in TextIO.undo(); self?.lastInsert = nil } : nil, vocabularyOffer: result.vocabularyOffer) { [weak self] in
            guard let term = result.vocabularyOffer else { return }
            do { try store.add(term) } catch { self?.overlay.showError("Couldn't save vocabulary") }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        status.refreshPermissions()
        menu.removeAllItems()
        menu.addItem(withTitle: status.value.summary, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Poptalk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func showSettings() {
        // Lands on the problem when there is one.
        openSettings(at: status.value.needsAttention ? (status.value.missing.isEmpty ? .models : .permissions) : nil)
    }

    /// Opens Settings at `tab`, or at the last-viewed tab when nil.
    private func openSettings(at tab: SettingsTab?) {
        if settingsWindow == nil {
            // Toolbar-style tabs, as in System Settings-era apps; the window resizes to each tab's content.
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for t in SettingsTab.allCases {
                let view = SettingsView(tab: t, status: status, store: store) { [weak self] in
                    self?.loadTranscriber()  // each only retries what failed
                    self?.prepareModels()
                }
                let host = NSHostingController(rootView: view)
                host.sizingOptions = .preferredContentSize  // window tracks the content's fitting size
                host.title = t.title  // the tab controller makes it the window title
                let item = NSTabViewItem(viewController: host)
                item.label = t.title
                item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
                tabs.addTabViewItem(item)
            }
            let w = NSWindow(contentViewController: tabs)
            w.styleMask.remove(.resizable)
            w.toolbarStyle = .preference
            w.title = "Poptalk Settings"
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        if let tab, let tabs = settingsWindow?.contentViewController as? NSTabViewController {
            tabs.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab)!
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
