#!/usr/bin/env zsh
# Unattended v3 session (#60, #68): teacher, data, three trainings, then back-to-back benches. NOT run by
# default: it holds the GPU for hours, so start it only with the user's go-ahead. From the repo root:
#   swift build -c release && zsh training/overnight.zsh 2>&1 | tee training/out/overnight.log
set -euo pipefail
lora=(uv run --project training mlx_lm.lora --config)

# 1. E4B teacher (e-tone/e-translate/e-rephrase targets), then rebuild items -> rendered -> data/{train,valid}.
#    Speech is cached (heard.jsonl exists), so make_data.zsh only runs the teacher, build, render and split.
#    The data is chat messages ({"messages": [...]}), not a rendered prompt string, so one build serves every
#    base: mlx_lm applies each base's own chat template at training time. No per-base re-render.
rm -f training/out/teach_out.jsonl
zsh training/make_data.zsh
wc -l training/out/data/{train,valid}.jsonl   # ~40% iters in the configs assume ~6,850 train rows: adjust if far off

# 2. Trainings (each ~40% of train rows, batch 1 x accumulate 4).
$lora training/lora.yaml               # -> training/out/adapters-v3
$lora training/lora-qwen3-1.7b.yaml    # -> training/out/adapters-qwen3-1.7b
$lora training/lora-qwen3-0.6b.yaml    # -> training/out/adapters-qwen3-0.6b

# 3. Benches, back to back (compare with PoptalkBench --compare a.json b.json). Adapter dirs load as
#    base + LoRA fused in memory (adapter_config.json names the base).
zsh training/bench.zsh adapters/gemma-4-e2b-poptalk-v2          # E2B v2 (shipping baseline)
zsh training/bench.zsh training/out/adapters-v3                 # E2B v3
zsh training/bench.zsh training/out/adapters-qwen3-1.7b         # Qwen3-1.7B v3
zsh training/bench.zsh training/out/adapters-qwen3-0.6b         # Qwen3-0.6B v3

# S1-mini (#67): dictation only (Prompts.isS1Mini picks its prompt), each set right after the E2B v3 equivalent,
# then one hybrid run (S1-mini cleanup + E2B v3 edits) for footprint. Skipped until the weights exist.
S1="$HOME/Library/Application Support/Poptalk/models/s1-mini-4bit"
V3=training/out/adapters-v3
b=(.build/release/PoptalkBench --provider mlx)
if [[ -f $S1/config.json ]]; then
  $b --runs 3 --cleanup-model $V3 --filter 'd-*'
  $b --runs 3 --cleanup-model "$S1" --filter 'd-*'
  $b --runs 3 --cleanup-model $V3 --cases training/heldout.jsonl --filter 'h-d-*'
  $b --runs 3 --cleanup-model "$S1" --cases training/heldout.jsonl --filter 'h-d-*'
  zsh training/bench.zsh "$S1" $V3                              # hybrid: all sets, footprint with both loaded
else
  print "skip S1-mini: no $S1"
fi

# TODO(#62): batched-embeddings E2B v3 variant, still being built. Add its bench line here once it lands, e.g.
#   zsh training/bench.zsh training/out/adapters-v3   (with the #62 build/flag), right after the E2B v3 run above.
