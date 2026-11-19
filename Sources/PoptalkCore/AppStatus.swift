/// A macOS privacy permission Poptalk uses, with its System Settings pane.
public enum Permission: String, CaseIterable, Sendable {
    case microphone = "Microphone", accessibility = "Accessibility"
    case inputMonitoring = "Input Monitoring", screenRecording = "Screen Recording"

    public var pane: String {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .screenRecording: "Privacy_ScreenCapture"
        }
    }
}

public enum SettingsTab: String, Sendable { case general, models, permissions, vocabulary }

/// What the menu summary and Settings show: model load states and permissions.
public struct AppStatus: Equatable, Sendable {
    public var speech: ModelStatus = .loading
    /// In-process LLM models of the current selection.
    public var models: [String: ModelStatus] = [:]
    /// Microphone, Accessibility and Screen Recording as last checked.
    public var granted: Set<Permission> = []
    /// The hotkey's event tap is up, so Input Monitoring (or Accessibility) is effectively granted.
    public var hotkeyInstalled = false

    public init() {}

    public func isGranted(_ p: Permission) -> Bool { p == .inputMonitoring ? hotkeyInstalled : granted.contains(p) }

    /// Required permissions not granted. Screen Recording is optional (screen context only). The tap works with
    /// Accessibility or Input Monitoring, so Input Monitoring is only blamed once Accessibility is granted.
    public var missing: [Permission] {
        var m: [Permission] = granted.contains(.microphone) ? [] : [.microphone]
        if !granted.contains(.accessibility) { m.append(.accessibility) } else if !hotkeyInstalled { m.append(.inputMonitoring) }
        return m
    }

    private var problem: String? {
        if !missing.isEmpty { return missing.map(\.rawValue).joined(separator: ", ") }
        if speech.isFailed { return "Speech model failed" }
        if models.values.contains(where: \.isFailed) { return "Model failed" }
        return nil
    }

    public var needsAttention: Bool { problem != nil }

    public var summary: String {
        if let problem { return "Needs attention: \(problem)" }
        let downloads = models.values.compactMap { if case .downloading(let f) = $0 { f } else { nil } }
        if let f = downloads.min() { return "Downloading model \(Int(f * 100))%" }
        if speech != .ready || models.values.contains(where: { $0 != .ready }) { return "Loading models…" }
        return "Ready"
    }

    /// Settings opens here at launch when something required is missing.
    public var launchTab: SettingsTab? { missing.isEmpty ? nil : .permissions }
}
