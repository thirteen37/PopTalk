import Foundation
import Testing
@testable import PoptalkCore

@Test func textOnlyKeepsLanguageModelTensors() {
    #expect(TextOnlyModel.isText("language_model.model.layers.0.mlp.down_proj.weight"))
    #expect(TextOnlyModel.isText("language_model.model.embed_tokens_per_layer.scales"))
    for name in ["vision_tower.encoder.layers.0.x", "audio_tower.output_proj.bias", "embed_audio.embedding_projection.weight",
                 "embed_vision.embedding_projection.scales", "model.language_model.x"] {
        #expect(!TextOnlyModel.isText(name))
    }
}

@Test func safetensorsCopyKeepsOnlySelectedTensorsByteForByte() throws {
    let src = safetensorsFile([("audio_tower.a", [3], [1, 2, 3]), ("language_model.b", [2, 2], [4, 5, 6, 7]),
                               ("vision_tower.c", [1], [8]), ("language_model.d", [2], [9, 10])])
    let dst = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).safetensors")
    try Safetensors.copy(from: src, to: dst, keeping: TextOnlyModel.isText)
    let h = try Safetensors.Header(contentsOf: dst), file = try Data(contentsOf: dst)
    #expect(Set(h.tensors.keys) == ["language_model.b", "language_model.d"])
    #expect(h.metadata == ["format": "mlx"])
    #expect(h.tensors["language_model.b"]?.shape == [2, 2])
    #expect(file[h.tensors["language_model.b"]!.range] == Data([4, 5, 6, 7]))
    #expect(file[h.tensors["language_model.d"]!.range] == Data([9, 10]))
    #expect(h.dataStart % 8 == 0)
    #expect(file.count == h.dataStart + 6)
}

@Test func textOnlyConfigDropsVisionAndAudio() throws {
    let config = #"{"model_type": "gemma4", "text_config": {"hidden_size": 1536}, "vision_config": {"a": 1}, "audio_config": {"b": 2}}"#
    let out = try JSONSerialization.jsonObject(with: TextOnlyModel.config(Data(config.utf8))) as! [String: Any]
    #expect(Set(out.keys) == ["model_type", "text_config"])
    #expect((out["text_config"] as? [String: Int]) == ["hidden_size": 1536])
}

@Test func textOnlyModelBuildsADirectoryFromAFullOne() throws {
    let fm = FileManager.default
    let src = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    try fm.moveItem(at: safetensorsFile([("audio_tower.a", [1], [1]), ("language_model.b", [1], [2])]),
                    to: src.appendingPathComponent("model.safetensors"))
    for f in ["config.json", "tokenizer.json", "tokenizer_config.json", "generation_config.json"] {
        try Data(#"{"vision_config": {}, "k": 1}"#.utf8).write(to: src.appendingPathComponent(f))
    }
    try Data("{{ x }}".utf8).write(to: src.appendingPathComponent("chat_template.jinja"))
    try Data("{}".utf8).write(to: src.appendingPathComponent("processor_config.json"))
    let dst = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("m-text")
    #expect(!TextOnlyModel.isComplete(dst))
    // A leftover from an interrupted run is replaced.
    try fm.createDirectory(at: TextOnlyModel.partial(dst), withIntermediateDirectories: true)
    try Data("junk".utf8).write(to: TextOnlyModel.partial(dst).appendingPathComponent("model.safetensors"))

    try TextOnlyModel.make(from: src, to: dst)
    #expect(Set(try fm.contentsOfDirectory(atPath: dst.path)) == ["model.safetensors", "config.json", "tokenizer.json",
                                                                  "tokenizer_config.json", "generation_config.json", "chat_template.jinja"])
    #expect(try Safetensors.Header(contentsOf: dst.appendingPathComponent("model.safetensors")).tensors.keys.sorted() == ["language_model.b"])
    #expect(try String(contentsOf: dst.appendingPathComponent("config.json"), encoding: .utf8) == #"{"k":1}"#)
    #expect(try String(contentsOf: dst.appendingPathComponent("tokenizer.json"), encoding: .utf8) == #"{"vision_config": {}, "k": 1}"#)
    #expect(!fm.fileExists(atPath: TextOnlyModel.partial(dst).path))
    #expect(TextOnlyModel.isComplete(dst))
    // The source is left alone; deleting it is the caller's call.
    #expect(fm.fileExists(atPath: src.appendingPathComponent("model.safetensors").path))
}

@Test func textOnlyDirectoryIsOnlyForE2B() {
    let support = URL(fileURLWithPath: "/AS")
    #expect(TextOnlyModel.directory(for: ModelSettings.e2b, appSupport: support)?.path
            == "/AS/Poptalk/models/gemma-4-e2b-it-4bit-text")
    #expect(TextOnlyModel.directory(for: ModelSettings.e4b, appSupport: support) == nil)
    #expect(TextOnlyModel.directory(for: "/some/local/dir", appSupport: support) == nil)
    #expect(TextOnlyModel.download(appSupport: support).path == "/AS/Poptalk/models/.download")
}
