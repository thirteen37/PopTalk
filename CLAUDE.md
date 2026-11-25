# PopTalk

macOS menu-bar dictation + voice editing (Swift 6, SwiftPM, no Xcode project). Targets: PoptalkCore (pure logic, tested), PoptalkSpeech (FluidAudio/Parakeet), PoptalkMLX (in-process MLX LLMs), Poptalk (app), PoptalkBench, PoptalkDatagen.

## Commands
- Run `swift build` / `swift test` / `git` / `gh` with the sandbox disabled: SwiftPM's manifest compile calls sandbox-exec and fails inside it.
- `swift test > .build/t.log 2>&1 && ! rg -q 'Test run with .* failed' .build/t.log` - gate commits on this. Don't gate on a `passed` match: `swift test` also prints a separate 3-test run that passes even when the main run fails.
- `scripts/install.zsh` - release build, sign, install to /Applications, relaunch. Waits (up to 120 s, then aborts) while PopTalk records or processes: `scripts/wait-idle.zsh` polls the busy marker `~/Library/Caches/io.lyx.poptalk/busy` (`BusyMarker`). Commit first: a dirty tree stamps `PoptalkCommit` with `-dirty`.
- `zsh training/bench.zsh <model id|dir>` - d/e/s bench + held-out set; compare back-to-back runs only (`PoptalkBench --compare a.json b.json`).
- Shipping a prompt, model or pipeline-guard change needs a real-history replay back to back with current main, on top of the bench: `scripts/replay.zsh [candidate-prompt.txt] current` (a code change: run it in both checkouts; counts only: raw fallbacks, timeouts, stray list markers). Replay inputs and outputs are history content and stay out of context, the repo and logs.
- New issues go on the GitHub Project "Poptalk" (#4) with a Status. Do it right after `gh issue create`, including in subagent briefs that file issues: `gh project item-add 4 --owner thirteen37 --url <issue url>`, then `gh project item-edit` with Status Todo, In Progress or Done (`gh project field-list 4 --owner thirteen37` lists the ids). Move it to Done when it closes.
- `/usr/bin/log stream --level info --predicate 'subsystem == "io.lyx.poptalk"'` - stage timings (category `timing`: counts and the frontmost app's bundle ID, no text). In zsh, `log` is a builtin, so use the full path.

## Gotchas
- Default MLX model, for dictation and edits, is the E2B v6 fine-tune `adapters/gemma-4-e2b-poptalk-v6`: a LoRA adapter loaded unfused on base E2B (its `adapter_config.json` names the base); base E4B with its own GEPA prompts is an option. Any local adapter dir works as a custom model id the same way.
- Never fuse a LoRA into the 4-bit base (`mlx_lm.fuse`, `model.fuse(with:)`): requantizing rounds most of it away (#103).
- Base E2B and E4B load from text-only copies in `~/Library/Application Support/Poptalk/models/<name>-text` (#51, #72, `TextOnlyModel`), stripped at first use from the shared HF cache (read only) or from a download into `models/.download` (deleted after). Delete the copy to rebuild it.
- Gemma 4's per-layer embeddings (1.59 GB in E4B) are read per token from the mmap'd safetensors file, not GPU memory (`MappedPLE`, #52). Disable for A/B with `POPTALK_PLE_MMAP=0` or the `mlxMappedPLE` default. The gather runs on MLX's CPU stream (#62): a GPU op over the mapping wires all of it (check `vm_stat` wired memory, not just `footprintMB`).
- The first Vision OCR per process takes ~15 s; `ScreenContext.prewarmOCR()` runs at launch and capture skips OCR until it is warm.
- Fine-tune prompts must match `Prompts.swift` exactly; changing the prompt text or order needs a bench re-run (and possibly a retrain).
- Never log or persist transcripts, screen text or replies outside the opt-in history (`HistoryStore`). One exception: screen terms that changed a dictation, in `LearnedTerms` (opt-in, local only, never synced).
- Training, retrains and long bench sweeps hog the GPU for hours: ask the user first.
- FluidAudio is built with `traits: []` (no NeMo ITN, TTS, Diarizer; #66); after changing its traits, `rm -rf .build/out` or linking fails on undefined `_nemo_*` symbols.
- Agent worktrees are ~5 GB each (their own `.build`); remove them as soon as the work merges.
