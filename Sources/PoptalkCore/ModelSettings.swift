import Foundation

/// Which language-model provider and models the app uses, stored per provider in UserDefaults
/// so switching providers never hands one provider another's model ids.
public enum ModelSettings {
    public static let e2b = "mlx-community/gemma-4-e2b-it-4bit"
    /// The E2B v6 fine-tune (#103), the default for dictation and edits: a LoRA adapter applied unfused on `e2b` at
    /// load, trained on `Prompts.dictationSystem` / `editSystem`. Relative: see `adapter(_:roots:)`.
    public static let fineTune = "adapters/gemma-4-e2b-poptalk-v6"
    public static let e4b = "mlx-community/gemma-4-e4b-it-4bit"

    /// The MLX models offered by name in Settings; any other id is "Custom".
    public static let knownMLXModels: [(id: String, name: String)] = [
        (fineTune, "Gemma 4 E2B · PopTalk fine-tune"),
        (e4b, "Gemma 4 E4B"),
    ]

    /// A known model's name, else the folder or Hugging Face repo name.
    public static func displayName(_ id: String) -> String {
        knownMLXModels.first { $0.id == id }?.name ?? (id as NSString).lastPathComponent
    }

    /// Parakeet TDT speech models offered in Settings and by PoptalkBench `--speech-model` (#73), by stable id;
    /// `Transcriber.version(_:)` maps each to FluidAudio's `AsrModelVersion`.
    public static let speechModels: [(id: String, name: String, note: String)] = [
        ("v2", "Parakeet TDT v2", "English."),
        ("v3", "Parakeet TDT v3", "25 European languages."),
        ("ultra", "Parakeet Ultra", "25 European languages; more accurate than v3 at the same speed."),
        ("bark3Clean", "Bark 3.0 Clean", "English. Drops fillers, false starts and repeated words."),
        ("phonon2", "Phonon-2", "English. Faster than v3; needs macOS 15."),
    ]

    /// A saved speech model id, or the default for an unset or unknown one.
    public static func speechModel(_ saved: String?) -> String {
        speechModels.contains { $0.id == saved } ? saved! : defaults["speechModel"]!
    }

    public static let defaults: [String: String] = [
        "speechModel": "v2",
        "provider": "mlx",  // mlx | lmstudio | apple
        "baseURL": "http://localhost:1234/v1",
        "mlxCleanupModel": fineTune,
        "mlxEditModel": fineTune,
        "lmstudioCleanupModel": "google/gemma-4-e4b",
        "lmstudioEditModel": "google/gemma-4-e4b",
    ]

    /// Set once E4B saved as #101's default has moved to the fine-tune, so an E4B picked later stays.
    static let movedToFineTune = "mlxMovedToFineTuneV6"
    /// Fine-tunes bundled before v6 (until #101): they fall back to the default.
    static let oldFineTunes = ["v2", "v3", "v4"].map { "adapters/gemma-4-e2b-poptalk-\($0)" }

    /// Before per-provider fields, `cleanupModel`/`editModel` held LM Studio ids: move them to the LM Studio fields.
    /// #103: the fine-tune is the default again; old bundled fine-tunes fall back to it, and E4B (#101's default)
    /// moves to it once.
    public static func migrate(_ d: UserDefaults) {
        let once = !d.bool(forKey: movedToFineTune)
        for key in ["mlxCleanupModel", "mlxEditModel"] {
            guard let v = d.string(forKey: key), oldFineTunes.contains(v) || (once && v == e4b) else { continue }
            d.removeObject(forKey: key)
        }
        d.set(true, forKey: movedToFineTune)
        for (old, new) in [("cleanupModel", "lmstudioCleanupModel"), ("editModel", "lmstudioEditModel")] {
            guard let v = d.string(forKey: old) else { continue }
            // Unset (or the registered default): never overwrite an id saved in the new field.
            if [nil, defaults[new]].contains(d.string(forKey: new)) { d.set(v, forKey: new) }
            d.removeObject(forKey: old)
        }
    }

    /// An MLX model id names a LoRA adapter when it is a directory holding an `adapter_config.json`, as
    /// `mlx_lm.lora` writes it; that file's `model` is the base it runs on. A relative id is looked up
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
