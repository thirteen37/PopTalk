import Foundation
import Testing
@testable import PoptalkCore

private func suite(_ saved: [String: String] = [:]) -> UserDefaults {
    let d = UserDefaults(suiteName: "poptalk-test-\(UUID())")!
    d.register(defaults: ModelSettings.defaults)
    for (k, v) in saved { d.set(v, forKey: k) }
    return d
}

@Test func freshInstallUsesMLXWithBenchmarkedModels() {
    let s = ModelSettings.selection(suite())
    #expect(s.provider == "mlx")
    #expect(s.cleanupModel == "mlx-community/gemma-4-e2b-it-4bit")
    #expect(s.editModel == "mlx-community/gemma-4-e2b-it-4bit")
}

// Saved LM Studio ids move to the LM Studio fields; MLX keeps its defaults.
@Test func migrationKeepsLMStudioIdsForLMStudioOnly() {
    let d = suite(["cleanupModel": "qwen/qwen3-4b", "editModel": "google/gemma-4-e4b"])
    ModelSettings.migrate(d)
    #expect(d.object(forKey: "cleanupModel") == nil && d.object(forKey: "editModel") == nil)
    #expect(ModelSettings.selection(d).cleanupModel == "mlx-community/gemma-4-e2b-it-4bit")
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
    let s = ModelSettings.selection(suite(["mlxEditModel": "mlx-community/gemma-4-e2b-it-4bit"]))
    #expect(s.mlxModels == ["mlx-community/gemma-4-e2b-it-4bit"])
    #expect(ModelSettings.selection(suite()).mlxModels.count == 2)
    #expect(ModelSettings.selection(suite(["provider": "lmstudio"])).mlxModels.isEmpty)
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
