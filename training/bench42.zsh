#!/usr/bin/env zsh
# #42 A/B: MLX prompt cache off vs on, back to back on the same build. From the repo root, after
# `swift build -c release --product PoptalkBench`:
#   zsh training/bench42.zsh [out dir] [configs] [sets]   (defaults: training/out/42/run, v3 e4b-orig e4b-gepa, d e h)
# e4b-orig needs the original system prompts in training/out/42/orig-{dictation,edit}.txt. Each run's timing log
# (counts only, no text) goes next to its report. Summarize with training/stats42.zsh.
set -uo pipefail
O=${1:-training/out/42/run}
P=training/out/42
typeset -A cfg sets
cfg=(v3 "--cleanup-model adapters/gemma-4-e2b-poptalk-v3"
     e4b-orig "--cleanup-model mlx-community/gemma-4-e4b-it-4bit --dictation-prompt-file $P/orig-dictation.txt --edit-prompt-file $P/orig-edit.txt"
     e4b-gepa "--cleanup-model mlx-community/gemma-4-e4b-it-4bit")
sets=(d "--filter d-*" e "--filter e-*" h "--cases training/heldout.jsonl --filter h-*")
for c in ${=2:-v3 e4b-orig e4b-gepa}; do
  for s in ${=3:-d e h}; do
    for cache in 0 1; do
      out=$O/$c-$s-cache$cache
      mkdir -p $out
      echo "== $c $s cache=$cache $(date +%T)"
      /usr/bin/log stream --level info --predicate 'subsystem == "io.lyx.poptalk" AND category == "timing" AND process == "PoptalkBench"' > $out/timing.log &
      lp=$!
      sleep 1
      POPTALK_PROMPT_CACHE=$cache .build/release/PoptalkBench --provider mlx ${=cfg[$c]} --runs 3 ${=sets[$s]} --out $out | tail -4
      kill $lp
    done
  done
done
