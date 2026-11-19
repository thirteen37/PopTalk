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
                        onCancel: { [weak self] in _ = self?.recorder.stop() })
        installHotkeyWhenTrusted()
    }

    /// The event tap needs Accessibility; retry until the user grants it.
    private func installHotkeyWhenTrusted() {
        if hotkey.install() { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installHotkeyWhenTrusted() }
    }

    private func pressed() {
        try? recorder.start(deviceUID: Settings.inputDeviceUID)
    }

    private func released() {
        let samples = recorder.stop()
        guard let transcriber else { return }
        Task {
            let text = try await transcriber.transcribe(samples, boost: [])
            NSLog("Poptalk transcript: %@", text)
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
