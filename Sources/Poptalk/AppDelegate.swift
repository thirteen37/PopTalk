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
    /// Screen terms that fixed a dictation (#87); recorded and used only with the setting on.
    let learned = LearnedTerms()
    private var learnedTerms: [VocabTerm] { ContextSources(.standard).rememberScreenTerms ? learned.vocabTerms() : [] }
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
        history.checkSync()  // honors another Mac's "wipe all Macs"
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
                        onCancel: { [weak self] in self?.cancelled() },
                        onTap: { [weak self] in self?.tapped() })
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
            // Live cleanup (#43) only with the model ready: degraded mode (#39) previews the raw transcript alone.
            startPreview(live: mode == .full && LivePreview.enabled(.standard))
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
        speculation?.task.cancel()
        speculation = nil
        // Don't cancel selectionTask: its clipboard guard must finish waiting before it restores.
        contextTask?.cancel()
        overlay.hide()
    }

    /// A right-⌥ tap: cancels, and accepts a showing typed-correction offer (#86), taken before `cancelled` hides it.
    private func tapped() {
        let accept = overlay.takeTapAccept()
        cancelled()
        accept?()
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
        let (spec, runs) = (speculation, speculativeRuns)
        (speculation, liveText, cleaned) = (nil, nil, nil)
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
            let boost = Pipeline.boostTerms(saved: store.terms, learned: learnedTerms, context: snapshot,
                                            fromScreen: ContextSources(.standard).screenVocabulary)
            let heard: Transcription
            do { heard = try await transcriber.transcribe(samples, boost: boost) } catch {
                overlay.showError("Transcription failed"); return
            }
            Timing.mark("release: transcribed", since: t0)
            overlay.showWorking(heard: heard.text)
            let request = Request(transcript: heard.text, selection: selection, context: snapshot)
            // #43: the speculative run already saw this exact request: insert its result (waiting if still running).
            var reused: (result: PipelineResult, calls: ModelCallRecorder)?
            if let spec {
                if LivePreview.sameInput(spec.request, request), let r = LivePreview.reusable(await spec.task.value) {
                    reused = (r, spec.calls)
                } else { spec.task.cancel() }
            }
            Timing.log.info("release: speculative runs \(runs), reused \(reused != nil ? "yes" : "no", privacy: .public)")
            await process(request, raw: heard.raw, boost: boost.map(\.text), samples: samples, started: started, app: app,
                          reused: reused, since: t0, system: system)
        }
    }

    /// Runs a request through the pipeline, applies it and records it in history. `cleanup`: re-running an
    /// earlier raw insert, whose text is replaced in place rather than inserted again. `reused`: a speculative run's
    /// result and model call for this exact request (#43), applied without running the pipeline.
    private func process(_ request: Request, raw: String, boost: [String], samples: [Float]?, started: Date,
                         app: NSRunningApplication?, cleanup: RawInsert? = nil,
                         reused: (result: PipelineResult, calls: ModelCallRecorder)? = nil, since t0: ContinuousClock.Instant,
                         system: SystemSample = .now()) async {
        typing?.end()  // before this request pastes: a fix typed in the last seconds is still checked
        typing = nil
        // Built per press, so settings changes apply to the next one. A provider that can't start (e.g.
        // Apple Intelligence off) still dictates raw.
        let complete: Pipeline.Complete
        do { complete = try await makeComplete() } catch { complete = { _, _, _, _ in throw error } }
        let models = Settings.selection
        let calls = reused?.calls ?? ModelCallRecorder()
        let pipeline = Pipeline(complete: calls.wrap(complete), vocabulary: store, learned: learnedTerms,
                                cleanupModel: models.cleanupModel, editModel: models.editModel, features: DictationFeatures(.standard))
        let id = UUID()
        // Before apply, which moves lastInsert to this request.
        let corrects = history.isEnabled && cleanup == nil
            ? lastInsert?.corrected(by: request.selection, in: TextIO.focusedElement()) : nil
        Timing.mark("release: provider ready", since: t0)
        let result = if let reused { reused.result } else { await pipeline.run(request) }
        Timing.mark("release: pipeline done", since: t0)
        let shown = if let cleanup { await replaceRaw(cleanup, with: result, id: id) } else {
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
            guard let self, let last = lastInsert else { return false }
            return canEdit(last, raw: true)
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

    /// Replaces the raw text with the cleaned text (`replaceLast`); a failure leaves the user's text as it was.
    private func replaceRaw(_ raw: RawInsert, with result: PipelineResult, id: UUID) async -> String {
        let failed = "Couldn't clean up"
        let terminal = terminalStamp()
        guard !result.degraded, case .insert(let s, _) = result.outcome, let last = lastInsert,
              await replaceLast(last, with: raw.prefix + s, raw: true)
        else { overlay.showError(failed); return failed }
        let field = TextIO.focusedElement() ?? last.target
        let now = LastInsert(target: field, text: s, requestID: history.isEnabled ? id : nil,
                             prefix: raw.prefix, terminal: terminal)
        lastInsert = now
        watchTyping(field, pasted: raw.prefix + s, transcript: raw.request.transcript, id: now.requestID)
        overlay.showOutcome("Cleaned up", undo: undoable(now) ? { [weak self] in
            await self?.undo(now, previous: raw.prefix + last.text, id: id) ?? false
        } : nil, vocabularyOffer: nil) {}
        return "Cleaned up"
    }

    static let editFailed = "Couldn't edit the last dictation"

    /// The frontmost app's pid and the key-down count, when it's a terminal (#79). Taken right before a paste, for
    /// the `LastInsert` made after it.
    private func terminalStamp() -> TerminalStamp? {
        guard let app = NSWorkspace.shared.frontmostApplication, Terminal.contains(app.bundleIdentifier) else { return nil }
        return TerminalStamp(app: app.processIdentifier, keyDowns: hotkey.keyDowns)
    }

    private func backspaces(_ last: LastInsert<AXUIElement>) -> Int? {
        last.backspaces(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier, keyDowns: hotkey.keyDowns)
    }

    /// Whether PopTalk's last insert is still as it left it, so it can be edited in place. In a terminal (#79): no key
    /// pressed since and the same app frontmost (`raw`: and it's a raw insert). Elsewhere: a raw insert (#39) with
    /// its field focused and the same text.
    private func canEdit(_ last: LastInsert<AXUIElement>, raw: Bool = false) -> Bool {
        if last.terminal != nil { return backspaces(last) != nil && (!raw || last.reprocess != nil) }
        guard let field = TextIO.focusedElement() else { return false }
        return last.canReprocess(focused: field, value: TextIO.value(of: field))
    }

    /// Replaces PopTalk's last insert with `new`, or returns false with nothing changed if `canEdit` fails. In a
    /// terminal by backspaces and a paste (#79); elsewhere by selecting it (checked by reading it back) and pasting
    /// over it. A raw insert's cleanup, and every undo in a terminal, goes through here.
    private func replaceLast(_ last: LastInsert<AXUIElement>, with new: String, raw: Bool = false) async -> Bool {
        guard canEdit(last, raw: raw) else { return false }
        if let n = backspaces(last) { await TextIO.retype(deleting: n, then: new); return true }
        guard let field = TextIO.focusedElement(), TextIO.selectLast(last.prefix + last.text, in: field) else { return false }
        await TextIO.replaceSelection(new)
        return true
    }

    /// Whether Esc may take `inserted` back: in a terminal only by backspaces, since ⌘Z there is window undo (#79).
    private func undoable(_ inserted: LastInsert<AXUIElement>?) -> Bool {
        inserted.map { $0.terminal == nil || backspaces($0) != nil } ?? (terminalStamp() == nil)
    }

    /// Esc on an outcome: takes `inserted` back out, putting back `previous` (what it replaced, "" for a dictation).
    /// ⌘Z, except in a terminal (#79): `replaceLast`, and false (having said so, nothing changed) once that isn't
    /// safe. Every undo goes through here.
    private func undo(_ inserted: LastInsert<AXUIElement>?, previous: String = "", id: UUID) async -> Bool {
        if let inserted, inserted.terminal != nil {
            guard await replaceLast(inserted, with: previous) else { overlay.showError(Self.editFailed); return false }
        } else { TextIO.undo() }
        typing?.end(flush: false)
        typing = nil
        lastInsert = nil
        learned.forget(request: id)
        history.append(HistoryEvent(.undo, id: id))
        return true
    }

    /// While held, re-transcribes the growing recording for the overlay only.
    /// The loop is sequential, so a slow pass delays the next tick instead of overlapping it.
    /// `live` (#43): boosts like the final pass, from the press's context, and at each pause runs the pipeline on the
    /// transcript so far (`speculate`); otherwise unboosted, raw preview only.
    /// ponytail: re-runs the whole buffer each tick; window the tail if long dictations get slow.
    private func startPreview(live: Bool) {
        guard let transcriber else { return }
        (speculation, speculativeRuns, liveText, cleaned) = (nil, 0, nil, nil)
        let (ctx, sel) = (contextTask, selectionTask)
        previewTask = Task {
            var fixed: LiveInput?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let tick = ContinuousClock.now
                let samples = recorder.snapshot()
                guard !Task.isCancelled, AudioGate.hasSpeech(samples) else { continue }
                if live, fixed == nil, let ctx { fixed = await liveInput(ctx, sel) }
                guard let text = try? await transcriber.transcribe(samples, boost: fixed?.boost ?? []).text,
                      !Task.isCancelled, !text.isEmpty else { continue }
                let previous = liveText
                liveText = text
                if let s = speculation, s.request.transcript != text { s.task.cancel() }  // new words: stale
                if let fixed, LivePreview.shouldRun(text, lastRun: speculation?.request.transcript, previous: previous,
                                                    paused: LivePreview.paused(samples), edit: fixed.selection != nil) {
                    speculate(Request(transcript: text, selection: fixed.selection, context: fixed.context), fixed, since: tick)
                }
                showLive()
            }
        }
    }

    /// What every speculative run of a press shares (#43): the context and selection captured at key-down, the boost
    /// terms the final pass will use, and the model settings.
    private struct LiveInput {
        let context: ScreenSnapshot, selection: String?, boost: [VocabTerm], learned: [VocabTerm]
        let complete: Pipeline.Complete, models: ModelSettings.Selection, features: DictationFeatures
    }

    private func liveInput(_ ctx: Task<ScreenSnapshot, Never>, _ sel: Task<String?, Never>?) async -> LiveInput {
        let context = await ctx.value
        let selection = await sel?.value
        let complete: Pipeline.Complete
        do { complete = try await makeComplete() } catch { complete = { _, _, _, _ in throw error } }
        let learned = learnedTerms
        return LiveInput(context: context, selection: selection,
                         boost: Pipeline.boostTerms(saved: store.terms, learned: learned, context: context,
                                                    fromScreen: ContextSources(.standard).screenVocabulary), learned: learned,
                         complete: complete, models: Settings.selection, features: DictationFeatures(.standard))
    }

    /// The latest speculative run of this press (#43) and its model call; the task returns nil once cancelled.
    private var speculation: (request: Request, calls: ModelCallRecorder, task: Task<PipelineResult?, Never>)?
    private var speculativeRuns = 0
    /// The newest live transcript, and the latest cleaned preview with the transcript it ran on.
    private var liveText: String?
    private var cleaned: (input: String, shown: LivePreview.Shown)?

    /// Runs the pipeline on the transcript so far for the overlay only: nothing is applied, saved or recorded in
    /// history, and MLX keeps it out of the prompt cache (`LivePreview.speculative`).
    private func speculate(_ request: Request, _ fixed: LiveInput, since tick: ContinuousClock.Instant) {
        speculativeRuns += 1
        let calls = ModelCallRecorder()
        var pipeline = Pipeline(complete: calls.wrap(fixed.complete), vocabulary: store, learned: fixed.learned, cleanupModel: fixed.models.cleanupModel,
                                editModel: fixed.models.editModel, features: fixed.features)
        pipeline.remembers = false
        let task = Task { [weak self] () -> PipelineResult? in
            let r = await LivePreview.$speculative.withValue(true) { await pipeline.run(request) }
            guard !Task.isCancelled else { return nil }
            if let self, recording, let shown = LivePreview.shown(r, input: request.transcript, selection: request.selection) {
                cleaned = (request.transcript, shown)
                showLive()
                Timing.mark("preview: cleaned shown", since: tick)
            }
            return r
        }
        speculation = (request, calls, task)
    }

    private func showLive() {
        guard recording, let text = liveText else { return }
        overlay.showPreview(text, cleaned: cleaned?.shown, input: cleaned?.input)
    }

    /// Where PopTalk last pasted; spaces the next dictation when the cursor position is unknown.
    private var lastInsert: LastInsert<AXUIElement>?

    /// Opt-in usage history (#38); writes nothing unless enabled in Settings.
    /// With "historySync" on too, also syncs through iCloud Drive (#76).
    let history = HistoryStore(sync: .init(defaults: .standard) {
        UserDefaults.standard.bool(forKey: "historyEnabled") && UserDefaults.standard.bool(forKey: "historySync")
    }) { UserDefaults.standard.bool(forKey: "historyEnabled") }
    /// The request whose vocabulary offer is showing; resolved as accepted or declined.
    private var pendingOffer: UUID?

    private func resolveOffer(_ id: UUID, _ kind: HistoryEvent.Kind) {
        guard pendingOffer == id else { return }
        pendingOffer = nil
        history.append(HistoryEvent(kind, id: id))
    }

    /// Watches the last dictation's field for a fix typed over it (#86).
    private var typing: TypingWatch?

    /// Starts `typing` on a dictation just pasted as `pasted` into `field`, except in a terminal or a secure field. A
    /// misheard term is offered (accepted by a right-⌥ tap); the user's version goes to history, linked to request `id`.
    private func watchTyping(_ field: AXUIElement, pasted: String, transcript: String, id: UUID?) {
        typing?.end()
        typing = nil
        guard terminalStamp() == nil, !ScreenContext.isSensitive() else { return }
        let store = store
        typing = TypingWatch(field: field, pasted: pasted, transcript: transcript, known: { store.terms },
            typed: { [weak self] in
                guard let self, !busy, !recording else { return }
                overlay.releaseKeys()  // this dictation's Esc/Return would land on the user's typing
            },
            offer: { [weak self] term in
                guard let self, !busy, !recording else { return }
                overlay.showTypedOffer(term) { [weak self] in
                    do { try store.add(term) } catch { self?.overlay.showError("Couldn't save vocabulary") }
                }
            },
            done: { [weak self] fix in
                if let id { self?.history.append(HistoryEvent(.typedCorrection, id: id, text: fix.text)) }
            })
    }

    /// #87: with the setting on, remembers the screen terms a boost (raw → boosted transcript) or the casing fix wrote
    /// into dictation `id`, if still in the text inserted. Undo forgets them again.
    private func learn(_ raw: RawInsert, _ result: PipelineResult, inserted: String, id: UUID) {
        guard ContextSources(.standard).rememberScreenTerms else { return }
        let boosted = Pipeline.termsWritten(from: raw.rawTranscript, to: raw.request.transcript, terms: raw.boost,
                                            saved: store.terms.map(\.text))
        learned.record((boosted + result.recased).filter { inserted.contains($0) }, request: id)
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
        let terminal = terminalStamp()
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
        lastInsert = pasted ? field.map {
            LastInsert(target: $0, text: text, requestID: history.isEnabled ? id : nil, reprocess: reprocess,
                       prefix: space, terminal: terminal)
        } : nil
        if case .insert = result.outcome, let field, let last = lastInsert {
            watchTyping(field, pasted: space + text, transcript: raw.request.transcript, id: last.requestID)
        }
        if case .insert = result.outcome, pasted { learn(raw, result, inserted: text, id: id) }
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
        let inserted = lastInsert
        let undo: (() async -> Bool)? = pasted && undoable(inserted) ? { [weak self] in
            await self?.undo(inserted, id: id) ?? false
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
                let view = SettingsView(tab: t, status: status, store: store, learned: learned, history: history) { [weak self] in
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
