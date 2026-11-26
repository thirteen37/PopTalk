#!/usr/bin/env zsh
# Counts-only baseline for #125: replays the history dictations with two number words in a row (or "dollars" and a
# number) through Pipeline and prints, per grouped form, how the output wrote it (scripts/number-counts.py). Run
# outside the sandbox. Usage: scripts/number-counts.zsh [--model ID] [--guards -NAME,...] [history.jsonl ...]
#   (defaults: the shipped E2B v6 fine-tune; this Mac's history plus every Mac's synced file)
# Inputs and outputs are history content: they live in a private temp dir, deleted at exit, and are never printed.
set -euo pipefail
umask 077
zparseopts -D -E -F -- -model:=model -guards:=guards || exit 1
model=${model[-1]:-adapters/gemma-4-e2b-poptalk-v6}
files=(${@:A})
(( $#files )) || files=(
  ~/Library/Application\ Support/Poptalk/history/history.jsonl(N)
  ~/Library/Mobile\ Documents/com~apple~CloudDocs/PopTalk/history/history-*.jsonl(N)
)
(( $#files )) || { print -u2 "No history files found."; exit 1 }
cd "${0:A:h:h}"
mkdir -p .build
swift build -c release --product PoptalkBench > .build/replay-build.log 2>&1 || { print -u2 "Build failed: .build/replay-build.log"; exit 1 }
dir=$(mktemp -d "${TMPDIR:-/tmp}/poptalk-numbers.XXXXXX")
trap 'rm -rf -- $dir' EXIT
scripts/replay.zsh build $files | jq -c 'select(.skipped | not)' > $dir/all.jsonl
uv run --script scripts/number-counts.py filter < $dir/all.jsonl > $dir/in.jsonl
print "replayable dictations: $(wc -l < $dir/all.jsonl | tr -d ' ')"
scripts/wait-idle.zsh
.build/release/PoptalkBench --replay $dir/in.jsonl $dir/out.jsonl --cleanup-model $model $guards | tail -1
uv run --script scripts/number-counts.py count $dir/out.jsonl | column -t -s $'\t'
