import Darwin
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import PoptalkCore
import Tokenizers

/// The `mlx` provider: runs MLX models in-process. A model is a Hugging Face id (downloaded to the
/// standard HF cache on first use) or a local directory, loaded once and kept resident.
public enum MLXProvider {
    // ponytail: no unload; every model asked for stays loaded until the process exits.
    private actor Models {
        var loaded: [String: Task<ModelContainer, Error>] = [:]
        func get(_ id: String) -> Task<ModelContainer, Error> {
            if let t = loaded[id] { return t }
            let t = Task {
                let local = URL(fileURLWithPath: (id as NSString).expandingTildeInPath)
                if FileManager.default.fileExists(atPath: local.appendingPathComponent("config.json").path) {
                    return try await loadModelContainer(from: local, using: #huggingFaceTokenizerLoader())
                }
                return try await loadModelContainer(from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), id: id)
            }
            loaded[id] = t
            return t
        }
    }
    private static let models = Models()

    /// Generous for edits that rewrite a selection; the caller's timeout bounds runaways.
    static let maxTokens = 1024

    /// Loads `preload` (so its time isn't charged to the first request) and returns the completion
    /// function plus metadata: load time and memory after loading.
    public static func make(preload: [String]) async throws -> (Pipeline.Complete, [String: String]) {
        let start = Date()
        for id in Set(preload) { _ = try await models.get(id).value }
        let meta = ["loadSeconds": String(format: "%.2f", Date().timeIntervalSince(start)),
                    "footprintMB": "\(footprintMB())"]
        return (complete, meta)
    }

    static let complete: Pipeline.Complete = { model, messages, _, timeout in
        let container = try await models.get(model).value
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                // Thinking off for templates that support the flag; Pipeline strips any <think> that slips through.
                let input = UserInput(messages: messages.map { ["role": $0.role, "content": $0.content] },
                                      additionalContext: ["enable_thinking": false])
                let lm = try await container.prepare(input: input)
                var out = ""
                // Leaving the loop on cancellation terminates the stream, which stops generation.
                for await g in try await container.generate(input: lm, parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0)) {
                    if case .chunk(let s) = g { out += s }
                }
                try Task.checkCancellation()
                return out
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw LLMError(description: "mlx: timed out after \(timeout)s")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Physical memory footprint of this process (what Activity Monitor shows), including MLX's Metal buffers.
    public static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint) / 1_048_576 : -1
    }
}
