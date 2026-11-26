#!/usr/bin/env zsh
# Check for #119: a PoptalkBench --replay whose last cleanup stopped at the reply limit exits 0. Before the fix, the
# generation task left running at the limit was still evaluating on MLX while exit ran its static destructors: exit
# 139, 3 of 3. Needs a release build (`swift build -c release --product PoptalkBench`) and the model.
#   zsh scripts/test-reply-limit-exit.zsh [model] [runs]   (POPTALK_BENCH=path: another PoptalkBench binary)
# Invented input: a question, and a system prompt asking for a long answer, so the reply runs past the limit.
set -euo pipefail
cd "${0:A:h}/.."
m=${1:-adapters/gemma-4-e2b-poptalk-v6} runs=${2:-3} bench=${POPTALK_BENCH:-.build/release/PoptalkBench}
dir=$(mktemp -d "${TMPDIR:-/tmp}/reply-limit-exit.XXXXXX")
trap 'rm -rf -- $dir' EXIT
print -r -- 'You are a helpful assistant. Answer the question in <transcript> in detail, in at least 150 words.' > $dir/prompt.txt
t='what is the tallest mountain in the world'
print -r -- "{\"id\":\"1\",\"transcript\":\"$t\",\"app\":\"Notes\",\"window\":\"Untitled\",\"ax\":\"\",\"ocr\":\"\",\"vocabulary\":[]}" > $dir/in.jsonl
# The provider stops once the reply is past maxCleanupLength (1.5 × 41 + 40 = 101) by its 20-character margin.
stop=$(( 101 + 20 ))
for k in {1..$runs}; do
  code=0
  $bench --replay $dir/in.jsonl $dir/out.jsonl --cleanup-model $m --dictation-prompt-file $dir/prompt.txt > $dir/log 2>&1 || code=$?
  n=$(jq '.reply // "" | length' $dir/out.jsonl 2>/dev/null || print 0)
  (( n > stop )) || { print "run $k: no reply past the limit (exit $code, reply $n chars); the check proves nothing"; exit 1 }
  (( code == 0 )) || { print "run $k: stopped at the reply limit, then exit $code"; exit 1 }
done
print "ok: $runs runs stopped at the reply limit and exited 0"
