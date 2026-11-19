import AVFoundation
import PoptalkCore
import ServiceManagement
import SwiftUI

/// UserDefaults-backed settings. The SwiftUI view binds the same keys via @AppStorage.
enum Settings {
    static func register() {
        UserDefaults.standard.register(defaults: ModelSettings.defaults)
        ModelSettings.migrate(.standard)
    }

    static var baseURL: URL { URL(string: UserDefaults.standard.string(forKey: "baseURL")!) ?? URL(string: ModelSettings.defaults["baseURL"]!)! }
    static var selection: ModelSettings.Selection { ModelSettings.selection(.standard) }
    static var inputDeviceUID: String? { UserDefaults.standard.string(forKey: "inputDeviceUID").flatMap { $0.isEmpty ? nil : $0 } }
}

struct SettingsView: View {
    @AppStorage("provider") private var provider = ModelSettings.defaults["provider"]!
    @AppStorage("baseURL") private var baseURL = ModelSettings.defaults["baseURL"]!
    @AppStorage("mlxCleanupModel") private var mlxCleanupModel = ModelSettings.defaults["mlxCleanupModel"]!
    @AppStorage("mlxEditModel") private var mlxEditModel = ModelSettings.defaults["mlxEditModel"]!
    @AppStorage("lmstudioCleanupModel") private var lmstudioCleanupModel = ModelSettings.defaults["lmstudioCleanupModel"]!
    @AppStorage("lmstudioEditModel") private var lmstudioEditModel = ModelSettings.defaults["lmstudioEditModel"]!
    @AppStorage("inputDeviceUID") private var inputDeviceUID = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let devices = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices

    /// The device's on-device model, or why it can't be used.
    private var appleModel: String {
        do { return try Providers.make("apple", baseURL: Settings.baseURL).1["variant"] ?? "Apple Intelligence" }
        catch { return (error as? LLMError)?.description ?? error.localizedDescription }
    }

    var body: some View {
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
                    TextField("Dictation cleanup model", text: $mlxCleanupModel)
                    TextField("Edit model", text: $mlxEditModel)
                    Text("A Hugging Face id (downloaded on first use) or a local model folder. Status is in the menu.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Microphone") {
                Picker("Input", selection: $inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
            Text("Hold Right ⌥ to talk. With text selected, what you say edits the selection.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
