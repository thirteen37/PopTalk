#!/usr/bin/env zsh
# Builds training/out/data/{train,valid}.jsonl (#21). Run from the repo root after `swift build -c release`.
# Slow steps (Parakeet transcription, E4B teacher) are skipped when their output already exists.
# SKIP_TEACH=1 skips the E4B teacher (GPU, #60): the build then has no e-tone/e-translate/e-rephrase items.
# The items check fails on any phrase shared with a bench or held-out case (#115); ALLOW_PHRASES=1 lets it pass.
set -euo pipefail
gen=(uv run --script training/gen.py)
dg=.build/release/PoptalkDatagen
out=training/out
uv run --script training/contamination.py            # self-test
[[ -s $out/heard.jsonl ]] || { $gen speak; $dg transcribe --cache $out/audio-cache < $out/speak.jsonl > $out/heard.jsonl; }
[[ -s $out/teach_out.jsonl ]] || {
  $gen teach
  $dg render < $out/teach.jsonl > $out/teach_msgs.jsonl
  [[ -n ${SKIP_TEACH:-} ]] || $dg teach --model mlx-community/gemma-4-e4b-it-4bit < $out/teach_msgs.jsonl > $out/teach_out.jsonl
}
$gen build
uv run --script training/contamination.py $out/items.jsonl ${ALLOW_PHRASES:+--allow-phrases} > /dev/null
$dg render < $out/items.jsonl > $out/rendered.jsonl
$gen split
