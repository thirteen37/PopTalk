import AppKit
import AVFoundation
import PoptalkCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    let store = VocabularyStore()
    private let recorder = AudioRecorder()
    private var transcriber: Transcriber?
    private var hotkey: Hotkey!

    func applicationDidFinishLaunching(_ note: Notification) {
        Settings.register()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Poptalk")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        Task { transcriber = try? await Transcriber() }
        hotkey = Hotkey(onPress: { [weak self] in self?.pressed() },
                        onRelease: { [weak self] in self?.released() },
                        onCancel: { [weak self] in self?.cancelled() })
        installHotkeyWhenTrusted()
    }

    /// The event tap needs Accessibility; retry until the user grants it.
    private func installHotkeyWhenTrusted() {
        if hotkey.install() { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installHotkeyWhenTrusted() }
    }

    private let overlay = Overlay()
    private var contextTask: Task<ScreenSnapshot, Never>?
    private var selectionTask: Task<String?, Never>?

    private func pressed() {
        do { try recorder.start(deviceUID: Settings.inputDeviceUID) } catch {
            overlay.showError("Microphone unavailable"); return
        }
        // Capture while recording so it costs no latency; read the selection before anything changes focus.
        contextTask = Task { await ScreenContext.capture() }
        selectionTask = Task { await TextIO.selectedText() }
        overlay.showRecording()
    }

    private func cancelled() {
        _ = recorder.stop()
        contextTask?.cancel()
        selectionTask?.cancel()
        overlay.hide()
    }

    private func released() {
        let samples = recorder.stop()
        guard let transcriber else { overlay.showError("Speech model still loading…"); return }
        overlay.showWorking()
        let store = store
        Task {
            let snapshot = await contextTask?.value ?? ScreenSnapshot()
            let selection = await selectionTask?.value
            let saved = Set(store.terms.map { $0.text.lowercased() })
            let boost = store.terms + TermExtractor.terms(from: snapshot.text)
                .filter { !saved.contains($0.lowercased()) }.map { VocabTerm(text: $0) }

            let transcript: String
            do { transcript = samples.isEmpty ? "" : try await transcriber.transcribe(samples, boost: boost) } catch {
                overlay.showError("Transcription failed"); return
            }
            let client = LLMClient(baseURL: Settings.baseURL)
            let pipeline = Pipeline(complete: { try await client.complete(model: $0, messages: $1, json: $2, timeout: $3) },
                                    vocabulary: store, cleanupModel: Settings.cleanupModel, editModel: Settings.editModel)
            let result = await pipeline.run(Request(transcript: transcript, selection: selection, context: snapshot))
            await apply(result)
        }
    }

    private func apply(_ result: PipelineResult) async {
        let label: String
        switch result.outcome {
        case .nothing: overlay.hide(); return
        case .error(let msg): overlay.showError(msg); return
        case .insert(let s, let l): await TextIO.insert(s); label = l
        case .replaceSelection(let s, let l): await TextIO.replaceSelection(s); label = l
        case .insertBefore(let s): await TextIO.insertBeforeSelection(s); label = "Inserted"
        case .insertAfter(let s): await TextIO.insertAfterSelection(s); label = "Inserted"
        }
        let text = result.remembered.map { "\(label) · saved “\($0.text)”" } ?? label
        let store = store
        overlay.showOutcome(text, undo: { TextIO.undo() }, vocabularyOffer: result.vocabularyOffer) { [weak self] in
            guard let term = result.vocabularyOffer else { return }
            do { try store.add(term) } catch { self?.overlay.showError("Couldn't save vocabulary") }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
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
