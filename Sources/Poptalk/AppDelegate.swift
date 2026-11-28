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
    /// Synced with history sync and its "Also sync vocabulary" on (#129); `syncVocabulary` merges the other Macs'.
    let store = VocabularyStore(sync: .init(defaults: .standard) {
        let d = UserDefaults.standard
        return d.bool(forKey: "historyEnabled") && d.bool(forKey: "historySync") && d.bool(forKey: Settings.vocabularySyncKey)
    })
    /// Off the main thread: reads the iCloud folder. At launch and on each press; Settings does it while open.
    private func syncVocabulary() { let s = store; Task.detached(priority: .utility) { s.sync() } }
    /// Screen terms that fixed a dictation (#87); recorded and used only with the setting on.
    let learned = LearnedTerms()
    private func learnedTerms(_ s: ContextSources) -> [VocabTerm] { s.rememberScreenTerms ? learned.vocabTerms() : [] }
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
                                      sources: profile?.sources ?? ContextSources(.standard), ocrWarm: ScreenContext.isOCRWarm,
                                      history: history.isEnabled, appOff: profile?.appOff ?? [])
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // Set on the system-wide element, this is the process-wide AX timeout (default ~6 s): a hung app can't freeze us.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        if ContextSources(.standard).ocr { ScreenContext.prewarmOCR() }
        history.checkSync()  // honors another Mac's "wipe all Macs"
        syncVocabulary()
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
        // Learn whether each app is a terminal as it comes to the front, before a dictation needs to know (#92).
        if let app = NSWorkspace.shared.frontmostApplication { isTerminal(app) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let app = NSWorkspace.shared.frontmostApplication { self?.isTerminal(app) }
            }
        }
        hotkey = Hotkey(onPress: { [weak self] in self?.pressed(afterTap: $0) },
                        onRelease: { [weak self] in self?.released() },
                        onCancel: { [weak self] in self?.cancelled() },
                        // A tap cancels at once; it accepts a showing offer only once it can't be a double tap (#111).
                        onTap: { [weak self] in self?.cancelled() },
                        onTapSettled: { [weak self] in self?.overlay.tapped() },
                        onDoubleTap: { [weak self] in self?.overlay.doubleTapped() })
        hotkey.onShift = { [weak self] in self?.shifted() }
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
    private var contextTask: Task<ScreenContext.Captured, Never>?
    /// The last press's resolved profile (#96), once its capture is done; nil shows the global sources.
    private var profile: ResolvedProfile?
    private var selectionTask: Task<String?, Never>?
    /// The hold's prefill of this press's dictation prompt (#139, `holdPrefill`).
    private var prefillTask: Task<Void, Never>?
    private var startWork: DispatchWorkItem?
    private var previewTask: Task<LiveInput?, Never>?
    private var recording = false { didSet { syncBusyMarker() } }
    /// Going idle applies a speech model change that waited for the request (#73).
    private var busy = false { didSet { syncBusyMarker(); if !busy { loadTranscriber() } } }
    private var targetPID: pid_t?
    /// The current press came right after a tap: held, it edits the last insert (#110), `editTarget` once known.
    private var editLast = false
    private var editTarget: LastInsert<AXUIElement>?
    static let nothingToEdit = "Nothing to edit"

    /// Sets the marker at once; clears it a run-loop turn later, so release's recording → busy handoff
    /// (two synchronous assignments) never leaves it briefly absent.
    private func syncBusyMarker() {
        if recording || busy { BusyMarker.set(true); return }
        DispatchQueue.main.async { [weak self] in
            if let self, !recording, !busy { BusyMarker.set(false) }
        }
    }

    /// `afterTap`: a double tap or a tap-then-hold (#110), which the delayed start tells apart.
    private func pressed(afterTap: Bool) {
        guard !busy else { return }  // one request at a time
        syncVocabulary()
        loadTranscriber()  // retries after a failed load
        prepareModels()  // likewise for the MLX models
        let mode = runMode
        // No speech model, nothing to record: say why. Release and cancel then no-op (not recording).
        if case .noSpeech(let msg) = mode { overlay.showNotice(msg); return }
        do { try recorder.start(deviceUID: Settings.inputDeviceUID) } catch {
            overlay.showError("Microphone unavailable"); return
        }
        recording = true
        (editLast, editTarget) = (afterTap, nil)
        targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // A release before `GestureTiming.tap` is a tap, which cancels; only then read the selection (may post ⌘C), OCR and show the HUD.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Tap-then-hold: the last insert is the selection, for the live preview (#43) and the final pass; with
            // none that can still be edited safely, say so rather than record.
            if editLast {
                editTarget = lastInsert.flatMap { canEdit($0) && !ScreenContext.isSensitive() ? $0 : nil }
                guard editTarget != nil else { cancelled(); overlay.showNotice(Self.nothingToEdit); return }
            }
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
            Timing.log.info("press: capture start, app \(app, privacy: .public)")
            profile = nil
            contextTask = Task {
                let c = await ScreenContext.capture()
                profile = c.profile
                return c
            }
            selectionTask = if let text = editTarget?.text.trimmingCharacters(in: .whitespacesAndNewlines) { Task { text } }
                else { Task { await TextIO.selectedText() } }
            prefillTask = mode == .full ? holdPrefill(contextTask!, selectionTask) : nil
            overlay.showRecording(note: editTarget != nil ? "Editing the last insert"
                                  : { if case .raw(let note) = mode { note } else { nil } }(),
                                  raw: LivePreview.rawCue(shifted: hotkey.shifted,
                                                          uses: UserDefaults.standard.integer(forKey: LivePreview.rawHintKey),
                                                          degraded: { if case .raw = mode { true } else { false } }()))
            // Live cleanup (#43) only with the model ready: degraded mode (#39) previews the raw transcript alone.
            startPreview(live: mode == .full && LivePreview.enabled(.standard))
        }
        startWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + GestureTiming.tap(.standard), execute: work)
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
        prefillTask?.cancel()
        prefillTask = nil
        // Don't cancel selectionTask: its clipboard guard must finish waiting before it restores.
        // A context capture means the delayed start ran and the recording HUD is up. A tap never gets there: it
        // leaves a showing outcome up, so a second tap can still undo it (#109).
        let shown = contextTask != nil
        contextTask?.cancel()
        contextTask = nil
        if shown { overlay.hide() }
    }


    /// Shift mid-hold (#131): drop the cleaned preview and say raw now. Before the delayed start the HUD isn't up
    /// yet; it reads `hotkey.shifted` itself.
    private func shifted() {
        guard recording, contextTask != nil else { return }
        speculation?.task.cancel()
        cleaned = nil
        overlay.showRaw()
    }

    private func released() {
        guard recording else { return }
        // Released right at `GestureTiming.tap`, before the delayed start ran: run it now and stop the scheduled copy. It may
        // stop the recording itself (nothing to edit, #110).
        if let work = startWork, !work.isCancelled, contextTask == nil { work.perform(); work.cancel() }
        guard recording else { return }
        recording = false
        startWork = nil
        let editing = editTarget
        let asHeard = hotkey.shifted  // #131: Shift during the hold
        let preview = previewTask
        previewTask = nil
        preview?.cancel()
        let (spec, runs) = (speculation, speculativeRuns)
        (speculation, liveText, cleaned) = (nil, nil, nil)
        let samples = recorder.stop()
        Timing.log.info("release: key up")
        let system = SystemSample.now()
        let (ctx, sel, prefill) = (contextTask, selectionTask, prefillTask)
        (contextTask, selectionTask, prefillTask) = (nil, nil, nil)
        guard AudioGate.hasSpeech(samples) else { overlay.hide(); return }
        guard let transcriber else {
            overlay.showError(transcriberError.map { "Speech model failed to load (retrying): \($0)" } ?? "Speech model still loading…")
            return
        }
        // Counts raw dictations for the recording hint (#131), which stops at `LivePreview.rawHintLimit`.
        if asHeard { UserDefaults.standard.set(UserDefaults.standard.integer(forKey: LivePreview.rawHintKey) + 1, forKey: LivePreview.rawHintKey) }
        busy = true
        overlay.showWorking()
        let store = store
        let started = Date()
        let app = targetPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        Task {
            defer { busy = false; offerCleanup() }  // the model may have become ready while this ran
            let t0 = Timing.start()
            let (snapshot, profile) = await ctx?.value
                ?? (ScreenSnapshot(), ResolvedProfile(sources: ContextSources(.standard), cleanup: CleanupLevel(.standard)))
            let sources = profile.sources
            Timing.mark("release: context awaited", since: t0)
            let selection = await sel?.value
            Timing.mark("release: selection awaited", since: t0)
            // An in-flight preview must not interleave with the final pass on the actor. Its terms are this press's (#149).
            let live = await preview?.value ?? nil
            Timing.mark("release: preview drained", since: t0)
            let (saved, learned) = (store.terms, live?.learned ?? learnedTerms(sources))
            let (terms, boost) = live.map { ($0.terms, $0.boost) } ?? pressTerms(snapshot, sources, learned: learned)
            let split = Pipeline.boostSources(boost, saved: saved, learned: learned)
            Timing.log.info("release: boost \(split.saved) saved, \(split.learned) learned, \(split.screen) screen")
            let heard: Transcription
            do { heard = try await transcriber.transcribe(samples, boost: boost) } catch {
                overlay.showError("Transcription failed"); return
            }
            Timing.mark("release: transcribed", since: t0)
            overlay.showWorking(heard: heard.text)
            var request = Request(transcript: heard.text, selection: selection, context: snapshot, cleanup: profile.cleanup)
            request.terms = terms
            // #43: the speculative run already saw this exact request: insert its result (waiting if still running).
            var reused: (result: PipelineResult, calls: ModelCallRecorder)?
            if let spec {
                if !asHeard, LivePreview.sameInput(spec.request, request), let r = LivePreview.reusable(await spec.task.value) {
                    reused = (r, spec.calls)
                } else { spec.task.cancel() }
            }
            Timing.log.info("release: speculative runs \(runs), reused \(reused != nil ? "yes" : "no", privacy: .public)")
            await prefill?.value  // its entry must be stored before the final pass plans its prompt
            Timing.mark("release: prefill drained", since: t0)
            await process(request, raw: heard.raw, boost: boost.map(\.text), sources: sources, samples: samples, started: started,
                          app: app, editing: editing, reused: reused, asHeard: asHeard, since: t0, system: system)
        }
    }

    /// Runs a request through the pipeline, applies it and records it in history. `cleanup`: re-running an
    /// earlier raw insert, whose text is replaced in place rather than inserted again. `reused`: a speculative run's
    /// result and model call for this exact request (#43), applied without running the pipeline. `sources`: the press's
    /// resolved sources (#96). `editing` (#110, tap-then-hold): the last insert, which `request` edits as its selection.
    private func process(_ request: Request, raw: String, boost: [String], sources: ContextSources, samples: [Float]?, started: Date,
                         app: NSRunningApplication?, cleanup: RawInsert? = nil, editing: LastInsert<AXUIElement>? = nil,
                         reused: (result: PipelineResult, calls: ModelCallRecorder)? = nil, asHeard: Bool = false,
                         since t0: ContinuousClock.Instant,
                         system: SystemSample = .now()) async {
        typing?.end()  // before this request pastes: a fix typed in the last seconds is still checked
        typing = nil
        // Built per press, so settings changes apply to the next one. A provider that can't start (e.g.
        // Apple Intelligence off) still dictates raw.
        let complete: Pipeline.Complete
        do { complete = try await makeComplete() } catch { complete = { _, _, _, _ in throw error } }
        let models = Settings.selection
        let calls = reused?.calls ?? ModelCallRecorder()
        var pipeline = Pipeline(complete: calls.wrap(complete), vocabulary: store, learned: learnedTerms(sources),
                                cleanupModel: models.cleanupModel, editModel: models.editModel,
                                features: DictationFeatures(.standard, sources: sources))
        if models.provider == "mlx" { (pipeline.termScore, pipeline.fidelityScore) = (MLXProvider.termScore, MLXProvider.yesNoScore) }
        let id = UUID()
        // Before apply, which moves lastInsert to this request.
        let focused = history.isEnabled && cleanup == nil ? TextIO.focusedElement() : nil
        let corrects = focused.flatMap { lastInsert?.corrected(by: request.selection, in: $0) }
        // The previous take, or one undone since (#95): an undo clears lastInsert. Never both.
        let repeats = focused.flatMap { f in (lastInsert ?? undone)?.redictated(raw: raw, selection: request.selection, in: f) }
        let earlier = repeats != nil ? (lastInsert ?? undone)?.rawTranscript : nil
        undone = nil
        Timing.mark("release: provider ready", since: t0)
        var result = if let reused { reused.result } else if asHeard { Pipeline.asHeard(request) } else { await pipeline.run(request) }
        // #97: a redictation re-says a misheard term; offer it as the edit offers do, the earlier hearing as alias.
        // Nothing when both takes heard it the same; the first qualifying change; the new take is taken as right.
        if result.vocabularyOffer == nil, case .insert = result.outcome, let earlier {
            result.vocabularyOffer = TypedCorrection(inserted: earlier, span: raw, transcript: earlier)?
                .offer(known: store.terms, isWord: TypingWatch.isWord)
        }
        Timing.mark("release: pipeline done", since: t0)
        let shown = if let cleanup { await replaceRaw(cleanup, with: result, id: id) }
            else if let editing { await editInsert(editing, with: result, transcript: request.transcript, id: id) } else {
            await apply(result, cursorKnown: request.context.cursorOffset != nil, id: id,
                        raw: RawInsert(request: request, rawTranscript: raw, boost: boost, sources: sources))
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
        entry.cleanup = request.cleanup.rawValue
        (entry.kind, entry.promptTokens, entry.sharedPrefix) = (call?.kind, call?.promptTokens, call?.sharedPrefix)
        history.append(entry)
        if let corrects { history.append(HistoryEvent(.correction, id: corrects, by: id)) }
        if let repeats { history.append(HistoryEvent(.redictation, id: repeats, by: id)) }
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
                await self.process(raw.request, raw: raw.rawTranscript, boost: raw.boost, sources: raw.sources, samples: nil,
                                   started: Date(), app: app, cleanup: raw, since: .now)
            }
        }
    }

    /// Replaces the raw text with the cleaned text (`replaceLast`); a failure leaves the user's text as it was.
    private func replaceRaw(_ raw: RawInsert, with result: PipelineResult, id: UUID) async -> String {
        let failed = "Couldn't clean up"
        let (terminal, axUndo) = (terminalStamp(), axUndoStamp())
        guard !result.degraded, case .insert(let s, _) = result.outcome, let last = lastInsert,
              await replaceLast(last, with: raw.prefix + s, raw: true)
        else { overlay.showError(failed); return failed }
        let field = TextIO.focusedElement() ?? last.target
        var now = LastInsert(target: field, text: s, requestID: history.isEnabled ? id : nil,
                             prefix: raw.prefix, terminal: terminal, axUndo: axUndo, rawTranscript: raw.rawTranscript)
        if terminal == nil { now.fieldValue = TextIO.value(of: field) }  // for a tap-then-hold edit (#110)
        now.written = written(raw, result, inserted: s)
        lastInsert = now
        watchTyping(field, pasted: raw.prefix + s, transcript: raw.request.transcript, id: now.requestID, written: now.written)
        overlay.showOutcome("Cleaned up", undo: undoable(now) ? { [weak self] in
            await self?.undo(now, previous: raw.prefix + last.text, id: id) ?? false
        } : nil, vocabularyOffer: nil) {}
        return "Cleaned up"
    }

    /// Applies a tap-then-hold edit (#110) to `last` in place (`replaceLast`): the edit of its text, as if selected.
    private func editInsert(_ last: LastInsert<AXUIElement>, with result: PipelineResult, transcript: String,
                            id: UUID) async -> String {
        let core = last.text.trimmingCharacters(in: .whitespacesAndNewlines)  // the selection it was edited as
        let edited: String, label: String
        switch result.outcome {
        case .replaceSelection(let s, let l), .insert(let s, let l): (edited, label) = (s, l)
        case .insertBefore(let s): (edited, label) = (s + core, "Inserted")
        case .insertAfter(let s): (edited, label) = (core + s, "Inserted")
        case .nothing: overlay.hide(); return "Nothing"
        case .error(let msg): overlay.showError(msg); return msg
        }
        let lead = String(last.text.prefix(while: \.isWhitespace))
        let trail = String(last.text.reversed().prefix(while: \.isWhitespace).reversed())
        let text = lead + edited + trail
        let (terminal, axUndo) = (terminalStamp(), axUndoStamp())
        guard await replaceLast(last, with: last.prefix + text) else { overlay.showError(Self.editFailed); return Self.editFailed }
        let gone = last.unlearned(by: text)
        if !gone.isEmpty { Timing.log.info("edit: forgot \(self.learned.forget(gone)) learned terms") }
        let field = TextIO.focusedElement() ?? last.target
        var now = LastInsert(target: field, text: text, requestID: history.isEnabled ? id : nil, prefix: last.prefix,
                             terminal: terminal, axUndo: axUndo)
        now.written = last.written  // for a further edit
        if terminal == nil { now.fieldValue = TextIO.value(of: field) }
        lastInsert = now
        let undo: (() async -> Bool)? = undoable(now) ? { [weak self] in
            await self?.undo(now, previous: last.prefix + last.text, id: id) ?? false
        } : nil
        return showOutcome(result, label: label, heard: transcript, text: edited, edit: true, undo: undo, id: id)
    }

    static let editFailed = "Couldn't edit the last dictation"

    /// The frontmost app's pid and the key-down count, when it's a terminal (#79). Taken right before a paste, for
    /// the `LastInsert` made after it.
    private func terminalStamp() -> TerminalStamp? {
        guard let app = NSWorkspace.shared.frontmostApplication, isTerminal(app) else { return nil }
        return TerminalStamp(app: app.processIdentifier, keyDowns: hotkey.keyDowns)
    }

    /// Bundle ID → `Terminal.detect` (#92).
    private var terminalApps: [String: Bool] = [:]

    /// Whether `app` is a terminal, as far as known: the bundle-ID list until `Terminal.detect`, started off the main
    /// thread the first time an app is seen (on activation, see launch), answers.
    @discardableResult private func isTerminal(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        if let known = terminalApps[id] { return known }
        let listed = Terminal.contains(id)
        terminalApps[id] = listed
        if !listed, let url = app.bundleURL {
            Task { @MainActor in terminalApps[id] = await Task.detached { Terminal.detect(bundleID: id, at: url) }.value }
        }
        return listed
    }

    /// Like `terminalStamp`, for an app whose ⌘Z ignores PopTalk's paste (#93): it's then deleted directly (`takeBack`).
    private func axUndoStamp() -> TerminalStamp? {
        guard let app = NSWorkspace.shared.frontmostApplication, AXUndo.contains(app.bundleIdentifier) else { return nil }
        return TerminalStamp(app: app.processIdentifier, keyDowns: hotkey.keyDowns)
    }

    private func backspaces(_ last: LastInsert<AXUIElement>) -> Int? {
        last.backspaces(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier, keyDowns: hotkey.keyDowns)
    }

    /// Whether PopTalk's last insert is still as it left it, so it can be edited in place. In a terminal (#79): no key
    /// pressed since and the same app frontmost (`raw`: and it's a raw insert). Elsewhere: its field focused with the
    /// same text (`raw`: a raw insert's, #39; else any insert's, for a tap-then-hold edit, #110).
    private func canEdit(_ last: LastInsert<AXUIElement>, raw: Bool = false) -> Bool {
        if last.terminal != nil { return backspaces(last) != nil && (!raw || last.reprocess != nil) }
        guard let field = TextIO.focusedElement() else { return false }
        let value = TextIO.value(of: field)
        return raw ? last.canReprocess(focused: field, value: value) : last.isUntouched(focused: field, value: value)
    }

    /// Replaces PopTalk's last insert with `new`, or returns false with nothing changed if `canEdit` fails. In a
    /// terminal by backspaces and a paste (#79); elsewhere by selecting it (checked by reading it back) and pasting
    /// over it. A raw insert's cleanup, and every undo in a terminal, goes through here.
    private func replaceLast(_ last: LastInsert<AXUIElement>, with new: String, raw: Bool = false) async -> Bool {
        guard canEdit(last, raw: raw) else { return false }
        if let n = backspaces(last) {
            let typed = last.prefix + last.text  // #89: graphemes vs UTF-16 of what the backspaces delete
            Timing.log.info("""
                retype: \(n) backspaces for \(typed.count) graphemes / \(typed.utf16.count) utf16, \
                paste \(new.count) graphemes / \(new.utf16.count) utf16
                """)
            await TextIO.retype(deleting: n, then: new)
            return true
        }
        guard let field = TextIO.focusedElement(), TextIO.selectLast(last.prefix + last.text, in: field) else { return false }
        await TextIO.replaceSelection(new)
        return true
    }

    /// Whether undo may take `inserted` back: in a terminal only by backspaces, since ⌘Z there is window undo (#79).
    /// In an `AXUndo` app (#93) not without a field to delete it from.
    private func undoable(_ inserted: LastInsert<AXUIElement>?) -> Bool {
        inserted.map { $0.terminal == nil || backspaces($0) != nil } ?? (terminalStamp() == nil && axUndoStamp() == nil)
    }

    /// Undo (a right-⌥ double tap, #109) on an outcome: takes `inserted` back out, putting back `previous` (what it
    /// replaced, "" for a dictation). ⌘Z, except in a terminal (#79): `replaceLast`, and in an `AXUndo` app (#93): `takeBack`; either returns false
    /// (having said so, nothing changed) once that isn't safe. Every undo goes through here.
    /// `unlearn`: the screen and learned terms the dictation wrote (`written`), forgotten with it (#130).
    private func undo(_ inserted: LastInsert<AXUIElement>?, previous: String = "", id: UUID, unlearn: [String] = []) async -> Bool {
        let path = inserted?.terminal != nil ? "terminal backspaces" : inserted?.axUndo != nil ? "AX takeBack" : "⌘Z"
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-"
        Timing.log.info("undo: \(path, privacy: .public), app \(app, privacy: .public)")
        if let inserted, inserted.terminal != nil {
            guard await replaceLast(inserted, with: previous) else { overlay.showError(Self.editFailed); return false }
        } else if let inserted, inserted.axUndo != nil {
            guard await takeBack(inserted, putting: previous) else { overlay.showError(Self.editFailed); return false }
        } else { await TextIO.undo() }
        typing?.end(flush: false)
        typing = nil
        lastInsert = nil
        undone = inserted
        undone?.deletedAt = Date()
        Timing.log.info("undo: forgot \(self.learned.forget(unlearn)) learned terms")
        history.append(HistoryEvent(.undo, id: id))
        return true
    }

    /// #93: deletes `last` from its field without ⌘Z (`axUndoSteps`), putting `previous` back; false, nothing
    /// changed, when no step applies.
    private func takeBack(_ last: LastInsert<AXUIElement>, putting previous: String) async -> Bool {
        let field = TextIO.focusedElement()
        let steps = last.axUndoSteps(focused: field, value: field.flatMap(TextIO.value(of:)),
                                     caret: field.flatMap(TextIO.caret(in:)),
                                     frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                     keyDowns: hotkey.keyDowns)
        for step in steps {
            switch step {
            case .select(let location, let length):
                guard let field, TextIO.select(location: location, length: length, expecting: last.prefix + last.text,
                                               in: field) else { continue }
                typing?.end(flush: false)  // the edit isn't the user's typing
                // A paste of "" leaves the selection in some editors (ProseMirror): a Backspace deletes it.
                await TextIO.retype(deleting: previous.isEmpty ? 1 : 0, then: previous)
                Timing.log.info("undo: deleted over AX")
            case .backspaces(let n):
                typing?.end(flush: false)
                await TextIO.retype(deleting: n, then: previous)
                Timing.log.info("undo: \(n) backspaces")
            }
            return true
        }
        return false
    }

    /// While held, re-transcribes the growing recording for the overlay only.
    /// The loop is sequential, so a slow pass delays the next tick instead of overlapping it.
    /// `live` (#43): boosts like the final pass, from the press's context, and at each pause runs the pipeline on the
    /// transcript so far (`speculate`); otherwise unboosted, raw preview only.
    /// ponytail: re-runs the whole buffer each tick; window the tail if long dictations get slow.
    private func startPreview(live: Bool) {
        guard let transcriber else { return }
        (speculation, speculativeRuns, liveText, cleaned) = (nil, 0, nil, nil)
        let (ctx, sel, prefill) = (contextTask, selectionTask, prefillTask)
        previewTask = Task {
            var fixed: LiveInput?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let tick = ContinuousClock.now
                let samples = recorder.snapshot()
                guard !Task.isCancelled, AudioGate.hasSpeech(samples) else { continue }
                // After the hold's prefill, so speculative runs start from its entry (#139).
                if live, fixed == nil, let ctx { await prefill?.value; fixed = await liveInput(ctx, sel) }
                guard let text = try? await transcriber.transcribe(samples, boost: fixed?.boost ?? []).text,
                      !Task.isCancelled, !text.isEmpty else { continue }
                let previous = liveText
                liveText = text
                if let s = speculation, s.request.transcript != text { s.task.cancel() }  // new words: stale
                if hotkey.shifted { speculation?.task.cancel(); cleaned = nil }  // #131: raw, nothing to clean
                else if let fixed, LivePreview.shouldRun(text, lastRun: speculation?.request.transcript, previous: previous,
                                                    paused: LivePreview.paused(samples), edit: fixed.selection != nil) {
                    var request = Request(transcript: text, selection: fixed.selection, context: fixed.context, cleanup: fixed.cleanup)
                    request.terms = fixed.terms
                    speculate(request, fixed, since: tick)
                }
                showLive()
            }
            return fixed
        }
    }

    /// #139: once capture is done, prefills the prompt of a long dictation up to `<transcript>` (system prompt and
    /// screen) and stores it, so release prefills only the transcript. MLX only; skipped for an edit (a selection).
    /// Wasted when the press turns out a dictation of `Pipeline.shortDictationWords` or fewer, whose prompt has no
    /// screen text, or a Shift hold. Release and the first speculative run await it.
    private func holdPrefill(_ ctx: Task<ScreenContext.Captured, Never>, _ sel: Task<String?, Never>?) -> Task<Void, Never>? {
        let models = Settings.selection
        guard models.provider == "mlx" else { return nil }
        let store = store
        return Task {
            let (context, profile) = await ctx.value
            guard (await sel?.value ?? "").isEmpty, !Task.isCancelled else { return }
            let p = Pipeline(complete: { _, _, _, _ in "" }, vocabulary: store, cleanupModel: models.cleanupModel, editModel: models.editModel)
            let (a, b) = p.dictationPrefix(context: context, cleanup: profile.cleanup)
            try? await MLXProvider.prefill(models.cleanupModel, a, b)  // logs "hold prefill" when it stored one
        }
    }

    /// What every speculative run of a press shares (#43): the context and selection captured at key-down, the terms
    /// and boost terms the final pass also uses (`pressTerms`), and the model settings.
    private struct LiveInput {
        let context: ScreenSnapshot, selection: String?, cleanup: CleanupLevel, terms: [VocabTerm], boost: [VocabTerm], learned: [VocabTerm]
        let complete: Pipeline.Complete, models: ModelSettings.Selection, features: DictationFeatures
    }

    /// A press's terms, worked out once (#149): `boostTerms` with screen terms, which the pipeline recases with
    /// (`Request.terms`), and the ones speech recognition boosts: screen terms only with screen boosting on (#130).
    private func pressTerms(_ context: ScreenSnapshot, _ sources: ContextSources,
                            learned: [VocabTerm]) -> (terms: [VocabTerm], boost: [VocabTerm]) {
        let terms = Pipeline.boostTerms(saved: store.terms, learned: learned, context: context)
        return (terms, sources.screenVocabulary ? terms
                : Pipeline.boostTerms(saved: store.terms, learned: learned, context: context, fromScreen: false))
    }

    private func liveInput(_ ctx: Task<ScreenContext.Captured, Never>, _ sel: Task<String?, Never>?) async -> LiveInput {
        let (context, profile) = await ctx.value
        let sources = profile.sources
        let selection = await sel?.value
        let complete: Pipeline.Complete
        do { complete = try await makeComplete() } catch { complete = { _, _, _, _ in throw error } }
        let learned = learnedTerms(sources)
        let (terms, boost) = pressTerms(context, sources, learned: learned)
        return LiveInput(context: context, selection: selection, cleanup: profile.cleanup, terms: terms, boost: boost, learned: learned,
                         complete: complete, models: Settings.selection, features: DictationFeatures(.standard, sources: sources))
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
        if fixed.models.provider == "mlx" { (pipeline.termScore, pipeline.fidelityScore) = (MLXProvider.termScore, MLXProvider.yesNoScore) }
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
    /// The take last undone, until the next dictation: a repeat of it is a redictation (#95).
    private var undone: LastInsert<AXUIElement>?

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
    /// Of `written` (`written(_:_:inserted:)`), the learned terms the user typed over are forgotten (#130).
    private func watchTyping(_ field: AXUIElement, pasted: String, transcript: String, id: UUID?, written: [String] = []) {
        typing?.end()
        typing = nil
        guard terminalStamp() == nil, !ScreenContext.isSensitive() else { return }
        let store = store
        typing = TypingWatch(field: field, pasted: pasted, transcript: transcript, known: { store.terms },
            typed: { [weak self] in
                guard let self, !busy, !recording else { return }
                overlay.userTyped()  // this dictation's undo would ⌘Z their typing, its offer is stale
            },
            offer: { [weak self] term in
                guard let self, !busy, !recording else { return }
                overlay.showTypedOffer(term) { [weak self] in
                    do { try store.add(term) } catch { self?.overlay.showError("Couldn't save vocabulary") }
                }
            },
            done: { [weak self] fix in
                guard let self else { return }
                if let id { history.append(HistoryEvent(.typedCorrection, id: id, text: fix.text)) }
                let reverted = fix.reverted(written)
                if !reverted.isEmpty { Timing.log.info("typed fix: forgot \(self.learned.forget(reverted)) learned terms") }
            },
            deleted: { [weak self] in
                guard let self, let id, lastInsert?.requestID == id else { return }
                lastInsert?.deletedAt = Date()
            })
    }

    /// The screen and learned terms a dictation's boost or casing fix wrote into `inserted` (#130).
    private func written(_ raw: RawInsert, _ result: PipelineResult, inserted: String) -> [String] {
        let w = Pipeline.screenTermsWritten(raw, recased: result.recased, inserted: inserted, saved: store.terms.map(\.text))
        return w.boost + w.casing
    }

    /// #87: remembers the screen terms a dictation wrote (`Pipeline.termsToLearn`). Undo forgets them again.
    private func learn(_ raw: RawInsert, _ result: PipelineResult, inserted: String) {
        guard let (fromBoost, fromCasing) = Pipeline.termsToLearn(raw, recased: result.recased, inserted: inserted,
                                                                  saved: store.terms.map(\.text)) else { return }
        let size = learned.record(fromBoost + fromCasing)
        Timing.log.info("learned: \(fromBoost.count) from boost, \(fromCasing.count) from casing, list \(size)")
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
        let (terminal, axUndo) = (terminalStamp(), axUndoStamp())
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
        let wrote: [String] = if case .insert = result.outcome { written(raw, result, inserted: text) } else { [] }
        lastInsert = pasted ? field.map {
            var last = LastInsert(target: $0, text: text, requestID: history.isEnabled ? id : nil, reprocess: reprocess,
                                  prefix: space, terminal: terminal, axUndo: axUndo, rawTranscript: raw.rawTranscript)
            last.written = wrote
            // After the paste: the text a tap-then-hold edit (#110) must find unchanged.
            if terminal == nil, !ScreenContext.isSensitive() { last.fieldValue = TextIO.value(of: $0) }
            return last
        } : nil
        if case .insert = result.outcome, let field, let last = lastInsert {
            watchTyping(field, pasted: space + text, transcript: raw.request.transcript, id: last.requestID, written: wrote)
        }
        if case .insert = result.outcome, pasted, !result.asHeard { learn(raw, result, inserted: text) }
        // No confirmed paste: ⌘Z could undo something unrelated (e.g. a Finder move).
        let inserted = lastInsert
        // What a deleting undo (#93) puts back: the selection an edit replaced. ⌘Z restores it by itself.
        var replaced = ""
        if case .replaceSelection = result.outcome, inserted?.axUndo != nil { replaced = raw.request.selection ?? "" }
        let undo: (() async -> Bool)? = pasted && undoable(inserted) ? { [weak self, replaced, wrote] in
            await self?.undo(inserted, previous: replaced, id: id, unlearn: wrote) ?? false
        } : nil
        return showOutcome(result, label: label, heard: raw.request.transcript, text: text,
                           edit: { if case .insert = result.outcome { false } else { true } }(), undo: undo, id: id)
    }

    /// Shows a request's outcome with its undo and vocabulary offer; returns the label shown, for history.
    private func showOutcome(_ result: PipelineResult, label: String, heard: String, text: String, edit: Bool,
                             undo: (() async -> Bool)?, id: UUID) -> String {
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
        overlay.showOutcome(shown, heard: heard, result: text, edit: edit,
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
        // The status menu doesn't activate PopTalk: the frontmost app is still the one the user was in (#96).
        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            let item = menu.addItem(withTitle: "Don't Read the Screen in \(app.localizedName ?? id)",
                                    action: #selector(toggleScreenOff(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = AppProfiles.screenOff(id, in: AppProfiles.load(.standard)) ? .on : .off
        }
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit PopTalk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// Creates or updates the app's profile (Settings → Apps); unchecking turns its screen sources back on.
    @objc private func toggleScreenOff(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        var profiles = AppProfiles.load(.standard)
        AppProfiles.setScreenOff(item.state != .on, bundleID: id, in: &profiles)
        AppProfiles.save(profiles, to: .standard)
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
