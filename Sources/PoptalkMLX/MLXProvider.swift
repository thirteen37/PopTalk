import Darwin
import Foundation
import os
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import PoptalkCore
import Tokenizers

/// The `mlx` provider: runs MLX models in-process. A model is a Hugging Face id (downloaded to the
/// standard HF cache on first use) or a local directory, loaded once and kept resident.
public enum MLXProvider {
    private actor Models {
        var loaded: [String: Task<ModelContainer, Error>] = [:]
        /// `download` (fraction done) only reaches the first caller for `id`; later callers share its load.
        func get(_ id: String, download: (@Sendable (Double) -> Void)? = nil) -> Task<ModelContainer, Error> {
            if let t = loaded[id] { return t }
            var progress = LoadProgressHandlers()
            if let download { progress.download = { @Sendable (p: Progress) in download(p.fractionCompleted) } }
            let t = Task {
                let container: ModelContainer
                if let (base, dir) = ModelSettings.adapter(id, roots: MLXProvider.roots) {
                    // Base + LoRA adapter, fused in memory (QLoRALinear.fused(): dequantize, add, requantize, as
                    // mlx_lm.fuse). Lazy: the fused weights are computed on first use, i.e. by `prepare`'s warm-up.
                    container = try await load(base, progress)
                    let adapter = try LoRAContainer.from(directory: dir)
                    try await container.perform { try $0.model.fuse(with: adapter) }
                } else {
                    container = try await load(id, progress)
                }
                if MappedPLE.enabled {
                    let dir = try await container.modelDirectory
                    let mapped = try await container.perform { try MappedPLE.install(in: $0.model, directory: dir) }
                    timing.info("llm \((id as NSString).lastPathComponent, privacy: .public) PLE mapped from disk: \(mapped)")
                }
                return container
            }
            loaded[id] = t
            return t
        }
        /// A failed load is forgotten so the next request retries it.
        func container(_ id: String, download: (@Sendable (Double) -> Void)? = nil) async throws -> ModelContainer {
            do { return try await get(id, download: download).value } catch { loaded[id] = nil; throw error }
        }
        func keepOnly(_ ids: Set<String>) {
            for (id, t) in loaded where !ids.contains(id) { t.cancel(); loaded[id] = nil; lastTokens[id] = nil }
        }
        /// The previous request's prompt tokens per model, to measure what a KV cache could reuse (#42).
        var lastTokens: [String: [Int]] = [:]
        /// Stores `tokens` as `id`'s latest prompt; returns the leading tokens shared with the previous one.
        func shared(_ id: String, _ tokens: [Int]) -> Int {
            defer { lastTokens[id] = tokens }
            return sharedPrefix(lastTokens[id] ?? [], tokens)
        }
    }
    /// A local model directory or a Hugging Face id.
    private static func load(_ id: String, _ progress: LoadProgressHandlers) async throws -> ModelContainer {
        let local = URL(fileURLWithPath: (id as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: local.appendingPathComponent("config.json").path) {
            return try await loadModelContainer(from: local, using: #huggingFaceTokenizerLoader(), progress: progress)
        }
        if let dir = TextOnlyModel.directory(for: id, appSupport: appSupport) {
            try await textOnly.make(id, dir, progress.download)
            // The registry's settings for `id` (e.g. Gemma's extra `<turn|>` EOS), with the weights from `dir`.
            var config = LLMModelFactory.shared.configuration(id: id)
            config.id = .directory(dir)
            return try await loadModelContainer(from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), configuration: config, progress: progress)
        }
        return try await loadModelContainer(from: #hubDownloader(), using: #huggingFaceTokenizerLoader(), id: id, progress: progress)
    }

    static let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    private static let textOnly = TextOnly()
    /// Builds the text-only copy of a model on first use (#51), once per process however many loads ask.
    // ponytail: no cross-process lock; the app and PoptalkBench both stripping on their first run could clash.
    private actor TextOnly {
        var running: [URL: Task<Void, Error>] = [:]
        func make(_ id: String, _ dir: URL, _ download: (@Sendable (Progress) -> Void)?) async throws {
            if TextOnlyModel.isComplete(dir) { return }
            let t = running[dir] ?? Task { try await build(id, dir, download) }
            running[dir] = t
            defer { running[dir] = nil }
            try await t.value
        }
        /// Strips the full model from the shared HF cache when it's already there (read only: other tools may use
        /// it), else downloads it into Poptalk's own cache and deletes that after a verified strip.
        private nonisolated func build(_ id: String, _ dir: URL, _ download: (@Sendable (Progress) -> Void)?) async throws {
            guard let repo = Repo.ID(rawValue: id) else { throw LLMError(description: "mlx: bad model id \(id)") }
            let patterns = ["*.safetensors", "*.json", "*.jinja"]
            let start = Date()
            if let shared = try? await HubClient.default.downloadSnapshot(of: repo, matching: patterns, localFilesOnly: true),
               FileManager.default.fileExists(atPath: shared.appendingPathComponent("model.safetensors").path) {
                try TextOnlyModel.make(from: shared, to: dir)
                timing.info("text-only \(dir.lastPathComponent, privacy: .public) from shared HF cache in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s")
                return
            }
            let staging = TextOnlyModel.download(appSupport: appSupport)
            let full = try await HubClient(cache: HubCache(cacheDirectory: staging)).downloadSnapshot(
                of: repo, matching: patterns, progressHandler: { p in download?(p) })
            try TextOnlyModel.make(from: full, to: dir)
            try? FileManager.default.removeItem(at: staging)
            timing.info("text-only \(dir.lastPathComponent, privacy: .public) downloaded and stripped in \(Date().timeIntervalSince(start), format: .fixed(precision: 1))s")
        }
    }
    /// Where relative adapter ids live: the app bundle's Resources (`scripts/install.zsh` copies `adapters/`
    /// there), else the working directory (the repo, for `swift run`).
    static let roots = [Bundle.main.resourceURL, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)].compactMap { $0 }
    private static let models = Models()
    static let timing = Logger(subsystem: "io.lyx.poptalk", category: "timing")

    /// Loads `id` (downloading it into the HF cache on first use, reporting the download fraction) and runs
    /// a dictation and an edit at full context length, so the first real request pays neither the ~3 s Metal
    /// warm-up nor the first long (>512-token, chunked) prefill, which a short warm-up prompt never reaches (#33).
    public static func prepare(_ id: String, download: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await models.container(id, download: download)
        for messages in Prompts.warmup { _ = try await complete(id, messages, false, 60) }
    }

    /// Unloads every model not in `ids`; memory returns once in-flight requests release theirs.
    public static func keepOnly(_ ids: [String]) async { await models.keepOnly(Set(ids)) }

    /// Generous for edits that rewrite a selection; the caller's timeout bounds runaways.
    static let maxTokens = 1024

    /// Loads and prewarms `preload`, like the app, so neither is charged to the first request. Returns
    /// the completion function plus metadata: load + warm-up time and memory after loading.
    public static func make(preload: [String]) async throws -> (Pipeline.Complete, [String: String]) {
        let start = Date()
        for id in Set(preload) { try await prepare(id) { _ in } }
        let meta = ["loadSeconds": String(format: "%.2f", Date().timeIntervalSince(start)),
                    "footprintMB": "\(footprintMB())"]
        return (complete, meta)
    }

    static let complete: Pipeline.Complete = { model, messages, _, timeout in
        let container = try await models.container(model)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                // Thinking off for templates that support the flag; Pipeline strips any <think> that slips through.
                let input = UserInput(messages: messages.map { ["role": $0.role, "content": $0.content] },
                                      additionalContext: ["enable_thinking": false])
                let lm = try await container.prepare(input: input)
                let tokens = lm.text.tokens.asArray(Int.self)
                let shared = await models.shared(model, tokens)
                ModelCallRecorder.current?.prompt(tokens: tokens.count, shared: shared)
                timing.info("llm \((model as NSString).lastPathComponent, privacy: .public) prefix-shared \(shared)/\(tokens.count) tok")
                var out = ""
                // Leaving the loop on cancellation terminates the stream, which stops generation.
                for await g in try await container.generate(input: lm, parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0)) {
                    switch g {
                    case .chunk(let s): out += s
                    // Timing only (no text), for diagnosing latency: `log stream --predicate 'subsystem == "io.lyx.poptalk"'`.
                    case .info(let i):
                        timing.info("llm \((model as NSString).lastPathComponent, privacy: .public) prompt \(i.promptTokenCount) tok \(i.promptTime, format: .fixed(precision: 2))s, gen \(i.generationTokenCount) tok \(i.generateTime, format: .fixed(precision: 2))s")
                    default: break
                    }
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
