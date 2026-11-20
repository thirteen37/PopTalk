import AVFoundation
import Observation
import PoptalkCore
import ServiceManagement
import SwiftUI

/// UserDefaults-backed settings. The SwiftUI view binds the same keys via @AppStorage.
enum Settings {
    static func register() {
        UserDefaults.standard.register(defaults: ModelSettings.defaults)
        UserDefaults.standard.register(defaults: [OutcomeKeys.undoWindowKey: OutcomeKeys.undoWindowDefault])
        ModelSettings.migrate(.standard)
    }

    static var baseURL: URL { URL(string: UserDefaults.standard.string(forKey: "baseURL")!) ?? URL(string: ModelSettings.defaults["baseURL"]!)! }
    static var selection: ModelSettings.Selection { ModelSettings.selection(.standard) }
    static var inputDeviceUID: String? { UserDefaults.standard.string(forKey: "inputDeviceUID").flatMap { $0.isEmpty ? nil : $0 } }
}

/// Live status for the menu and Settings; `AppDelegate` writes it.
@Observable @MainActor
final class StatusModel {
    var value = AppStatus() { didSet { if value != oldValue { onChange() } } }
    @ObservationIgnored var onChange: () -> Void = {}

    /// macOS sends no notification when a permission is granted: callers poll.
    func refreshPermissions() {
        var g = Set<Permission>()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { g.insert(.microphone) }
        if AXIsProcessTrusted() { g.insert(.accessibility) }
        if CGPreflightScreenCaptureAccess() { g.insert(.screenRecording) }
        if value.granted != g { value.granted = g }
    }
}

extension SettingsTab {
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .context: "text.viewfinder"
        case .models: "cpu"
        case .permissions: "lock.shield"
        case .vocabulary: "character.book.closed"
        }
    }
}

/// One Settings tab; `AppDelegate` hosts one per toolbar tab.
struct SettingsView: View {
    static let width: CGFloat = 500
    let tab: SettingsTab
    let status: StatusModel
    let store: VocabularyStore
    let history: HistoryStore
    /// Retries whatever failed to load (speech model and/or LLM models).
    let retry: () -> Void

    @AppStorage("provider") private var provider = ModelSettings.defaults["provider"]!
    @AppStorage("baseURL") private var baseURL = ModelSettings.defaults["baseURL"]!
    @AppStorage("mlxCleanupModel") private var mlxCleanupModel = ModelSettings.defaults["mlxCleanupModel"]!
    @AppStorage("mlxEditModel") private var mlxEditModel = ModelSettings.defaults["mlxEditModel"]!
    @AppStorage("lmstudioCleanupModel") private var lmstudioCleanupModel = ModelSettings.defaults["lmstudioCleanupModel"]!
    @AppStorage("lmstudioEditModel") private var lmstudioEditModel = ModelSettings.defaults["lmstudioEditModel"]!
    @AppStorage("inputDeviceUID") private var inputDeviceUID = ""
    @AppStorage(OutcomeKeys.undoWindowKey) private var undoWindow = OutcomeKeys.undoWindowDefault
    @AppStorage(ContextSources.Key.focusedText) private var ctxFocusedText = true
    @AppStorage(ContextSources.Key.nearbyText) private var ctxNearbyText = true
    @AppStorage(ContextSources.Key.ocr) private var ctxOCR = true
    @AppStorage(ContextSources.Key.windowTitle) private var ctxWindowTitle = true
    @AppStorage(ContextSources.Key.screenVocabulary) private var ctxScreenVocabulary = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var terms: [VocabTerm] = []
    @State private var vocabMessage: String?

    private let devices = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices

    /// The device's on-device model, or why it can't be used.
    private var appleModel: String {
        do { return try Providers.make("apple", baseURL: Settings.baseURL).1["variant"] ?? "Apple Intelligence" }
        catch { return (error as? LLMError)?.description ?? error.localizedDescription }
    }

