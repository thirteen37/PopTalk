#!/usr/bin/env zsh
# Builds training/out/data/{train,valid}.jsonl (#21). Run from the repo root after `swift build -c release`.
# Slow steps (Parakeet transcription, E4B teacher) are skipped when their output already exists.
set -euo pipefail
gen=(python3 training/gen.py)
dg=.build/release/PoptalkDatagen
out=training/out
python3 training/contamination.py            # self-test
[[ -s $out/heard.jsonl ]] || { $gen speak; $dg transcribe --cache $out/audio-cache < $out/speak.jsonl > $out/heard.jsonl; }
[[ -s $out/teach_out.jsonl ]] || {
  $gen teach
  $dg render < $out/teach.jsonl > $out/teach_msgs.jsonl
  $dg teach --model mlx-community/gemma-4-e4b-it-4bit < $out/teach_msgs.jsonl > $out/teach_out.jsonl
}
$gen build
python3 training/contamination.py $out/items.jsonl > /dev/null
$dg render < $out/items.jsonl > $out/rendered.jsonl
$gen split
