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
    /// The `ModelSettings.speechModels` id `transcriber` was loaded with.
    private var transcriberModel: String?
    /// A selection that failed to load while another model was in use: not retried on every press, only once it is
    /// selected again after another.
    private var failedSwitch: String?
    private var loadingTranscriber = false { didSet { syncSpeech() } }
    private var transcriberError: String? { didSet { syncSpeech() } }
    /// Speech model download fraction while files are fetched; nil when cached or not started.
    private var speechDownload: Double? { didSet { syncSpeech() } }
    private var hotkey: Hotkey!

    func applicationWillTerminate(_ note: Notification) { BusyMarker.set(false) }

    func applicationDidFinishLaunching(_ note: Notification) {
        BusyMarker.set(false)  // a crash mid-dictation leaves one behind
        Settings.register()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        status.onChange = { [weak self] in self?.updateIcon() }
        overlay.statusStrip = { [unowned self] in
            let sel = Settings.selection
            return StatusStrip.badges(status.value, llm: sel.provider == "mlx" ? modelStatus[sel.cleanupModel] ?? .loading : .ready,
                                      sources: ContextSources(.standard), ocrWarm: ScreenContext.isOCRWarm, history: history.isEnabled)
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // Set on the system-wide element, this is the process-wide AX timeout (default ~6 s): a hung app can't freeze us.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        if ContextSources(.standard).ocr { ScreenContext.prewarmOCR() }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        loadTranscriber()
        prepareModels()
        // Text fields save on every keystroke: wait for a pause before loading what was typed.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settingsWork?.cancel()
                let work = DispatchWorkItem { self?.prepareModels(); self?.loadTranscriber() }
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
        status.value.speech = transcriber != nil ? .ready
            : loadingTranscriber ? speechDownload.map { ModelStatus(downloaded: $0) } ?? .loading
            : transcriberError.map { .failed($0) } ?? .loading
    }

    private func updateIcon() {
        let attention = status.value.needsAttention
        // Template PNGs copied into Contents/Resources by install.zsh; SF Symbols if missing (e.g. `swift run`).
        let image = Bundle.main.image(forResource: attention ? "MenuBarAttention" : "MenuBar")
            ?? NSImage(systemSymbolName: attention ? "exclamationmark.triangle" : "waveform", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = attention ? "PopTalk needs attention" : "PopTalk"
        statusItem.button?.image = image
    }

    /// Loads (or, after a failure, retries loading) the selected speech model; the last error is kept for the overlay
    /// and Settings. Switching to another selection (#73) starts only between requests and loads alongside the current
    /// model, which keeps serving (requests hold their own reference) and is replaced once the new one is ready; a
    /// failed switch keeps it.
    private func loadTranscriber() {
        let id = Settings.speechModel
        if failedSwitch != id { failedSwitch = nil }
        let from = transcriber == nil ? nil : transcriberModel
        let switching = from != nil && from != id
        guard !loadingTranscriber, transcriber == nil || (switching && failedSwitch == nil && !recording && !busy) else { return }
        loadingTranscriber = true
        speechDownload = nil
        Task {
            let name = { (id: String?) in ModelSettings.speechModels.first { $0.id == id }?.name ?? id ?? "" }
            let idle = { !self.recording && !self.busy }  // don't cover a request's overlay
            do {
                let t = try await Transcriber(version: Transcriber.version(id) ?? .v2) { f in
                    Task { @MainActor [weak self] in self?.speechDownload = f }
                }
                (transcriber, transcriberModel, transcriberError) = (t, id, nil)
                if switching, idle() { overlay.showNotice("Speech model: \(name(id))") }
            } catch where switching {
                failedSwitch = id
                if idle() {
                    overlay.showError("Couldn't load \(name(id)), still using \(name(from)): \(error.localizedDescription)"
                                      + " Select it again to retry.")
                }
            } catch {
                transcriberError = error.localizedDescription
            }
            loadingTranscriber = false
            if Settings.speechModel != id { loadTranscriber() }  // changed while loading
        }
    }

    /// MLX models of the current selection and their load state; a press before `.ready` skips the model.
    private var modelStatus: [String: ModelStatus] = [:] {
        didSet {
            status.value.models = modelStatus
            let cleanup = Settings.selection.cleanupModel
            if oldValue[cleanup] != .ready, modelStatus[cleanup] == .ready { offerCleanup() }
        }
    }

    /// What a press can do right now; providers other than MLX don't load in-process, so count as ready.
    private var runMode: RunMode {
        let sel = Settings.selection
        return RunMode(speech: status.value.speech, llm: sel.provider == "mlx" ? modelStatus[sel.cleanupModel] ?? .loading : .ready)
    }
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
    private var recording = false { didSet { syncBusyMarker() } }
    /// Going idle applies a speech model change that waited for the request (#73).
    private var busy = false { didSet { syncBusyMarker(); if !busy { loadTranscriber() } } }
    private var targetPID: pid_t?

    /// Sets the marker at once; clears it a run-loop turn later, so release's recording → busy handoff
    /// (two synchronous assignments) never leaves it briefly absent.
    private func syncBusyMarker() {
        if recording || busy { BusyMarker.set(true); return }
        DispatchQueue.main.async { [weak self] in
            if let self, !recording, !busy { BusyMarker.set(false) }
        }
    }

    private func pressed() {
        guard !busy else { return }  // one request at a time
        loadTranscriber()  // retries after a failed load
        prepareModels()  // likewise for the MLX models
        let mode = runMode
        // No speech model, nothing to record: say why. Release and cancel then no-op (not recording).
        if case .noSpeech(let msg) = mode { overlay.showNotice(msg); return }
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
            overlay.showRecording(note: { if case .raw(let note) = mode { note } else { nil } }())
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
        let system = SystemSample.now()
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
        let started = Date()
        let app = targetPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        Task {
            defer { busy = false; offerCleanup() }  // the model may have become ready while this ran
            let t0 = Timing.start()
            let snapshot = await ctx?.value ?? ScreenSnapshot()
            Timing.mark("release: context awaited", since: t0)
            let selection = await sel?.value
            Timing.mark("release: selection awaited", since: t0)
            await preview?.value  // an in-flight preview must not interleave with the final pass on the actor
            Timing.mark("release: preview drained", since: t0)
            let boost = Pipeline.boostTerms(saved: store.terms, context: snapshot,
                                            fromScreen: ContextSources(.standard).screenVocabulary)
            let heard: Transcription
            do { heard = try await transcriber.transcribe(samples, boost: boost) } catch {
                overlay.showError("Transcription failed"); return
            }
            Timing.mark("release: transcribed", since: t0)
            overlay.showWorking(heard: heard.text)
            await process(Request(transcript: heard.text, selection: selection, context: snapshot),
                          raw: heard.raw, boost: boost.map(\.text), samples: samples, started: started, app: app, since: t0, system: system)
        }
    }

    /// Runs a request through the pipeline, applies it and records it in history. `cleanup`: re-running an
    /// earlier raw insert, whose text is replaced in place rather than inserted again.
    private func process(_ request: Request, raw: String, boost: [String], samples: [Float]?, started: Date,
                         app: NSRunningApplication?, cleanup: RawInsert? = nil, since t0: ContinuousClock.Instant,
                         system: SystemSample = .now()) async {
        // Built per press, so settings changes apply to the next one. A provider that can't start (e.g.
        // Apple Intelligence off) still dictates raw.
        let complete: Pipeline.Complete
        do { complete = try await makeComplete() } catch { complete = { _, _, _, _ in throw error } }
        let models = Settings.selection
        let calls = ModelCallRecorder()
        let pipeline = Pipeline(complete: calls.wrap(complete), vocabulary: store,
                                cleanupModel: models.cleanupModel, editModel: models.editModel, skipGate: Pipeline.skipGateSetting)
        let id = UUID()
        // #49: with nothing selected, "scratch that" / "no, I meant X" act on the last dictation.
        let amend: (last: LastInsert<AXUIElement>, command: InsertCommand)? = {
            guard cleanup == nil, request.selection == nil, let last = lastInsert,
                  let command = InsertCommand(request.transcript, last: last.text),
                  let field = TextIO.focusedElement(), last.canAmend(focused: field, value: TextIO.value(of: field))
            else { return nil }
            return (last, command)
        }()
        // Before apply, which moves lastInsert to this request.
        let corrects = history.isEnabled && cleanup == nil
            ? amend?.last.requestID ?? lastInsert?.corrected(by: request.selection, in: TextIO.focusedElement()) : nil
        Timing.mark("release: provider ready", since: t0)
        var request = request
        let result: PipelineResult
        if let amend, amend.command != .change { result = PipelineResult(outcome: .nothing) } else {
            if let amend { request.selection = amend.last.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            result = await pipeline.run(request)
        }
        Timing.mark("release: pipeline done", since: t0)
        let shown = if let amend { await amendLast(amend.last, amend.command, with: result, id: id) }
            else if let cleanup { await replaceRaw(cleanup, with: result, id: id) } else {
            await apply(result, cursorKnown: request.context.cursorOffset != nil, id: id,
                        raw: RawInsert(request: request, rawTranscript: raw, boost: boost))
        }
        Timing.mark("release: applied", since: t0)
        let system = Timing.summary(system, since: t0)
        guard history.isEnabled else { return }
        let audio = samples != nil && UserDefaults.standard.bool(forKey: "historyAudio") ? "\(id).m4a" : nil
        if let audio, let samples { history.saveFile(audio) { try AudioRecorder.write(samples, to: $0) } }
        let call = calls.call
        var entry = HistoryRequest(
            id: id, at: started, app: app?.localizedName ?? request.context.appName, bundleID: app?.bundleIdentifier,
            rawTranscript: raw, transcript: request.transcript, boost: boost, selection: request.selection,
            provider: models.provider, model: call?.model, messages: call?.messages, reply: call?.reply,
            outcome: result.outcome, vocabularyOffer: result.vocabularyOffer?.text, remembered: result.remembered?.text,
            latency: Date().timeIntervalSince(started), audio: audio)
        entry.outcome = shown
        entry.system = system
        entry.speechModel = transcriberModel
        (entry.kind, entry.promptTokens, entry.sharedPrefix) = (call?.kind, call?.promptTokens, call?.sharedPrefix)
        history.append(entry)
        if let corrects { history.append(HistoryEvent(.correction, id: corrects, by: id)) }
    }

    /// Offers to clean up the last raw insert, if its field is focused and untouched and the model is ready.
    private func offerCleanup() {
        guard !busy, !recording, runMode == .full, let raw = lastInsert?.reprocess else { return }
        let valid = { [weak self] () -> Bool in
            guard let self, let field = TextIO.focusedElement() else { return false }
            return lastInsert?.canReprocess(focused: field, value: TextIO.value(of: field)) == true
        }
        guard valid() else { return }
        overlay.showCleanupOffer(isValid: valid) { [weak self] in
            guard let self, !busy, !recording else { return }
            busy = true
            overlay.showWorking()
            targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let app = NSWorkspace.shared.frontmostApplication
            Task {
                defer { self.busy = false }
                await self.process(raw.request, raw: raw.rawTranscript, boost: raw.boost, samples: nil,
                                   started: Date(), app: app, cleanup: raw, since: .now)
            }
        }
    }

    /// Selects the raw text (checked by reading it back) and pastes the cleaned text over it. Every check
    /// runs before anything changes, so a failure leaves the user's text as it was.
    private func replaceRaw(_ raw: RawInsert, with result: PipelineResult, id: UUID) async -> String {
        let failed = "Couldn't clean up"
        guard !result.degraded, case .insert(let s, _) = result.outcome, let last = lastInsert,
              let field = TextIO.focusedElement(), last.canReprocess(focused: field, value: TextIO.value(of: field)),
              TextIO.selectLast(raw.prefix + last.text, in: field)
        else { overlay.showError(failed); return failed }
        await TextIO.replaceSelection(raw.prefix + s)
        lastInsert = LastInsert(target: field, text: s, requestID: history.isEnabled ? id : nil,
                                prefix: raw.prefix, fieldValue: TextIO.value(of: field))
        let undo = { [weak self] in
            TextIO.undo()
            self?.lastInsert = nil
            self?.history.append(HistoryEvent(.undo, id: id))
        }
        overlay.showOutcome("Cleaned up", undo: undo, vocabularyOffer: nil) {}
        return "Cleaned up"
    }

    /// Applies a voice command to the last insert (#49): selects its text (checked by reading it back), then
    /// deletes it or pastes the new text over it. Every check runs before anything changes.
    private func amendLast(_ last: LastInsert<AXUIElement>, _ command: InsertCommand, with result: PipelineResult,
                           id: UUID) async -> String {
        let body = last.prefix + last.text  // exactly what was pasted
        let new: String, label: String
        if let rest = command.remainder(of: body) {
            new = rest
            label = switch command { case .deleteLastWord: "Deleted last word"; case .deleteLastSentence: "Deleted last sentence"; default: "Scratched" }
        } else if case .replaceSelection(let s, _) = result.outcome {
            new = String(body.prefix(while: \.isWhitespace)) + s
            label = InsertCommand.changed(from: last.text, to: s).map { "Changed → \(PreviewText.tail($0, limit: 40))" } ?? "Changed"
        } else {
            let msg = if case .error(let m) = result.outcome { m } else { "Couldn't change that" }
            overlay.showError(msg); return msg
        }
        let failed = "Couldn't edit the last dictation"
        guard let field = TextIO.focusedElement(), last.canAmend(focused: field, value: TextIO.value(of: field)),
              TextIO.selectLast(body, in: field)
        else { overlay.showError(failed); return failed }
        if new.isEmpty { TextIO.press(.delete) } else { await TextIO.replaceSelection(new) }
        lastInsert = new.isEmpty ? nil
            : LastInsert(target: field, text: new, requestID: history.isEnabled ? id : nil, fieldValue: TextIO.value(of: field))
        let undo = { [weak self] in
            TextIO.undo()
            self?.lastInsert = last  // the field is back as it was, so commands on it work again
            self?.history.append(HistoryEvent(.undo, id: id))
        }
        overlay.showOutcome(label, undo: undo, vocabularyOffer: nil) {}
        return label
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
                      let text = try? await transcriber.transcribe(samples, boost: []).text,
                      !Task.isCancelled, !text.isEmpty else { continue }
                overlay.showPreview(text)
            }
        }
    }

    /// Where PopTalk last pasted; spaces the next dictation when the cursor position is unknown.
    private var lastInsert: LastInsert<AXUIElement>?

    /// Opt-in usage history (#38); writes nothing unless enabled in Settings.
    let history = HistoryStore { UserDefaults.standard.bool(forKey: "historyEnabled") }
    /// The request whose vocabulary offer is showing; resolved as accepted or declined.
    private var pendingOffer: UUID?

    private func resolveOffer(_ id: UUID, _ kind: HistoryEvent.Kind) {
        guard pendingOffer == id else { return }
        pendingOffer = nil
        history.append(HistoryEvent(kind, id: id))
    }

    /// Applies the outcome and returns the label shown, for history.
    /// `raw`: kept on `lastInsert` for a later cleanup when the result was a raw insert while the model loaded.
    private func apply(_ result: PipelineResult, cursorKnown: Bool, id: UUID, raw: RawInsert) async -> String {
        let text: String
        switch result.outcome {
        case .nothing: overlay.hide(); return "Nothing"
        case .error(let msg): overlay.showError(msg); return msg
        case .insert(let s, _), .replaceSelection(let s, _), .insertBefore(let s), .insertAfter(let s): text = s
        }
        // Focus moved while we worked: don't paste into the wrong app; leave the result on the clipboard.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text.trimmingCharacters(in: .whitespaces), forType: .string)
            overlay.showError("App changed — result copied to clipboard")
            return "App changed — result copied to clipboard"
        }
        let label: String
        var pasted = true
        var space = ""
        let field = TextIO.focusedElement()
        switch result.outcome {
        case .insert(let s, let l):
            // With a known cursor the pipeline already spaced it.
            space = cursorKnown ? "" : field.flatMap { lastInsert?.space(before: s, into: $0) } ?? ""
            pasted = await TextIO.insert(space + s)
            label = pasted ? l : "No text field found — copied to clipboard"
        case .replaceSelection(let s, let l): await TextIO.replaceSelection(s); label = l
        case .insertBefore(let s): await TextIO.insertBeforeSelection(s); label = "Inserted"
        case .insertAfter(let s): await TextIO.insertAfterSelection(s); label = "Inserted"
        case .nothing, .error: return ""
        }
        var reprocess: RawInsert?
        if result.degraded, let field {
            reprocess = raw
            reprocess?.prefix = space
            reprocess?.fieldValue = TextIO.value(of: field)  // after the paste: the text a cleanup must find unchanged
        }
        // Only a dictation takes voice commands (#49): scratching a replacement would lose what it replaced.
        let amendable: String? = if case .insert = result.outcome, let field {
            reprocess?.fieldValue ?? TextIO.value(of: field)
        } else { nil }
        lastInsert = pasted ? field.map {
            LastInsert(target: $0, text: text, requestID: history.isEnabled ? id : nil, reprocess: reprocess,
                       prefix: space, fieldValue: amendable)
        } : nil
        let shown = result.remembered.map { "\(label) · saved “\($0.text)”" } ?? label
        let store = store
        // A newer outcome replaced the old offer unanswered.
        if let old = pendingOffer { resolveOffer(old, .vocabularyDeclined) }
        if result.vocabularyOffer != nil {
            pendingOffer = id
            DispatchQueue.main.asyncAfter(deadline: .now() + Overlay.outcomeSeconds + 0.1) { [weak self] in
                self?.resolveOffer(id, .vocabularyDeclined)
            }
        }
        // No confirmed paste: ⌘Z could undo something unrelated (e.g. a Finder move).
        let undo: (() -> Void)? = pasted ? { [weak self] in
            TextIO.undo()
            self?.lastInsert = nil
            self?.history.append(HistoryEvent(.undo, id: id))
        } : nil
        overlay.showOutcome(shown, heard: raw.request.transcript, result: text,
                            edit: { if case .insert = result.outcome { false } else { true } }(),
                            undo: undo, vocabularyOffer: result.vocabularyOffer) { [weak self] in
            guard let term = result.vocabularyOffer else { return }
            self?.resolveOffer(id, .vocabularyAccepted)
            do { try store.add(term) } catch { self?.overlay.showError("Couldn't save vocabulary") }
        }
        return shown
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        status.refreshPermissions()
        menu.removeAllItems()
        menu.addItem(withTitle: status.value.summary, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit PopTalk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
                let view = SettingsView(tab: t, status: status, store: store, history: history) { [weak self] in
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
            w.title = "PopTalk Settings"
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
