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
    static var speechModel: String { ModelSettings.speechModel(UserDefaults.standard.string(forKey: "speechModel")) }
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
        case .apps: "square.grid.2x2"
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
    let learned: LearnedTerms
    let history: HistoryStore
    /// Retries whatever failed to load (speech model and/or LLM models).
    let retry: () -> Void

    @AppStorage("speechModel") private var speechModel = ModelSettings.defaults["speechModel"]!
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
    @AppStorage(ContextSources.Key.rememberScreenTerms) private var rememberScreenTerms = false
    @State private var confirmForget = false
    @State private var learnedTerms: [LearnedTerm] = []
    @AppStorage(DictationFeatures.Key.recaseTerms) private var recaseTerms = true
    @AppStorage(DictationFeatures.Key.skipGate) private var skipGate = false
    @AppStorage(DictationFeatures.Key.soundAlikeTerms) private var soundAlikeTerms = false
    @AppStorage(LivePreview.key) private var liveCleanup = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var terms: [VocabTerm] = []
    @State private var vocabMessage: String?
    @State private var editing: TermDraft?

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
            case .apps: AppProfilesView()
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
                let l = learned.terms()
                if l != learnedTerms { learnedTerms = l }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var general: some View {
        Form {
            Section {
                Text("Hold Right ⌥ to talk. With text selected, what you say edits the selection. Tap, then hold, to edit what PopTalk just inserted.")
            }
            Section("Microphone") {
                Picker("Input", selection: $inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
            }
            Section {
                Stepper("Undo window: \(undoWindow) s", value: $undoWindow, in: OutcomeKeys.undoWindowRange)
                    .help("How long the result stays up, with a right-⌥ double tap to undo and Return to add a suggested word.")
                Toggle("Live cleanup preview", isOn: $liveCleanup)
                Text("Shows the cleanup or edit while you talk, so release can insert it at once. Uses the GPU at each pause.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Reset Overlay Position") { UserDefaults.standard.removeObject(forKey: OverlayPlacement.anchorsKey) }
                    .help("Drag the overlay to move it on a display; right-click it to reset that display. This resets all.")
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
                // Off offers to forget what was learned.
                Toggle("Remember screen terms that fix dictations", isOn: Binding(get: { rememberScreenTerms }, set: { on in
                    rememberScreenTerms = on
                    if !on, !learned.terms().isEmpty { confirmForget = true }
                })).disabled(!ctxScreenVocabulary)
                Text("A term on screen that corrected a dictation boosts later ones too. Stored on this Mac only; see Vocabulary.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Context sources")
            } footer: {
                Text("What PopTalk reads on each press to understand what you're writing. Selected text is always used (edits need it), saved vocabulary always boosts recognition, and password fields are never read. Screen text needs Screen Recording. Apps turns sources off for one app or website.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HistorySection(history: history)
        }
        .formStyle(.grouped)
        .fitted()
        .confirmationDialog("Forget the terms learned from screen?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Learned Terms", role: .destructive) { learned.forgetAll(); learnedTerms = [] }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("They're no longer used while this is off. Kept, they're used again if you turn it back on.")
        }
    }

    private var models: some View {
        Form {
            Section {
                // An unknown saved id shows as the default it falls back to.
                Picker("Model", selection: Binding(get: { ModelSettings.speechModel(speechModel) }, set: { speechModel = $0 })) {
                    ForEach(ModelSettings.speechModels, id: \.id) { Text($0.name).tag($0.id) }
                }
            } header: {
                Text("Speech model")
            } footer: {
                Text((ModelSettings.speechModels.first { $0.id == ModelSettings.speechModel(speechModel) }?.note ?? "")
                     + " Downloads on first use; a change applies after the current dictation.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
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
                    // #101: E4B needs about 3 GB (the default fine-tune about 1.6); Apple's model runs in the system.
                    if ProcessInfo.processInfo.physicalMemory <= 8 << 30, [mlxCleanupModel, mlxEditModel].contains(ModelSettings.e4b) {
                        Text("Gemma 4 E4B uses about 3 GB of memory. On this Mac, Apple on-device may be the better choice.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                // Only E2B fine-tunes (the default, #103, and local adapter folders) use it.
                if provider == "mlx" && Pipeline.recasesTerms(mlxCleanupModel) {
                    Toggle("Fix screen-term casing before cleanup", isOn: $recaseTerms)
                    Text("For the PopTalk fine-tuned models: \"meal prep\" becomes \"Meal Prep\" when the screen shows it.")
                        .font(.footnote).foregroundStyle(.secondary)
                    // #75: runs only where the casing fix does.
                    if recaseTerms {
                        Toggle("Match sound-alike terms (experimental)", isOn: $soundAlikeTerms)
                        Text("Asks the model whether words that sound like a screen or vocabulary term (\"core vanta\") are that term, and gives them its spelling.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Toggle("Skip cleanup for clean dictations (experimental)", isOn: $skipGate)
                Text("Inserts a punctuated dictation with no fillers or corrections as heard, without the language model.")
                    .font(.footnote).foregroundStyle(.secondary)
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
                        Button { editing = TermDraft(t) } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                            .help("Edit")
                        Button { delete(t) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            .help("Delete")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = TermDraft(t) }
                }
            }
            .overlay { if terms.isEmpty { Text("No saved terms").foregroundStyle(.secondary) } }
            HStack {
                Button("Add Term…") { editing = TermDraft() }
                Button("Import FluidVoice Vocabulary", action: importFluidVoice)
                if let vocabMessage { Text(vocabMessage).font(.footnote).foregroundStyle(.secondary) }
            }
            if !learnedTerms.isEmpty { learnedSection }
        }
        .padding()
        .frame(width: SettingsView.width, height: learnedTerms.isEmpty ? 400 : 560)
        .sheet(item: $editing) { TermSheet(draft: $0, save: save) }
    }

    /// #87: screen terms remembered with "Remember screen terms that fix dictations", newest first.
    private var learnedSection: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Learned from screen").font(.headline)
                Spacer()
                Button("Forget All") { learned.forgetAll(); learnedTerms = [] }
            }
            .padding(.top, 8)
            List(learnedTerms, id: \.text) { t in
                HStack {
                    VStack(alignment: .leading) {
                        Text(t.text)
                        Text("Fixed \(t.count)× · last \(t.lastUsed.formatted(.relative(presentation: .named)))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { promote(t) } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
                        .help("Move to Vocabulary")
                    Button { learned.forget(t.text); learnedTerms = learned.terms() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete")
                }
            }
            .frame(height: 140)
            if !rememberScreenTerms {
                Text("Not used: \"Remember screen terms that fix dictations\" is off in Context.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func promote(_ t: LearnedTerm) {
        save(TermDraft(text: t.text))
        if store.terms.contains(where: { $0.text.lowercased() == t.text.lowercased() }) { learned.forget(t.text) }
        learnedTerms = learned.terms()
    }

    private func save(_ d: TermDraft) {
        let term = VocabTerm(text: d.text, aliases: d.aliases.split(separator: ",").map(String.init))
        do {
            if let old = d.old { try store.update(old, to: term) } else { try store.add(term) }
            vocabMessage = nil
        } catch {
            vocabMessage = "Couldn't save: \(error.localizedDescription)"
        }
        terms = store.terms
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
            for t in imported where !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try store.add(t) }
            vocabMessage = "Imported \(imported.count) term(s) from FluidVoice."
        } catch {
            vocabMessage = "Couldn't import FluidVoice vocabulary: \(error.localizedDescription)"
        }
        terms = store.terms
    }
}

/// A vocabulary term being added (`old` nil) or edited; aliases comma-separated.
private struct TermDraft: Identifiable {
    let id = UUID()
    var old: String?
    var text = ""
    var aliases = ""

    init(text: String = "") { self.text = text }
    init(_ t: VocabTerm) { old = t.text; text = t.text; aliases = t.aliases.joined(separator: ", ") }
}

private struct TermSheet: View {
    @State var draft: TermDraft
    let save: (TermDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .trailing) {
            Form {
                TextField("Term", text: $draft.text, prompt: Text("Todoist"))
                TextField("Heard as", text: $draft.aliases, prompt: Text("todo list, to do list"))
                Text("Optional, comma-separated: how speech recognition mishears the term. Recognition listens for these and writes the term. Spoken forms like “fluid audio” for FluidAudio are added automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.old == nil ? "Add" : "Save") { save(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Per-app profiles (#96): the context sources an app or website turns off, on top of Context. On this Mac only.
private struct AppProfilesView: View {
    @AppStorage(AppProfiles.key) private var data = Data()
    @State private var editing: AppProfile?

    private var profiles: [AppProfile] { (try? JSONDecoder().decode([AppProfile].self, from: data)) ?? [] }

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(profiles) { p in
                    HStack {
                        Image(nsImage: appIcon(p.bundleID))
                        VStack(alignment: .leading) {
                            Text([p.bundleID.isEmpty ? "Any app" : appName(p.bundleID), p.domain].filter { !$0.isEmpty }
                                .joined(separator: " · "))
                            Text(summary(p)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { editing = p } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Edit")
                        Button { save(profiles.filter { $0.id != p.id }) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = p }
                }
            }
            .overlay { if profiles.isEmpty { Text("No app profiles").foregroundStyle(.secondary) } }
            HStack {
                Button("Add…") { editing = AppProfile() }
                Text("Or use \"Don't Read the Screen in…\" in the menu bar.").font(.footnote).foregroundStyle(.secondary)
            }
            Text("A profile turns context sources off in one app, on one website, or both; the most specific one applies. Sources off in Context stay off everywhere. Password fields, password managers and private windows are never read.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: SettingsView.width, height: 400)
        .sheet(item: $editing) { p in
            ProfileSheet(draft: p, others: profiles) { new in
                save(profiles.contains { $0.id == new.id } ? profiles.map { $0.id == new.id ? new : $0 } : profiles + [new])
            }
        }
    }

    private func save(_ p: [AppProfile]) { AppProfiles.save(p, to: .standard) }

    private func summary(_ p: AppProfile) -> String {
        if ContextSource.screen.isSubset(of: p.off) { return "Screen not read" }
        let off = ContextSource.allCases.filter(p.off.contains).map(\.label)
        return off.isEmpty ? "Nothing off" : "Off: " + off.joined(separator: ", ")
    }
}

/// An app profile being added or edited (#96): match rule, then one checkbox per source.
private struct ProfileSheet: View {
    @State var draft: AppProfile
    let others: [AppProfile]
    let save: (AppProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    private let global = ContextSources(.standard)

    /// Running apps with a Dock icon, and the draft's app.
    private var apps: [String] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier).filter { $0 != Bundle.main.bundleIdentifier }
        return Set(running + [draft.bundleID]).filter { !$0.isEmpty }.sorted { appName($0).localizedCompare(appName($1)) == .orderedAscending }
    }

    private var valid: Bool {
        !(draft.bundleID.isEmpty && AppProfile.host(draft.domain).isEmpty) && !AppProfiles.conflicts(draft, in: others)
    }

    var body: some View {
        VStack(alignment: .trailing) {
            Form {
                Section {
                    LabeledContent("App") {
                        HStack {
                            Picker("App", selection: $draft.bundleID) {
                                Text("Any app").tag("")
                                ForEach(apps, id: \.self) { Text(appName($0)).tag($0) }
                            }
                            .labelsHidden()
                            Button("Choose…", action: choose)
                        }
                    }
                    TextField("Website", text: $draft.domain, prompt: Text("example.com (optional)"))
                    Text("A website also matches its subdomains, in any browser unless an app is set. Not used in private windows.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if AppProfiles.conflicts(draft, in: others) {
                        Text("Another profile already matches this app and website.").font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section {
                    Toggle("Don't read the screen", isOn: Binding(
                        get: { ContextSource.screen.isSubset(of: draft.off) },
                        set: { on in if on { draft.off.formUnion(ContextSource.screen) } else { draft.off.subtract(ContextSource.screen) } }))
                    ForEach(ContextSource.allCases, id: \.self) { s in
                        Toggle(s.label, isOn: Binding(get: { global[s] && !draft.off.contains(s) }, set: { on in
                            if on { draft.off.remove(s) } else { draft.off.insert(s) }
                        }))
                        .toggleStyle(.checkbox)
                        .disabled(!global[s])
                        .help(global[s] ? "" : "Off in Context")
                    }
                } header: {
                    Text("Read here")
                } footer: {
                    Text("Greyed out: off in Context for every app. Selected text and saved vocabulary are still used.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(others.contains { $0.id == draft.id } ? "Save" : "Add") {
                    draft.domain = AppProfile.host(draft.domain)
                    save(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let id = panel.url.flatMap({ Bundle(url: $0)?.bundleIdentifier }) { draft.bundleID = id }
    }
}

private extension ContextSource {
    var label: String {
        switch self {
        case .focusedText: "Focused field text"
        case .nearbyText: "Nearby text"
        case .ocr: "Screen text (OCR)"
        case .windowTitle: "Window title"
        case .webDomain: "Web domain"
        case .screenVocabulary: "Boost recognition with words on screen"
        case .rememberScreenTerms: "Use remembered screen terms"
        case .learnScreenTerms: "Remember screen terms from here"
        }
    }
}

/// The app's name from its bundle ID, or the ID when it isn't installed.
private func appName(_ bundleID: String) -> String {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent ?? bundleID
}

/// The app's icon, or a globe for a website-only profile.
private func appIcon(_ bundleID: String) -> NSImage {
    let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        ?? NSImage(systemSymbolName: bundleID.isEmpty ? "globe" : "app.dashed", accessibilityDescription: nil)!
    image.size = NSSize(width: 20, height: 20)
    return image
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

/// Opt-in usage history (#38): toggles, what's stored, iCloud sync (#76), and a wipe.
private struct HistorySection: View {
    let history: HistoryStore
    @AppStorage("historyEnabled") private var enabled = false
    @AppStorage("historyAudio") private var audio = false
    @AppStorage("historySync") private var sync = false
    @State private var stats: HistoryStore.Stats?
    @State private var confirmWipe = false
    @State private var confirmSync = false
    @State private var confirmUnsync = false

    var body: some View {
        Section {
            Toggle("Keep usage history", isOn: $enabled)
            Toggle("Also save audio", isOn: $audio).disabled(!enabled)
            // On asks first (and whether to copy what's here); off offers to delete this Mac's synced copy.
            Toggle("Sync history via iCloud", isOn: Binding(get: { sync }, set: { on in
                if on { confirmSync = true } else { sync = false; confirmUnsync = true }
            })).disabled(!enabled)
            if sync && enabled {
                LabeledContent("Synced", value: stats.map(syncStatus) ?? "…")
            }
            LabeledContent("Stored") {
                HStack {
                    Text(stats.map { "\($0.requests) requests · \(ByteCountFormatter.string(fromByteCount: Int64($0.bytes), countStyle: .file))" } ?? "…")
                    Button("Wipe History…") { confirmWipe = true }.disabled(stats?.requests == 0 && stats?.bytes == 0)
                }
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("Keeps transcripts, the context sent to the model, its replies, and your undos and corrections on this Mac, to train a better model. Nothing leaves the Mac unless you sync it.\n\nSync copies the history, but not audio, to PopTalk/history in your iCloud Drive and merges in your other Macs' history. With standard iCloud data protection it's encrypted, but Apple holds the keys. With Advanced Data Protection it's end-to-end encrypted.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .task { await refresh() }
        .confirmationDialog("Sync history via iCloud?", isPresented: $confirmSync, titleVisibility: .visible) {
            Button("Copy Existing History") { startSync(copy: true) }
            Button("Sync New History Only") { startSync(copy: false) }
        } message: {
            Text("From now on this Mac also writes its history to iCloud Drive. Copy the history already on this Mac there too?")
        }
        .confirmationDialog("Delete this Mac's synced history from iCloud Drive?", isPresented: $confirmUnsync, titleVisibility: .visible) {
            Button("Delete from iCloud", role: .destructive) {
                history.deleteSyncedCopy()
                Task { await refresh() }
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Syncing has stopped. The history on this Mac and your other Macs' synced history stay.")
        }
        .confirmationDialog("Delete all usage history and saved audio?", isPresented: $confirmWipe, titleVisibility: .visible) {
            if sync && enabled {
                Button("This Mac", role: .destructive) { wipe(allMacs: false) }
                Button("All Macs", role: .destructive) { wipe(allMacs: true) }
            } else {
                Button("Wipe History", role: .destructive) { wipe(allMacs: false) }
            }
        } message: {
            if sync && enabled {
                Text("This Mac deletes its history and its synced copy. All Macs also deletes the synced folder in iCloud Drive, and your other Macs delete their history the next time they check.")
            }
        }
    }

    private func syncStatus(_ s: HistoryStore.Stats) -> String {
        let macs = s.devices == 1 ? "1 Mac" : "\(s.devices) Macs"
        return "\(macs) · " + (s.lastSync.map { "last write \($0.formatted(.relative(presentation: .named)))" } ?? "nothing written yet")
    }

    private func startSync(copy: Bool) {
        sync = true
        history.startSync(copyExisting: copy)
        Task { await refresh() }
    }

    private func wipe(allMacs: Bool) {
        history.wipe(allMacs: allMacs)
        Task { await refresh() }
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
