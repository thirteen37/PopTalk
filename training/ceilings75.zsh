#!/usr/bin/env zsh
# #75 step 1: raw-ASR and oracle-term ceilings on the dictation sets (d-, s-, held-out h-d-). From the repo root,
# after `swift build -c release`:   zsh training/ceilings75.zsh [out dir, default training/out/issue75]
set -euo pipefail
out=${1:-training/out/issue75}
bench() {  # bench <tag> <PoptalkBench args...>: d/s/h into $out/<tag>/
  local tag=$1; shift
  local b=(.build/release/PoptalkBench "$@" --out $out/$tag)
  $b --runs 3 --filter 'd-*'
  $b --runs 1 --filter 's-*'
  $b --runs 3 --cases training/heldout.jsonl --filter 'h-d-*'
}
typeset -A models=(v3 adapters/gemma-4-e2b-poptalk-v3 e4b mlx-community/gemma-4-e4b-it-4bit)
for o in '' --oracle-terms; do bench raw${o:+-oracle} --provider raw $o; done
for tag m in ${(kv)models}; do  # each pair back to back
  for o in '' --oracle-terms; do bench $tag${o:+-oracle} --provider mlx --cleanup-model $m $o; done
done
