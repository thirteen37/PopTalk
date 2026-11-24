#!/usr/bin/env zsh
# Benches a cleanup model on the bench sets and the held-out set (#21). From the repo root:
#   training/bench.zsh <model id or local dir> [edit model] [--flag ...]
#   (edit model defaults to the cleanup model; trailing --flags go to PoptalkBench, e.g. --dictation-prompt-file F)
# Real voice (#99, docs/real-voice-bench.md): add `--audio-dir bench/audio-real`. Only the speech set uses it, and its
# results go to the gitignored bench/results-real/: they hold what you said, so commit or post only counts
# (WER, recall, pass counts), never the files or transcripts.
set -euo pipefail
m=$1; shift
edit=()
[[ ${1:-} == (|--*) ]] || { edit=(--edit-model $1); shift }
b=(.build/release/PoptalkBench --provider mlx --cleanup-model $m $edit "$@")
$b --runs 3 --filter 'd-*'
$b --runs 3 --filter 'e-*'
$b --runs 1 --filter 's-*'
$b --runs 3 --cases training/heldout.jsonl --filter 'h-*'
