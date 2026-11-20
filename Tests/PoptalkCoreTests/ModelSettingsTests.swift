import Foundation
import Testing
@testable import PoptalkCore

private func suite(_ saved: [String: String] = [:]) -> UserDefaults {
    let d = UserDefaults(suiteName: "poptalk-test-\(UUID())")!
    d.register(defaults: ModelSettings.defaults)
    for (k, v) in saved { d.set(v, forKey: k) }
    return d
}

@Test func freshInstallUsesMLXWithFineTune() {
    let s = ModelSettings.selection(suite())
    #expect(s.provider == "mlx")
    #expect(s.cleanupModel == ModelSettings.fineTune)
    #expect(s.editModel == ModelSettings.fineTune)
    #expect(s.mlxModels == [ModelSettings.fineTune])
}

private func tempDir(_ files: [String: String]) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    for (name, body) in files {
        let f = d.appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! body.write(to: f, atomically: true, encoding: .utf8)
    }
    return d
}

@Test func adapterIdResolvesItsBase() {
    let root = tempDir(["adapters/a/adapter_config.json": #"{"model": "org/base", "num_layers": 16}"#,
                        "models/m/config.json": "{}"])
    let rel = ModelSettings.adapter("adapters/a", roots: [URL(fileURLWithPath: "/nonexistent"), root])
    #expect(rel?.base == "org/base")
    #expect(rel?.dir.standardizedFileURL == root.appendingPathComponent("adapters/a").standardizedFileURL)
    #expect(ModelSettings.adapter(root.appendingPathComponent("adapters/a").path, roots: [])?.base == "org/base")
    // Plain HF ids and full model dirs are not adapters.
    #expect(ModelSettings.adapter("mlx-community/gemma-4-e2b-it-4bit", roots: [root]) == nil)
    #expect(ModelSettings.adapter("models/m", roots: [root]) == nil)
}

// The shipped default adapter names the base E2B it was trained on.
@Test func bundledFineTuneFusesIntoBaseE2B() {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..")
    #expect(ModelSettings.adapter(ModelSettings.fineTune, roots: [repo])?.base == ModelSettings.e2b)
}

// Saved LM Studio ids move to the LM Studio fields; MLX keeps its defaults.
@Test func migrationKeepsLMStudioIdsForLMStudioOnly() {
    let d = suite(["cleanupModel": "qwen/qwen3-4b", "editModel": "google/gemma-4-e4b"])
    ModelSettings.migrate(d)
    #expect(d.object(forKey: "cleanupModel") == nil && d.object(forKey: "editModel") == nil)
    #expect(ModelSettings.selection(d).cleanupModel == ModelSettings.fineTune)
    d.set("lmstudio", forKey: "provider")
    let s = ModelSettings.selection(d)
    #expect(s.cleanupModel == "qwen/qwen3-4b")
    #expect(s.editModel == "google/gemma-4-e4b")
}

@Test func migrationDoesNotOverwriteNewerLMStudioIds() {
    let d = suite(["cleanupModel": "old", "lmstudioCleanupModel": "new", "provider": "lmstudio"])
    ModelSettings.migrate(d)
    #expect(ModelSettings.selection(d).cleanupModel == "new")
}

@Test func appleIgnoresModelIds() {
    let s = ModelSettings.selection(suite(["provider": "apple"]))
    #expect(s.provider == "apple")
    #expect(s.mlxModels.isEmpty)
}

@Test func sharedMLXModelLoadsOnce() {
    let s = ModelSettings.selection(suite(["mlxCleanupModel": ModelSettings.e2b, "mlxEditModel": ModelSettings.e2b]))
    #expect(s.mlxModels == [ModelSettings.e2b])
    // Defaults share one model; distinct cleanup and edit models load both.
    #expect(ModelSettings.selection(suite()).mlxModels.count == 1)
    #expect(ModelSettings.selection(suite(["mlxEditModel": "mlx-community/gemma-4-e4b-it-4bit"])).mlxModels.count == 2)
    #expect(ModelSettings.selection(suite(["provider": "lmstudio"])).mlxModels.isEmpty)
}

@Test func modelNames() {
    #expect(ModelSettings.knownMLXModels.map(\.id) == [ModelSettings.fineTune, ModelSettings.e2b, ModelSettings.e4b])
    #expect(ModelSettings.displayName(ModelSettings.fineTune) == "Gemma 4 E2B · Poptalk fine-tune")
    #expect(ModelSettings.displayName(ModelSettings.e2b) == "Gemma 4 E2B")
    #expect(ModelSettings.displayName(ModelSettings.e4b) == "Gemma 4 E4B")
    // Others: the folder or Hugging Face repo name.
    #expect(ModelSettings.displayName("/Users/me/models/gemma-4-e2b-poptalk-v2/") == "gemma-4-e2b-poptalk-v2")
    #expect(ModelSettings.displayName("mlx-community/Qwen3.5-2B-MLX-4bit") == "Qwen3.5-2B-MLX-4bit")
}

@Test func modelStatusTitles() {
    #expect(ModelStatus.loading.title == "loading…")
    #expect(ModelStatus(downloaded: 0.423).title == "downloading 42%")
    #expect(ModelStatus(downloaded: 1) == .loading)  // download done, weights still loading
    #expect(ModelStatus.ready.title == "ready")
    #expect(ModelStatus.failed("offline").title == "⚠️ failed: offline")
    #expect(ModelStatus.failed("x").isFailed && !ModelStatus.loading.isFailed)
}

@Test func dictationBeforeModelIsReadyInsertsRawWithHint() async {
    let p = Pipeline(complete: { _, _, _, _ in throw Pipeline.ModelLoading() },
                     vocabulary: VocabularyStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                     cleanupModel: "a", editModel: "b")
    #expect(await p.run(Request(transcript: "hello there", selection: nil, context: ScreenSnapshot())).outcome
            == .insert("hello there", label: "Dictated (raw) · model loading"))
    #expect(await p.run(Request(transcript: "make it formal", selection: "hi", context: ScreenSnapshot())).outcome
            == .error("Model loading…"))
}
