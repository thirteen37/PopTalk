#!/usr/bin/env zsh
# Builds training/out/v7/data/{train,valid}.jsonl for the E2B v7 adapter (#105): v6's data plus d-keep-lead (gen.py
# v7 section), d-numgroup (#125), the kept-as-said changes (#126; split7 keeps unfixable names as heard) and d-short-sidebar (#116). Reuses v6's speech and E4B teacher outputs (teach6 is unchanged), so it needs no GPU. Run from the
# repo root, outside the sandbox, after training/make_data_v6.zsh's slow steps and `swift build -c release`.
# Syncs lora-v7.yaml's iters to 40% of the real train rows.
# The items check fails on any phrase shared with a bench or held-out case (#115); ALLOW_PHRASES=1 lets it pass.
set -euo pipefail
gen=(uv run --script training/gen.py)
dg=${DG:-.build/release/PoptalkDatagen}
v7=training/out/v7
[[ -s training/out/heard.jsonl && -s training/out/v6/teach_out.jsonl ]] || {
  print -u2 "needs training/out/heard.jsonl and training/out/v6/teach_out.jsonl: run training/make_data_v6.zsh"; exit 1
}
uv run --script training/contamination.py            # self-test
$gen build7
uv run --script training/contamination.py $v7/items.jsonl ${ALLOW_PHRASES:+--allow-phrases} > /dev/null
$dg render < $v7/items.jsonl > $v7/rendered.jsonl
$gen split7
n=$(wc -l < $v7/data/train.jsonl); s=$((n * 2 / 5 / 4))
sed -i '' -E "s/^iters: [0-9]+/iters: $((s * 4))/; s/(arguments: \[1\.0e-4, )[0-9]+/\1$s/; s/^steps_per_eval: [0-9]+/steps_per_eval: $((s * 2))/" training/lora-v7.yaml
print "train $n rows -> $((s * 4)) iters ($s optimizer steps)"
