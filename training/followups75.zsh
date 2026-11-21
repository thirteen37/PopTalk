#!/usr/bin/env zsh
# #75 follow-ups: screen-term recaser on/off for v3 and E4B, then the skip gate on Parakeet-cased dictations.
# From the repo root, after `swift build -c release`:   zsh training/followups75.zsh [out dir, default training/out/issue75-followups]
set -euo pipefail
out=${1:-training/out/issue75-followups}
mkdir -p $out
typeset -A models=(v3 adapters/gemma-4-e2b-poptalk-v3 e4b mlx-community/gemma-4-e4b-it-4bit)
bench() {  # bench <tag> <PoptalkBench args...>: d/s/h-d/h-e into $out/<tag>/
  local tag=$1; shift
  local b=(.build/release/PoptalkBench --provider mlx "$@" --out $out/$tag)
  $b --runs 3 --filter 'd-*'
  $b --runs 1 --filter 's-*'
  $b --runs 3 --cases training/heldout.jsonl --filter 'h-d-*'
  $b --runs 3 --cases training/heldout.jsonl --filter 'h-e-*'
}
for tag m in ${(kv)models}; do  # each pair back to back
  for r in off on; do bench $tag-recase-$r --cleanup-model $m --recase-terms $r; done
done

# Skip gate: the typed d-/h-d- transcripts are lowercase, so Parakeet-cased copies are synthesized and
# transcribed like the s- cases (`speak`). Gate off vs on, v3 with its default (recase on).
jq -c 'select(.kind == "dictation") | .id |= "p-" + . | .speak = .transcript | del(.transcript) | .voice = "Samantha"' \
  <(rg '"id": ?"d-' bench/cases.jsonl) <(rg '"id": ?"h-d-' training/heldout.jsonl) > $out/parakeet-cases.jsonl
for g in off on; do
  b=(.build/release/PoptalkBench --provider mlx --cleanup-model $models[v3] --skip-gate $g --out $out/v3-gate-$g)
  $b --runs 1 --filter 's-*'
  $b --runs 1 --cases $out/parakeet-cases.jsonl
done
