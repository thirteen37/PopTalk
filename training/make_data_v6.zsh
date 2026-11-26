#!/usr/bin/env zsh
# Builds training/out/v6/data/{train,valid}.jsonl for the E2B v6 adapter (#103; see the m6 section of gen.py and
# lora-v6.yaml for the phase-2 sequence). Run from the repo root, outside the sandbox, after `swift build -c release`.
# Slow steps are skipped when their output exists: speech (say + Parakeet, shared with make_data.zsh in training/out/)
# and the E4B teacher (GPU). SKIP_TEACH=1 builds without teacher items; DG=.build/debug/PoptalkDatagen for a dry run.
# The items check fails on any phrase shared with a bench or held-out case (#115); ALLOW_PHRASES=1 lets it pass.
set -euo pipefail
gen=(uv run --script training/gen.py)
dg=${DG:-.build/release/PoptalkDatagen}
out=training/out v6=training/out/v6
uv run --script training/contamination.py            # self-test
[[ -s $out/heard.jsonl ]] || [[ -n ${SKIP_SPEECH:-} ]] || {
  $gen speak; $dg transcribe --cache $out/audio-cache < $out/speak.jsonl > $out/heard.part && mv $out/heard.part $out/heard.jsonl
}
[[ -s $v6/teach.jsonl ]] || $gen teach6
[[ -s $v6/teach_out.jsonl ]] || [[ -n ${SKIP_TEACH:-} ]] || {
  $dg pipeline --model mlx-community/gemma-4-e4b-it-4bit < $v6/teach.jsonl > $v6/teach_out.part
  mv $v6/teach_out.part $v6/teach_out.jsonl
}
$gen build6
uv run --script training/contamination.py $v6/items.jsonl ${ALLOW_PHRASES:+--allow-phrases} > /dev/null
$dg render < $v6/items.jsonl > $v6/rendered.jsonl
$gen split6
