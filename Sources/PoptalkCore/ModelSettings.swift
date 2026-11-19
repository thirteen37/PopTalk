import Foundation

/// Which language-model provider and models the app uses, stored per provider in UserDefaults
/// so switching providers never hands one provider another's model ids.
public enum ModelSettings {
    public static let defaults: [String: String] = [
        "provider": "mlx",  // mlx | lmstudio | apple
        "baseURL": "http://localhost:1234/v1",
        "mlxCleanupModel": "mlx-community/gemma-4-e2b-it-4bit",
        "mlxEditModel": "mlx-community/gemma-4-e2b-it-4bit",
        "lmstudioCleanupModel": "google/gemma-4-e4b",
        "lmstudioEditModel": "google/gemma-4-e4b",
    ]

    /// Before per-provider fields, `cleanupModel`/`editModel` held LM Studio ids: move them to the LM Studio fields.
    public static func migrate(_ d: UserDefaults) {
        for (old, new) in [("cleanupModel", "lmstudioCleanupModel"), ("editModel", "lmstudioEditModel")] {
            guard let v = d.string(forKey: old) else { continue }
            // Unset (or the registered default): never overwrite an id saved in the new field.
            if [nil, defaults[new]].contains(d.string(forKey: new)) { d.set(v, forKey: new) }
            d.removeObject(forKey: old)
        }
    }

    public struct Selection: Equatable, Sendable {
        public var provider: String, cleanupModel: String, editModel: String
        /// MLX models to load and keep warm, each once.
        public var mlxModels: [String] {
            provider == "mlx" ? (cleanupModel == editModel ? [cleanupModel] : [cleanupModel, editModel]) : []
        }
    }

    public static func selection(_ d: UserDefaults) -> Selection {
        let p = d.string(forKey: "provider") ?? "mlx"
        guard p != "apple" else { return Selection(provider: p, cleanupModel: "apple", editModel: "apple") }
        let prefix = p == "lmstudio" ? "lmstudio" : "mlx"
        return Selection(provider: prefix, cleanupModel: d.string(forKey: prefix + "CleanupModel") ?? "",
                         editModel: d.string(forKey: prefix + "EditModel") ?? "")
    }
}

/// Load state of an in-process model, shown in the menu.
public enum ModelStatus: Equatable, Sendable {
    case loading, downloading(Double), ready, failed(String)

    /// From a download progress fraction: once complete, the weights are still loading.
    public init(downloaded f: Double) { self = f < 1 ? .downloading(f) : .loading }

    public var isFailed: Bool { if case .failed = self { true } else { false } }

    public var title: String {
        switch self {
        case .loading: "loading…"
        case .downloading(let f): "downloading \(Int(f * 100))%"
        case .ready: "ready"
        case .failed(let msg): "⚠️ failed: \(msg)"
        }
    }
}