    var body: some View {
        Group {
            switch tab {
            case .general: general
            case .context: context
            case .models: models
            case .permissions: permissions
            case .vocabulary: vocabulary
            }
        }
        .task {  // runs while this tab is showing
            while !Task.isCancelled {
                status.refreshPermissions()
                let t = store.terms  // the overlay can save terms too
                if t != terms { terms = t }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var general: some View {
        Form {
            Section {
                Text("Hold Right ⌥ to talk. With text selected, what you say edits the selection.")
            }
            Section("Microphone") {
                Picker("Input", selection: $inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
            }
            Section {
                Stepper("Undo window: \(undoWindow) s", value: $undoWindow, in: OutcomeKeys.undoWindowRange)
                    .help("How long the result stays up, with Esc to undo and Return to add a suggested word.")
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
            } footer: {
                Text(versionLabel(Bundle.main.infoDictionary))
                    .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity).padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .fitted()
    }

    /// What's read at each press (#40), then what's recorded (#38).
    private var context: some View {
        Form {
            Section {
                Toggle("Focused field text", isOn: $ctxFocusedText)
                Toggle("Nearby text", isOn: $ctxNearbyText)
                Toggle("Screen text (OCR)", isOn: $ctxOCR)
                Toggle("App & window title, web domain", isOn: $ctxWindowTitle)
                Toggle("Boost recognition with words on screen", isOn: $ctxScreenVocabulary)
            } header: {
                Text("Context sources")
            } footer: {
                Text("What PopTalk reads on each press to understand what you're writing. Selected text is always used (edits need it), saved vocabulary always boosts recognition, and password fields are never read. Screen text needs Screen Recording.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HistorySection(history: history)
        }
        .formStyle(.grouped)
        .fitted()
    }

    private var models: some View {
        Form {
            Section("Language model") {
                Picker("Provider", selection: $provider) {
                    Text("MLX (in-process)").tag("mlx")
                    Text("LM Studio").tag("lmstudio")
                    Text("Apple on-device").tag("apple")
                }
                switch provider {
                case "lmstudio":
                    TextField("Server URL", text: $baseURL)
                    TextField("Dictation cleanup model", text: $lmstudioCleanupModel)
                    TextField("Edit model", text: $lmstudioEditModel)
                case "apple":
                    LabeledContent("Model", value: appleModel)
                default:
                    MLXModelPicker(label: "Dictation cleanup model", id: $mlxCleanupModel)
                    MLXModelPicker(label: "Edit model", id: $mlxEditModel)
                }
            }
            Section("Status") {
                statusRow("Speech model", status.value.speech)
                let sel = Settings.selection
                ForEach(sel.mlxModels, id: \.self) { id in
                    let role = sel.cleanupModel == sel.editModel ? "Model" : id == sel.cleanupModel ? "Cleanup model" : "Edit model"
                    statusRow("\(role) \(ModelSettings.displayName(id))", status.value.models[id] ?? .loading).help(id)
                }
            }
        }
        .formStyle(.grouped)
        .fitted()
    }

    private func statusRow(_ name: String, _ s: ModelStatus) -> some View {
        LabeledContent(name) {
            HStack {
                Text(s.title).lineLimit(2).textSelection(.enabled)
                if s.isFailed { Button("Retry", action: retry) }
            }
        }
    }

    private var permissions: some View {
        Form {
            Section {
                ForEach(Permission.allCases, id: \.self) { p in
                    LabeledContent {
                        Button("Open System Settings") {
                            if p == .screenRecording { CGRequestScreenCaptureAccess() }
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(p.pane)")!)
                        }
                    } label: {
                        Label(p.rawValue, systemImage: status.value.isGranted(p) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(status.value.isGranted(p) ? .green : status.value.missing.contains(p) ? .orange : .secondary)
                    }
                }
            } footer: {
                Text("Input Monitoring is checked by whether the hotkey is active; Accessibility usually covers it. Screen Recording is optional: it adds on-screen text as context.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fitted()
    }

    private var vocabulary: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(terms, id: \.text) { t in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(t.text)
                            if !t.aliases.isEmpty {
                                Text(t.aliases.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { delete(t) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            .overlay { if terms.isEmpty { Text("No saved terms").foregroundStyle(.secondary) } }
            HStack {
                Button("Import FluidVoice Vocabulary", action: importFluidVoice)
                if let vocabMessage { Text(vocabMessage).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .padding()
        .frame(width: SettingsView.width, height: 400)
    }

    private func delete(_ t: VocabTerm) {
        do { try store.remove(t.text); vocabMessage = nil } catch { vocabMessage = "Couldn't delete: \(error.localizedDescription)" }
        terms = store.terms
    }

    private func importFluidVoice() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidVoice/parakeet_custom_vocabulary.json")
        do {
            let imported = try VocabularyStore.importFluidVoice(from: url)
            for t in imported { try store.add(t) }
            vocabMessage = "Imported \(imported.count) term(s) from FluidVoice."
        } catch {
            vocabMessage = "Couldn't import FluidVoice vocabulary: \(error.localizedDescription)"
        }
        terms = store.terms
    }
}

/// A known MLX model by name, or Custom…: a Hugging Face id or a local folder, shown by its short name.
private struct MLXModelPicker: View {
    let label: String
    @Binding var id: String
    @State private var asking = false
    @State private var draft = ""

    private var isKnown: Bool { ModelSettings.knownMLXModels.contains { $0.id == id } }
    private var localURL: URL? {
        let path = (id as NSString).expandingTildeInPath
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    var body: some View {
        Picker(label, selection: Binding(get: { isKnown ? id : "custom" }, set: { v in
            if v == "custom" { draft = isKnown ? "" : id; asking = true } else { id = v }
        })) {
            ForEach(ModelSettings.knownMLXModels, id: \.id) { Text($0.name).tag($0.id) }
            Text("Custom…").tag("custom")
        }
        .help(id)
        .alert("Custom model", isPresented: $asking) {
            TextField("org/model or /path/to/folder", text: $draft)
            Button("Use") { if !draft.isEmpty { id = draft } }
            Button("Choose Folder…", action: choose)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A Hugging Face id (downloaded on first use) or a local MLX model or adapter folder.")
        }
        if !isKnown {
            LabeledContent {
                HStack {
                    Button("Choose…", action: choose)
                    Button("Reveal in Finder") { localURL.map { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
                        .disabled(localURL == nil)
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string) }
                }
            } label: {
                Text(ModelSettings.displayName(id)).lineLimit(1).truncationMode(.middle).help(id)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = localURL
        if panel.runModal() == .OK, let url = panel.url { id = url.path }
    }
}

/// Opt-in usage history (#38): toggles, what's stored, and a wipe.
private struct HistorySection: View {
    let history: HistoryStore
    @AppStorage("historyEnabled") private var enabled = false
    @AppStorage("historyAudio") private var audio = false
    @State private var stats: HistoryStore.Stats?
    @State private var confirmWipe = false

    var body: some View {
        Section {
            Toggle("Keep usage history", isOn: $enabled)
            Toggle("Also save audio", isOn: $audio).disabled(!enabled)
            LabeledContent("Stored") {
                HStack {
                    Text(stats.map { "\($0.requests) requests · \(ByteCountFormatter.string(fromByteCount: Int64($0.bytes), countStyle: .file))" } ?? "…")
                    Button("Wipe History…") { confirmWipe = true }.disabled(stats?.bytes == 0)
                }
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("Keeps transcripts, the context sent to the model, its replies, and your undos and corrections on this Mac, to train a better model. Nothing leaves the Mac.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task { await refresh() }
        .confirmationDialog("Delete all usage history and saved audio?", isPresented: $confirmWipe) {
            Button("Wipe History", role: .destructive) {
                history.wipe()
                Task { await refresh() }
            }
        }
    }

    private func refresh() async {
        let h = history
        stats = await Task.detached { h.stats() }.value
    }
}

private extension View {
    /// Fixed width, height of the content: the window (sized by preferredContentSize) follows tab and provider changes.
    func fitted() -> some View {
        scrollDisabled(true).frame(width: SettingsView.width).fixedSize(horizontal: false, vertical: true)
    }
}
