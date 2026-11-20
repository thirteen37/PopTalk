# #52 feasibility: cut Gemma 4 E2B RAM via the embedding tables

This is a written study. I made no GPU runs, benchmarks or product code changes. The evidence comes from reading mlx-swift-lm 3.33.0 and mlx-swift in `.build/checkouts`, the safetensors header of `mlx-community/gemma-4-e2b-it-4bit`, and a CPU-only tokenizer script (`uvx --with tokenizers`).

## Recommendation

**Option 2: take the per-layer embeddings (PLE) out of MLX and read them from the safetensors file on the host, a few rows per token.**

| | Option 2: host-side PLE | Option 1: vocab prune to ~95k |
|---|---|---|
| Saved, steady state | **~1,260 MiB** (all of PLE) | ~940 MiB (PLE 805 + embed 138) |
| Expected footprint (now 2,807 MB) | ~1,550 MB | ~1,865 MB |
| Quality change | none (same rows, same dequantize, bit-identical) | yes: off-distribution tokenization for names/brands, CJK and emoji |
| LoRA adapter | applies unchanged | applies unchanged (no retrain needed for shapes) |
| Code | ~100 lines in `PoptalkMLX`, no fork | offline converter (tokenizer.json + safetensors + configs), new model dir |
| Risk | decode latency (one host sync per step); load peak unchanged | quality regressions on bench `e-japanese`, `d-cjk-emoji-context`, product names |
| Effort | ~1 day incl. a parity test | ~2–4 days plus bench triage |

The two options don't stack well: once PLE is off-GPU, pruning only saves the remaining 138 MiB of `embed_tokens`, which isn't worth the quality risk. Option 3 (3-bit layers, ~250 MB) stays lowest priority.

## 1. Where the memory goes

Tensor sizes from the safetensors header (`model.safetensors`, 3,386 MiB on disk):

| Group | MiB | Resident? |
|---|---:|---|
| `embed_tokens_per_layer` (PLE): u32 `[262144, 1120]` + bf16 scales and biases `[262144, 140]` each | **1,260.0** | yes |
| decoder layers 0–34 | 1,000.0 | yes |
| `embed_tokens`: u32 `[262144, 192]` + scales and biases `[262144, 24]` | 216.0 | yes |
| `per_layer_model_projection` | 7.4 | yes |
| audio_tower, vision_tower, embed_audio/vision | 902.5 | no (skipped by `Gemma4Model.sanitize` and the component loader) |

The resident text model is about 2,483 MiB, which matches the measured `footprintMB` of 2,807 (bench result `2026-11-20-114758-…-h.json`, Mac16,7) once the KV cache, activations and the process itself are added. Each vocab row costs 5,040 B of PLE plus 864 B of `embed_tokens`, so 5,904 B per token id.

How mlx-swift-lm uses the tables (`Libraries/MLXLLM/Models/Gemma4Text.swift`):

- **Both tables are 4-bit quantized** (affine, group 64). `applyCheckpoint` (`MLXLMCommon/Load.swift`) swaps each `Embedding` for a `QuantizedEmbedding` because the checkpoint has `.scales` for it.
- **Both are gathered per token.** `QuantizedEmbedding.callAsFunction` (`mlx-swift/Source/MLXNN/Quantized.swift:231`) indexes `weight[x]`, `scales[x]` and `biases[x]`, then dequantizes only those rows. PLE is called once per forward pass at `Gemma4Text.swift:765` (`embedPerLayer(inputs)`), reshaped to `[B, L, 35, 256]`, combined with `per_layer_model_projection(h)`, and sliced per layer (lines 764–785). Only the current tokens' rows are ever read.
- **The output head is tied to `embed_tokens`.** `tie_word_embeddings: true`, there is no `lm_head` tensor, and `Gemma4TextModel.callAsFunction` calls `model.embedTokens.asLinear(out)` (line 869), a `quantizedMM` over the whole 262,144-row table each step. So `embed_tokens` must stay on the GPU in full; PLE need not.
- **Loading is eager.** `loadModelCheckpoint` evaluates every tensor into MLX buffers at load (`Load.swift`, `eval(Array(selected.values))`). There is no lazy or mmap path. `Load::eval_cpu` (`Cmlx/mlx/mlx/backend/common/load.cpp:31`) does `allocator::malloc` + `pread`.

## 2. Vocab pruning (option 1)

### How many tokens English dictation and edits need

I tokenized each corpus with the model's `tokenizer.json` (no special tokens added):

