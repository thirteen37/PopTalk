import Darwin
import Foundation
import os
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import PoptalkCore
import Tokenizers

/// The `mlx` provider: runs MLX models in-process. A model is a Hugging Face id (downloaded to the
/// standard HF cache on first use) or a local directory, loaded once and kept resident.
public enum MLXProvider {
    private actor Models {
        typealias Load = (task: Task<ModelContainer, Error>, prefixes: PrefixCache, scores: PrefixCache)
        /// Each load gets its own prefix caches (#42), so a reload starts empty and a request still running on an
        /// unloaded model only fills a cache nothing reads. `scores`: the yes/no checks' (`yesNoScore`), apart so their
        /// prompts never push a dictation's out of the recent ones its snapshots are found from.
        var loaded: [String: Load] = [:]
        /// `download` (fraction done) only reaches the first caller for `id`; later callers share its load.
        func get(_ id: String, download: (@Sendable (Double) -> Void)? = nil) -> Load {
            if let l = loaded[id] { return l }
            var progress = LoadProgressHandlers()
            if let download { progress.download = { @Sendable (p: Progress) in download(p.fractionCompleted) } }
            let t = Task {
                let container: ModelContainer
                if let (base, dir) = ModelSettings.adapter(id, roots: MLXProvider.roots) {
                    // Base + LoRA adapter as separate low-rank layers, not fused: requantizing a fused 4-bit
                    // weight (QLoRALinear.fused(), as mlx_lm.fuse) rounds most of the adapter away (#103: v6 kept
                    // 28/32 of its own training targets unfused, 3/32 fused).
                    container = try await load(base, progress)
                    let adapter = try LoRAContainer.from(directory: dir)
                    try await container.perform { try $0.model.load(adapter: adapter) }
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
            loaded[id] = (t, PrefixCache(), PrefixCache(minReuse: 64, minGain: 8))
            return loaded[id]!
        }
        /// A failed load is forgotten so the next request retries it.
        func container(_ id: String, download: (@Sendable (Double) -> Void)? = nil) async throws -> (ModelContainer, PrefixCache, scores: PrefixCache) {
            let l = get(id, download: download)
            do { return (try await l.task.value, l.prefixes, l.scores) } catch { loaded[id] = nil; throw error }
        }
        func keepOnly(_ ids: Set<String>) {
            for (id, l) in loaded where !ids.contains(id) { l.task.cancel(); loaded[id] = nil }
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
        /// it), else downloads it into PopTalk's own cache and deletes that after a verified strip.
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
    /// Where relative adapter ids live: the app bundle's Resources, else the working directory (the repo, for
    /// `swift run` and `training/bench.zsh`).
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
                    "footprintMB": "\(footprintMB())",
                    "promptCache": PrefixCache.enabled ? "on" : "off", "promptCacheMinReuse": "\(PrefixCache.minReuse)",
                    "promptCacheBudgetMB": "\(PrefixCache.budgetBytes >> 20)"]
        return (complete, meta)
    }

    static let complete: Pipeline.Complete = { model, messages, _, timeout in
        let (container, prefixes, _) = try await models.container(model)
        let name = (model as NSString).lastPathComponent
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                // Thinking off for templates that support the flag; Pipeline strips any <think> that slips through.
                let input = UserInput(messages: messages.map { ["role": $0.role, "content": $0.content] },
                                      additionalContext: ["enable_thinking": false])
                let lm = try await container.prepare(input: input)
                let tokens = lm.text.tokens.asArray(Int.self)
                let enabled = PrefixCache.enabled
                let (plan, entry, shared) = prefixes.plan(tokens, enabled: enabled, speculative: LivePreview.speculative)
                ModelCallRecorder.current?.prompt(tokens: tokens.count, shared: shared)
                timing.info("llm \(name, privacy: .public) prefix-shared \(shared)/\(tokens.count) tok")
                let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0)
                let (stream, generation) = try await container.perform(nonSendable: lm) { context, lm in
                    try MLXProvider.generate(lm, tokens, plan, entry, prefixes, parameters, context, name)
                }
                var out = "", chunks = 0
                let limit = Pipeline.replyLimit
                reply: for await g in stream {
                    switch g {
                    case .chunk(let s):
                        out += s
                        chunks += 1
                        if let limit, Pipeline.pastReplyLimit(out, limit: limit) {
                            timing.info("llm \(name, privacy: .public) stopped at reply limit \(limit) chars after \(chunks) chunks")
                            break reply
                        }
                    // Timing only (no text), for diagnosing latency: `log stream --predicate 'subsystem == "io.lyx.poptalk"'`.
                    case .info(let i):
                        timing.info("llm \(name, privacy: .public) prompt \(i.promptTokenCount) tok \(i.promptTime, format: .fixed(precision: 2))s, gen \(i.generationTokenCount) tok \(i.generateTime, format: .fixed(precision: 2))s")
                    default: break
                    }
                }
                // Left early (reply limit, or cancelled on timeout), the generation task still runs its current
                // step on the model and the KV cache. Stop it and wait, so nothing uses MLX after this returns: a
                // process exiting right after tore MLX down under it (#119), and the next request would share the GPU.
                generation.cancel()
                await generation.value
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

    /// `Pipeline.TermScore` (#75 step 2): one prefill of `Pipeline.termCheck`, log P(yes) − log P(no) at the first
    /// reply token over the first token of each spelling ("yes", " Yes", …). Never prefix-cached: the shared head is
    /// ~10 tokens, under the `scores` cache's 64 (it saved ~1 ms per pair in `training/term_probe.py --cache`).
    public static let termScore: Pipeline.TermScore = { model, heard, term in
        try await yesNoScore(model, Pipeline.termCheck(heard: heard, term: term))
    }

    /// `Pipeline.YesNoScore`: the term check's scoring for any question; the fidelity probe (#75 step 2) uses it too.
    /// Its shared head (system message and level text, ~100 tokens) comes from the load's `scores` prefix cache (#42),
    /// stored once a second check repeats it; the term check's is too short to store.
    public static let yesNoScore: Pipeline.YesNoScore = { model, messages in
        let (container, _, scores) = try await models.container(model)
        let name = (model as NSString).lastPathComponent
        let input = UserInput(messages: messages.map { ["role": $0.role, "content": $0.content] },
                              additionalContext: ["enable_thinking": false])
        let lm = try await container.prepare(input: input)
        let start = Date()
        let tokens = lm.text.tokens.asArray(Int.self)
        let (plan, entry, _) = scores.plan(tokens, enabled: PrefixCache.enabled)
        let score = try await container.perform(nonSendable: lm) { context, lm in
            func ids(_ w: String) -> [Int32] {
                Array(Set(["", " "].flatMap { p in [w, w.capitalized, w.uppercased()].compactMap {
                    context.tokenizer.encode(text: p + $0, addSpecialTokens: false).first.map(Int32.init)
                } }))
            }
            let (cache, from) = try prefilled(lm, tokens, plan, entry, scores, nil, context, name)
            let logits = context.model(lm.text[.newAxis, from...], cache: cache, state: nil).logits[0, -1].asType(.float32)
            let yes = logits[MLXArray(ids("yes"))].logSumExp(), no = logits[MLXArray(ids("no"))].logSumExp()
            return (yes - no).item(Float.self)
        }
        timing.info("yes-no score \(Int(Date().timeIntervalSince(start) * 1000)) ms, \(tokens.count) tok, \(plan.keep) reused")
        return Double(score)
    }

    /// Generation on top of a stored prompt prefix (#42): a copy of `entry`'s cache, cut back to the shared prefix,
    /// is prefilled up to `plan.snapshot` and stored again there; `generate` prefills the rest as usual. Stored
    /// caches are only ever copied, never generated into. With the cache off, `plan` is empty: a plain generation.
    /// Returns the generation task with the stream, to await once the stream is left early (#119).
    private static func generate(_ lm: LMInput, _ tokens: [Int], _ plan: PrefixPlan, _ entry: PrefixCache.Entry?, _ prefixes: PrefixCache,
                                 _ parameters: GenerateParameters, _ context: ModelContext, _ name: String) throws
        -> (AsyncStream<Generation>, Task<Void, Never>) {
        let (cache, start) = try prefilled(lm, tokens, plan, entry, prefixes, parameters, context, name)
        timing.info("llm \(name, privacy: .public) prefix-reused \(plan.keep)/\(tokens.count) tok")
        // As `MLXLMCommon.generate(input:cache:parameters:context:)`, which drops the task. Whether the prompt ends
        // inside a reasoning block is read from the whole prompt, not the part left to prefill.
        let iterator = try TokenIterator(input: LMInput(text: lm.text[start...]), model: context.model, cache: cache, parameters: parameters)
        let primed = context.configuration.reasoningConfig.map {
            ReasoningEventEmitter.promptEndsInsideReasoning(promptTokens: tokens, config: $0, tokenizer: context.tokenizer)
        } ?? false
        return generateTask(promptTokenCount: tokens.count - start, modelConfiguration: context.configuration, tokenizer: context.tokenizer,
                            iterator: iterator, toolCallPolicy: parameters.toolCallPolicy, reasoningPrimedInside: primed)
    }

    /// `plan`'s cache (#42): a copy of `entry`'s cut back to the shared prefix (else a new one), prefilled up to
    /// `plan.snapshot` and stored in `prefixes` there. Returns it with where the rest of the prompt starts.
    private static func prefilled(_ lm: LMInput, _ tokens: [Int], _ plan: PrefixPlan, _ entry: PrefixCache.Entry?, _ prefixes: PrefixCache,
                                  _ parameters: GenerateParameters?, _ context: ModelContext, _ name: String) throws -> ([KVCache], Int) {
        let cache = try entry?.cache.map { $0.copy() } ?? context.model.newCache(parameters: parameters)
        if let entry { for c in cache { c.trim(entry.tokens.count - plan.keep) } }
        var start = plan.keep
        if let end = plan.snapshot {
            let step = PrefillParameters.defaultStepSize
            for s in stride(from: start, to: end, by: step) {
                // Only the cache is evaluated, so the unused logits are never computed (as in `LLMModel.prepare`).
                _ = context.model(lm.text[.newAxis, s ..< min(s + step, end)], cache: cache, state: nil)
                eval(cache)
            }
            let copy = cache.map { $0.copy() }
            eval(copy)
            let bytes = copy.flatMap(\.state).reduce(0) { $0 + $1.nbytes }
            let total = prefixes.insert(.init(tokens: Array(tokens[..<end]), cache: copy, maxTrim: copy.map(\.maxTrimCount).min() ?? 0),
                                        bytes: bytes)
            timing.info("llm \(name, privacy: .public) prefix-cache stored \(end) tok \(bytes >> 20) MB, total \(total) MB")
            start = end
        }
        return (cache, start)
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

/// Prompt-prefix KV snapshots for one loaded model (#42): caches each holding exactly a token prefix that recent
/// prompts repeat (a kind's system prompt, unchanged screen context), so a prompt starting with it skips that much
/// prefill. One per load: unloading or reloading the model drops them.
final class PrefixCache: @unchecked Sendable {
    /// `maxTrim`: how many trailing tokens every layer can drop exactly (a sliding window that has wrapped can't).
    struct Entry: @unchecked Sendable { let tokens: [Int]; let cache: [KVCache]; let maxTrim: Int }

    /// On unless `POPTALK_PROMPT_CACHE=0` or the `mlxPromptCache` default is false, for A/B runs.
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["POPTALK_PROMPT_CACHE"] != "0"
            && (UserDefaults.standard.object(forKey: "mlxPromptCache") as? Bool ?? true)
    }
    /// Shorter prefixes are prefilled as usual. 256 keeps v3's 258-token dictation system prompt cached: at 512 its
    /// dictation saw no reuse (0.26 s median either way), at 256 it went 0.32 → 0.20 s. Revisit if that prompt
    /// shrinks below it. `POPTALK_PROMPT_CACHE_MIN` overrides it for bench sweeps.
    static let minReuse = ProcessInfo.processInfo.environment["POPTALK_PROMPT_CACHE_MIN"].flatMap(Int.init) ?? 256
    /// Per model. Holds E4B with the long GEPA prompts' dictation (~30 MB) and edit (~80 MB) system-prompt entries plus
    /// a screen-context one; v3's entries are 5–20 MB.
    static let budgetBytes = 200 << 20
    /// Prompts the next one is compared with for a snapshot point: both kinds, a few presses back.
    static let maxRecent = 8

    /// This cache's floors for `prefixPlan`: the dictation's by default.
    let minReuse: Int, minGain: Int
    init(minReuse: Int = PrefixCache.minReuse, minGain: Int = 32) { (self.minReuse, self.minGain) = (minReuse, minGain) }

    private let lock = NSLock()
    private var entries: [(item: Entry, bytes: Int)] = []  // most recently used first
    private var recent: [[Int]] = []  // prompts, newest first

    /// Plans `tokens` against the entries (marking the one it uses as most recent) and records it as the newest
    /// prompt. `shared`: tokens shared with the previous prompt, for history. Disabled: drops the entries, plans none.
    /// `speculative` (#43, a live preview's growing transcript): reuses entries only, with no snapshot and no recent
    /// prompt, so the cache ends as if it never ran. It still starts from the stored system prompt (and screen, when a
    /// press in the same window stored it). ponytail: an unstored screen is prefilled per run; store one snapshot per
    /// press at the prompt's fixed part if previews in new windows get slow.
    func plan(_ tokens: [Int], enabled: Bool, speculative: Bool = false) -> (plan: PrefixPlan, entry: Entry?, shared: Int) {
        lock.withLock {
            if !enabled { entries = [] }
            var plan = enabled ? prefixPlan(tokens, entries: entries.map { ($0.item.tokens, $0.item.maxTrim) }, recent: recent,
                                            minReuse: minReuse, minGain: minGain) : PrefixPlan(entry: nil, keep: 0)
            if speculative { plan.snapshot = nil }
            let entry = plan.entry.map { entries.remove(at: $0) }
            if let entry { entries.insert(entry, at: 0) }
            let shared = recent.first.map { sharedPrefix($0, tokens) } ?? 0
            if !speculative { recent = Array(([tokens] + recent).prefix(Self.maxRecent)) }
            return (plan, entry?.item, shared)
        }
    }

    /// Stores `entry` unless it alone exceeds the budget, evicting the least recently used to fit. Returns the total MB.
    func insert(_ entry: Entry, bytes: Int) -> Int {
        lock.withLock {
            entries = lruInsert(entry, bytes: bytes, into: entries, budget: Self.budgetBytes)
            return entries.reduce(0) { $0 + $1.bytes } >> 20
        }
    }
}
