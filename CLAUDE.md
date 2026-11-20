# PopTalk

macOS menu-bar dictation + voice editing (Swift 6, SwiftPM, no Xcode project). Targets: PoptalkCore (pure logic, tested), PoptalkSpeech (FluidAudio/Parakeet), PoptalkMLX (in-process MLX LLMs), Poptalk (app), PoptalkBench, PoptalkDatagen.

## Commands
- Run `swift build` / `swift test` / `git` / `gh` with the sandbox disabled: SwiftPM's manifest compile calls sandbox-exec and fails inside it.
- `swift test > .build/t.log 2>&1; rg -q 'Test run with .* passed' .build/t.log` - gate commits on this; a piped `rg 'Test run with'` also matches "failed".
- `scripts/install.zsh` - release build, sign, install to /Applications, relaunch. Waits (up to 120 s, then aborts) while PopTalk records or processes: `scripts/wait-idle.zsh` polls the busy marker `~/Library/Caches/io.lyx.poptalk/busy` (`BusyMarker`). Commit first: a dirty tree stamps `PoptalkCommit` with `-dirty`. If `open` fails with -600, run `open /Applications/PopTalk.app` again.
- `zsh training/bench.zsh <model id|dir>` - d/e/s bench + held-out set; compare back-to-back runs only (`PoptalkBench --compare a.json b.json`).
- `/usr/bin/log stream --level info --predicate 'subsystem == "io.lyx.poptalk"'` - stage timings (category `timing`, counts only, no text). In zsh, `log` is a builtin, so use the full path.

## Gotchas
- Default MLX model is `adapters/gemma-4-e2b-poptalk-v2`: a LoRA adapter fused in memory onto base E2B at load. Its `adapter_config.json` names the base.
- `mlx-community/gemma-4-e2b-it-4bit` loads from a text-only copy in `~/Library/Application Support/Poptalk/models/gemma-4-e2b-it-4bit-text` (#51, `TextOnlyModel`), stripped at first use from the shared HF cache (read only) or from a download into `models/.download` (deleted after). Delete the copy to rebuild it.
- Gemma 4's per-layer embeddings (1.26 GB) are read per token from the mmap'd safetensors file, not GPU memory (`MappedPLE`, #52). Disable for A/B with `POPTALK_PLE_MMAP=0` or the `mlxMappedPLE` default. The gather runs on MLX's CPU stream (#62): a GPU op over the mapping wires all of it (check `vm_stat` wired memory, not just `footprintMB`).
- The first Vision OCR per process takes ~15 s; `ScreenContext.prewarmOCR()` runs at launch and capture skips OCR until it is warm.
- Fine-tune prompts must match `Prompts.swift` exactly; changing the prompt text or order needs a bench re-run (and possibly a retrain).
- Never log or persist transcripts, screen text or replies outside the opt-in history (`HistoryStore`).
- Training, retrains and long bench sweeps hog the GPU for hours: ask the user first.
- Agent worktrees are ~5 GB each (their own `.build`); remove them as soon as the work merges.
