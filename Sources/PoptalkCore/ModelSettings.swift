import Foundation

/// Which language-model provider and models the app uses, stored per provider in UserDefaults
/// so switching providers never hands one provider another's model ids.
public enum ModelSettings {
    public static let e2b = "mlx-community/gemma-4-e2b-it-4bit"
    /// The E2B fine-tune (#21) as a LoRA adapter, fused into `e2b` at load (#36). Relative: see `adapter(_:roots:)`.
    public static let fineTune = "adapters/gemma-4-e2b-poptalk-v2"
    public static let e4b = "mlx-community/gemma-4-e4b-it-4bit"

    /// The MLX models offered by name in Settings; any other id is "Custom".
    public static let knownMLXModels: [(id: String, name: String)] = [
        (fineTune, "Gemma 4 E2B · Poptalk fine-tune"),
        (e2b, "Gemma 4 E2B"),
        (e4b, "Gemma 4 E4B"),
    ]

    /// A known model's name, else the folder or Hugging Face repo name.
    public static func displayName(_ id: String) -> String {
        knownMLXModels.first { $0.id == id }?.name ?? (id as NSString).lastPathComponent
    }

    public static let defaults: [String: String] = [
        "provider": "mlx",  // mlx | lmstudio | apple
        "baseURL": "http://localhost:1234/v1",
        "mlxCleanupModel": fineTune,
        "mlxEditModel": fineTune,
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

    /// An MLX model id names a LoRA adapter when it is a directory holding an `adapter_config.json`, as
    /// `mlx_lm.lora` writes it; that file's `model` is the base to fuse it into. A relative id is looked up
    /// in each of `roots` in turn (the app's Resources, then the working directory).
    public static func adapter(_ id: String, roots: [URL]) -> (base: String, dir: URL)? {
        struct Config: Decodable { let model: String }
        let path = (id as NSString).expandingTildeInPath
        let dirs = path.hasPrefix("/") ? [URL(fileURLWithPath: path)] : roots.map { $0.appendingPathComponent(path) }
        for dir in dirs {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("adapter_config.json")),
                  let config = try? JSONDecoder().decode(Config.self, from: data) else { continue }
            return (config.model, dir)
        }
        return nil
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
