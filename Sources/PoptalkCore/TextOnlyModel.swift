import Foundation

/// A text-only copy of E2B (#51): the upstream repo also ships vision and audio towers (~0.9 GB) that
/// PopTalk never loads. The copy keeps the `language_model.*` tensors, config, tokenizer and chat template.
public enum TextOnlyModel {
    public static func isText(_ tensor: String) -> Bool { tensor.hasPrefix("language_model.") }

    static let files = ["config.json", "generation_config.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"]

    /// Where the text-only copy of `id` lives, for the ids that get one.
    public static func directory(for id: String, appSupport: URL) -> URL? {
        id == ModelSettings.e2b ? models(appSupport).appendingPathComponent("gemma-4-e2b-it-4bit-text") : nil
    }
    /// PopTalk's own Hugging Face cache for full downloads, deleted once stripped.
    public static func download(appSupport: URL) -> URL { models(appSupport).appendingPathComponent(".download") }
    static func models(_ appSupport: URL) -> URL { appSupport.appendingPathComponent("Poptalk/models") }

    /// The copy is built here, then renamed into place, so `isComplete` never sees a half-written one.
    public static func partial(_ dir: URL) -> URL { dir.appendingPathExtension("partial") }
    public static func isComplete(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
    }

    /// `config.json` without the vision and audio sections (the text loader reads only `text_config`).
    public static func config(_ data: Data) throws -> Data {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "TextOnlyModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "config.json is not an object"])
        }
        obj["vision_config"] = nil
        obj["audio_config"] = nil
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Builds `dst` from the full model directory `src` (left untouched; it may be the shared HF cache).
    public static func make(from src: URL, to dst: URL) throws {
        let fm = FileManager.default, tmp = partial(dst)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        // HF snapshot files are symlinks into the cache's blobs: copy what they point at.
        func source(_ name: String) -> URL { src.appendingPathComponent(name).resolvingSymlinksInPath() }
        try Safetensors.copy(from: source("model.safetensors"), to: tmp.appendingPathComponent("model.safetensors"), keeping: isText)
        for f in files where fm.fileExists(atPath: source(f).path) {
            if f == "config.json" {
                try config(Data(contentsOf: source(f))).write(to: tmp.appendingPathComponent(f))
            } else {
                try fm.copyItem(at: source(f), to: tmp.appendingPathComponent(f))
            }
        }
        try? fm.removeItem(at: dst)  // never complete here: callers check `isComplete` first
        try fm.moveItem(at: tmp, to: dst)
    }
}
