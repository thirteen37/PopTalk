import AVFoundation
import ServiceManagement
import SwiftUI

/// UserDefaults-backed settings. The SwiftUI view binds the same keys via @AppStorage.
enum Settings {
    nonisolated(unsafe) static let defaults: [String: Any] = [
        "baseURL": "http://localhost:1234/v1",
        "cleanupModel": "google/gemma-4-e4b",
        "editModel": "google/gemma-4-e4b",
    ]
    static func register() { UserDefaults.standard.register(defaults: defaults) }

    static var baseURL: URL { URL(string: UserDefaults.standard.string(forKey: "baseURL")!) ?? URL(string: defaults["baseURL"] as! String)! }
    static var cleanupModel: String { UserDefaults.standard.string(forKey: "cleanupModel")! }
    static var editModel: String { UserDefaults.standard.string(forKey: "editModel")! }
    static var inputDeviceUID: String? { UserDefaults.standard.string(forKey: "inputDeviceUID").flatMap { $0.isEmpty ? nil : $0 } }
}

struct SettingsView: View {
    @AppStorage("baseURL") private var baseURL = Settings.defaults["baseURL"] as! String
    @AppStorage("cleanupModel") private var cleanupModel = Settings.defaults["cleanupModel"] as! String
    @AppStorage("editModel") private var editModel = Settings.defaults["editModel"] as! String
    @AppStorage("inputDeviceUID") private var inputDeviceUID = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let devices = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices

    var body: some View {
        Form {
            Section("Language model (OpenAI-compatible server)") {
                TextField("Server URL", text: $baseURL)
                TextField("Dictation cleanup model", text: $cleanupModel)
                TextField("Edit model", text: $editModel)
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
