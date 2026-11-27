#!/usr/bin/env zsh
# Builds training/out/v8/data/{train,valid}.jsonl for the E2B v8 adapter (#96, cleanup levels): v7's data plus the same
# dictations at Verbatim and Polished (gen.py cleanup-level section). Reuses v6's speech and E4B teacher outputs; the
# one GPU step is the E4B teacher at Verbatim on l-verbatim-keep (~720 items, ~15 min), skipped when
# training/out/v8/teach_out.jsonl exists. SKIP_TEACH=1 builds without it; DG=.build/debug/PoptalkDatagen for a dry run.
# Run from the repo root, outside the sandbox, after training/make_data_v6.zsh's slow steps and `swift build -c release`
# (the teacher needs this branch's PoptalkDatagen: `pipeline` takes `cleanup`). Syncs lora-v8.yaml's iters to 40% of
# the real train rows. The items check fails on any phrase shared with a bench or held-out case (#115); ALLOW_PHRASES=1
# lets it pass.
set -euo pipefail
gen=(uv run --script training/gen.py)
dg=${DG:-.build/release/PoptalkDatagen}
v8=training/out/v8
[[ -s training/out/heard.jsonl && -s training/out/v6/teach_out.jsonl ]] || {
  print -u2 "needs training/out/heard.jsonl and training/out/v6/teach_out.jsonl: run training/make_data_v6.zsh"; exit 1
}
uv run --script training/contamination.py            # self-test
[[ -s $v8/teach.jsonl ]] || $gen teach8
[[ -s $v8/teach_out.jsonl ]] || [[ -n ${SKIP_TEACH:-} ]] || {
  $dg pipeline --model mlx-community/gemma-4-e4b-it-4bit < $v8/teach.jsonl > $v8/teach_out.part
  mv $v8/teach_out.part $v8/teach_out.jsonl
}
$gen build8
uv run --script training/contamination.py $v8/items.jsonl ${ALLOW_PHRASES:+--allow-phrases} > /dev/null
$dg render < $v8/items.jsonl > $v8/rendered.jsonl
$gen split8
n=$(wc -l < $v8/data/train.jsonl); s=$((n * 2 / 5 / 4))
sed -i '' -E "s/^iters: [0-9]+/iters: $((s * 4))/; s/(arguments: \[1\.0e-4, )[0-9]+/\1$s/; s/^steps_per_eval: [0-9]+/steps_per_eval: $((s * 2))/" training/lora-v8.yaml
print "train $n rows -> $((s * 4)) iters ($s optimizer steps)"
