import AppKit
import AVFoundation
import PoptalkCore
import PoptalkSpeech
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    let store = VocabularyStore()
    private let recorder = AudioRecorder()
    private var transcriber: Transcriber?
    private var loadingTranscriber = false
    private var transcriberError: String?
    private var hotkey: Hotkey!

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.register()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Poptalk")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // Set on the system-wide element, this is the process-wide AX timeout (default ~6 s): a hung app can't freeze us.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        loadTranscriber()
        hotkey = Hotkey(onPress: { [weak self] in self?.pressed() },
                        onRelease: { [weak self] in self?.released() },
                        onCancel: { [weak self] in self?.cancelled() })
        installHotkeyWhenTrusted()
    }

    /// Loads (or, after a failure, retries loading) the speech model; the last error is kept for the overlay and menu.
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

    /// The event tap needs Accessibility; retry until the user grants it.
    private func installHotkeyWhenTrusted() {
        if hotkey.install() { return }
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
        do { try recorder.start(deviceUID: Settings.inputDeviceUID) } catch {
            overlay.showError("Microphone unavailable"); return
        }
        recording = true
        targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Hotkey cancels holds under 150 ms; only then read the selection (may post ⌘C), OCR and show the HUD.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
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
            let snapshot = await ctx?.value ?? ScreenSnapshot()
            let selection = await sel?.value
            await preview?.value  // an in-flight preview must not interleave with the final pass on the actor
            let transcript: String
            do {
                transcript = try await transcriber.transcribe(
                    samples, boost: Pipeline.boostTerms(saved: store.terms, context: snapshot))
            } catch {
                overlay.showError("Transcription failed"); return
            }
            let client = LLMClient(baseURL: Settings.baseURL)
            let pipeline = Pipeline(complete: { try await client.complete(model: $0, messages: $1, json: $2, timeout: $3) },
                                    vocabulary: store, cleanupModel: Settings.cleanupModel, editModel: Settings.editModel)
            let result = await pipeline.run(Request(transcript: transcript, selection: selection, context: snapshot))
            await apply(result)
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

    private func apply(_ result: PipelineResult) async {
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
        switch result.outcome {
        case .insert(let s, let l):
            pasted = await TextIO.insert(s)
            label = pasted ? l : "No text field found — copied to clipboard"
        case .replaceSelection(let s, let l): await TextIO.replaceSelection(s); label = l
        case .insertBefore(let s): await TextIO.insertBeforeSelection(s); label = "Inserted"
        case .insertAfter(let s): await TextIO.insertAfterSelection(s); label = "Inserted"
        case .nothing, .error: return
        }
        let shown = result.remembered.map { "\(label) · saved “\($0.text)”" } ?? label
        let store = store
        // No confirmed paste: ⌘Z could undo something unrelated (e.g. a Finder move).
        overlay.showOutcome(shown, undo: pasted ? { TextIO.undo() } : nil, vocabularyOffer: result.vocabularyOffer) { [weak self] in
            guard let term = result.vocabularyOffer else { return }
            do { try store.add(term) } catch { self?.overlay.showError("Couldn't save vocabulary") }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        if transcriber == nil {
            menu.addItem(withTitle: transcriberError.map { "⚠️ Speech model failed: \($0)" } ?? "Speech model loading…",
                         action: nil, keyEquivalent: "")
        }
        let perms: [(String, Bool, String)] = [
            ("Microphone", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Privacy_Microphone"),
            ("Accessibility", AXIsProcessTrusted(), "Privacy_Accessibility"),
            ("Screen Recording", CGPreflightScreenCaptureAccess(), "Privacy_ScreenCapture"),
        ]
        for (name, ok, pane) in perms {
            let item = menu.addItem(withTitle: "\(ok ? "✅" : "⚠️") \(name)", action: #selector(openPane(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pane
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Import FluidVoice Vocabulary", action: #selector(importFluidVoice), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Poptalk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Poptalk Settings"
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openPane(_ sender: NSMenuItem) {
        if sender.representedObject as? String == "Privacy_ScreenCapture" { CGRequestScreenCaptureAccess() }
        let pane = sender.representedObject as! String
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    @objc private func importFluidVoice() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidVoice/parakeet_custom_vocabulary.json")
        let alert = NSAlert()
        do {
            let terms = try VocabularyStore.importFluidVoice(from: url)
            for t in terms { try store.add(t) }
            alert.messageText = "Imported \(terms.count) term(s) from FluidVoice."
        } catch {
            alert.messageText = "Couldn't import FluidVoice vocabulary: \(error.localizedDescription)"
        }
        alert.runModal()
    }
}