| Corpus | Tokens | Unique ids |
|---|---:|---:|
| `bench/cases.jsonl` (all string fields) | 9,608 | 692 |
| `training/heldout.jsonl` | 11,359 | 1,036 |
| `training/samples.jsonl` | 18,645 | 1,035 |
| `training/lexicon.py` (rare names, misheard forms) | 8,876 | 2,445 |
| `/usr/share/dict` words, propernames, connectives, web2a, each as `w`, ` w`, ` w.lower()`, ` W.capitalize()`, ` W.UPPER()` | 4.5 M | 75,571 |
| `/usr/share/man` (groff stripped, English prose) | 6.8 M | 41,753 |
| Markdown in `.build/checkouts` | 0.8 M | 21,593 |
| Poptalk Sources, training/*.py (minus lexicon), README, CLAUDE.md | 70 k | 5,060 |

- The general-English union has **91,162 ids**. Adding the BPE merge closure (every intermediate merge result must survive, or BPE can't reach the kept tokens), 439 special/control ids and the 256 byte tokens gives a **keep set of 94,650**. Adding the task text gives 94,848.
- **Generalization**, i.e. task-token OOV against the keep set built *without* the task text: held-out 2.15%, training samples 0.69%, lexicon 1.30%, **bench 15.8%**. Bench is high because it deliberately includes Japanese (`e-japanese`), CJK and emoji screen context (`d-cjk-emoji-context`, `d-long-emoji-utf16`). The English misses are the words Poptalk cares about most: `▁Kubernetes`, `▁Firebase`, `▁GraphQL`, `▁Salesforce`, `▁Fitzgerald`, `▁Gallagher`, `▁Takahashi`, `▁Mehmet`, plus everyday words that no dictionary form produced (`▁fridge`, `▁yogurt`, `▁prospects`, `laptop`).
- English ids are **spread over the whole id range**, not concentrated low: only 22.8k of the 94.8k keep set fall below id 32,768, and 64.7k below 131,072. Plain truncation therefore doesn't work, and the ids must be remapped. BPE merge rank is no use as a frequency proxy either: the top 65,536 tokens by merge rank still leave 7.6–12% of task tokens OOV.
- Of the full vocab, 100,018 ids are non-Latin scripts or emoji, and the keep set holds 445 of them.

### Byte fallback

Present: `model.type = BPE`, `byte_fallback: true`, decoder `Replace ▁→space, ByteFallback, Fuse`, with tokens `<0x00>`..`<0xFF>` at ids 238–493. Every dropped string stays representable as sub-pieces or UTF-8 bytes. It is **representable but off-distribution**: a name the model saw as one token in pretraining becomes 3–10 byte or sub-word tokens. That is exactly the screen-context names case the product depends on, and it also lengthens prompts.

### MB saved by keep size

| Keep | Saved MiB (PLE + embed) |
|---:|---:|
| 65,536 | 1,107 (945 + 162) |
| 94,650 (general English + closure) | 943 (805 + 138) |
| 100,000 | 913 (779 + 134) |
| 131,072 | 738 (630 + 108) |

### What code would change

Best done offline as a converter producing a new model dir, with no Swift changes beyond pointing the adapter at it:

1. **Tokenizer remap:** write a new `tokenizer.json` with ids `0..K-1`. Drop vocab entries outside the keep set, drop every merge whose inputs or output are dropped, and remap `added_tokens`. Also remap `bos/eos/pad` in `config.json` and `generation_config.json` (`eos_token_id` list) and check that the chat template's control tokens survive. The Swift tokenizer (`#huggingFaceTokenizerLoader`, swift-transformers) just reads the new file.
2. **Slice weights:** take rows `keep` of `embed_tokens.{weight,scales,biases}` and `embed_tokens_per_layer.{…}`, and set `vocab_size` and `vocab_size_per_layer_input` to K. `Gemma4TextModelInner.init` sizes both `Embedding`s from config (lines 705, 715), so `sanitize` needs no change. Doing it in `sanitize` at load instead would need a fork and still read the full tables first.
3. **Output head:** nothing extra. The head is tied, so it shrinks with `embed_tokens`. The model can no longer emit a dropped token. It can still emit byte tokens, so no mask is required.
4. **LoRA adapter:** `adapters/gemma-4-e2b-poptalk-v2/adapters.safetensors` holds 160 tensors, all `layers.{19..34}.{self_attn.q_proj,o_proj,mlp.gate/up/down_proj}.lora_{a,b}`. No embedding shapes are involved, so it still fuses. It was trained on the full-vocab tokenization, so a bench re-run is mandatory and a retrain may help.

## 3. PLE off the GPU (option 2)

### What MLX Swift supports

- **"Keep it on CPU" saves nothing by itself.** On Apple silicon MLX has one allocator. CPU-stream arrays are Metal buffers too (`Load::eval_cpu` → `allocator::malloc`), so the stream choice doesn't change the footprint.
- **mmap'd MLX arrays are effectively out.** `MLXArray(rawPointer:_:dtype:finalizer:)` (`mlx-swift/Source/MLX/MLXArray+Init.swift:95`) → `array(void*, …, deleter)` → `MetalAllocator::make_buffer` → `newBuffer(bytesNoCopy)` (`allocator.cpp:207`). This wraps memory without a copy, but it needs a page-aligned pointer, and the PLE tensors sit at file offsets 1,965,632,308, 1,210,660,838 and 873,150,302 (mod 16 KiB: 11,060, 14,310, 14,174). It would also add the buffer to MLX's residency set, which asks Metal to keep the whole 1.26 GB resident. That defeats the point.
- **What works with no fork:** a host-side lookup. `Embedding` is `open` and `Module.update(modules:)` accepts a subclass, the same mechanism `quantize` uses. After load and fuse, Poptalk swaps `language_model.model.embed_tokens_per_layer` for an `Embedding` subclass whose `callAsFunction(x)`:
  1. reads the token ids (`x.asArray(Int32.self)`),
  2. copies, per id, 4,480 B of weight + 280 B of scales + 280 B of biases from a read-only `mmap` of `model.safetensors` (offsets come from the header, as `safetensorSpansInFileOrder` already parses),
  3. builds three small `MLXArray`s (`[n,1120]` u32, `[n,140]` bf16 ×2) and returns `dequantized(…, groupSize: 64, bits: 4).reshaped(s + [-1])`, the same math as `QuantizedEmbedding.callAsFunction`.

  It then drops the old module and calls `Memory.clearCache()`. Clean file-backed pages are not counted in `phys_footprint`, and the kernel reclaims them under pressure. A 1,000-token prefill copies about 5 MB.

### Where the patch goes and how big it is

- New file `Sources/PoptalkMLX/MappedPLE.swift`, ~80 lines: the mmap, the header offsets and the `Embedding` subclass.
- `MLXProvider.Models.get`, ~5 lines: after `fuse`, call `container.perform { swapPLE($0.model, modelDirectory) }`. Gate it behind an env var (e.g. `POPTALK_PLE_MMAP=1`) at first, so the same binary can A/B. The model directory for an HF id has to be resolved to its snapshot dir. The loader already knows it, and `ModelContext.configuration` / the hub cache path are the places to look.
- Test, ~30 lines: for random ids, `MappedPLE(x)` equals the original `QuantizedEmbedding(x)` exactly. This runs on load only, with no generation.
- No mlx-swift-lm fork is needed. A fork would only buy one thing: skipping the 1.26 GB read at load (override `excludedCheckpointNamespaces`, the PLE module and `sanitize`), which removes the transient load peak and ~0.2 s of load time. Leave that until the steady-state win is confirmed.

### Risks

- **Decode pipelining.** `TokenIterator` overlaps steps with `asyncEval` (`Evaluate.swift:1255`). Reading token ids on the host forces a sync each step, so graph building no longer overlaps the GPU. Expect a small per-token cost. Outputs are short (dictation ~30–100 tokens), but measure decode tok/s. If it matters, the fix is to read the sampled id from the step that produced it (needs a fork of `TokenIterator`) or to use a Metal kernel over a page-aligned PLE sidecar file.
- **Load peak.** Without a fork the full PLE is still read at load and then freed, so the peak stays ~2.8 GB and the steady state drops.
- **Cold page faults.** The first use of a rare token reads 3 × 16 KiB pages from disk: microseconds on NVMe.

## 4. Measurement plan

These steps need the user's go-ahead (GPU). Run them back to back on the same machine, with nothing else heavy running.

`MLXProvider.make` records `footprintMB` (right after load + warm-up) and `loadSeconds`. PoptalkBench adds `footprintMBAfterRun`, and all three land in each result JSON's `provider` block. Latency comes from the median, p90 and max columns of `--compare`. The current baseline is footprintMB 2807, footprintMBAfterRun 2796 and loadSeconds 2.31 (Mac16,7).

```zsh
# from the repo root; sandbox disabled for swift
swift build -c release --product PoptalkBench

# A: baseline (current adapter, full PLE on GPU)
zsh training/bench.zsh adapters/gemma-4-e2b-poptalk-v2

# B: same binary, host-side PLE (after the patch lands behind the env var)
POPTALK_PLE_MMAP=1 zsh training/bench.zsh adapters/gemma-4-e2b-poptalk-v2

# compare each set (d, e, s, h) A vs B
.build/release/PoptalkBench --compare bench/results/<A>-d.json bench/results/<B>-d.json
# …same for -e, -audio-s, -h

# footprint read off the result JSONs
jq '.provider | {footprintMB, footprintMBAfterRun, loadSeconds}' bench/results/<A or B>-h.json

# optional: peak during load and a breakdown (in another shell while the bench runs)
/usr/bin/footprint -p "$(pgrep -n PoptalkBench)"
# decode cost: tok/s from the timing log
/usr/bin/log stream --level info --predicate 'subsystem == "io.lyx.poptalk" && category == "timing"'
```

Pass criteria for option 2: bench pass counts identical (outputs should be bit-identical at temperature 0), `footprintMB` ≤ ~1,600, and median latency within ~5% of A.

If option 1 is still wanted later, build the pruned model dir with an offline converter and run `zsh training/bench.zsh <pruned dir>` against A the same way. Watch `e-japanese`, `d-cjk-emoji-context`, `d-fluidaudio` and the `s-kubernetes` cases first.
