#!/usr/bin/env zsh
# #42 A/B: MLX prompt cache off vs on, back to back on the same build. From the repo root, after
# `swift build -c release --product PoptalkBench`:
#   zsh training/bench42.zsh [out dir] [configs]   (default training/out/42/run, all of v3 e4b-orig e4b-gepa)
# e4b-orig needs the original system prompts in training/out/42/orig-{dictation,edit}.txt.
# Summarize with training/stats42.zsh.
set -uo pipefail
O=${1:-training/out/42/run}
P=training/out/42
typeset -A cfg
cfg=(v3 "--cleanup-model adapters/gemma-4-e2b-poptalk-v3"
     e4b-orig "--cleanup-model mlx-community/gemma-4-e4b-it-4bit --dictation-prompt-file $P/orig-dictation.txt --edit-prompt-file $P/orig-edit.txt"
     e4b-gepa "--cleanup-model mlx-community/gemma-4-e4b-it-4bit")
sets=("--filter d-*" "--filter e-*" "--cases training/heldout.jsonl --filter h-*")
names=(d e h)
for c in ${=2:-v3 e4b-orig e4b-gepa}; do
  for i in 1 2 3; do
    for cache in 0 1; do
      echo "== $c ${names[$i]} cache=$cache $(date +%T)"
      POPTALK_PROMPT_CACHE=$cache .build/release/PoptalkBench --provider mlx ${=cfg[$c]} --runs 3 ${=sets[$i]} \
        --out $O/$c-${names[$i]}-cache$cache | tail -4
    done
  done
done
