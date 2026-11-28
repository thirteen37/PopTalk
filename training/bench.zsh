#!/usr/bin/env zsh
# Benches a cleanup model on the bench sets and the held-out set (#21), twice (#108). From the repo root:
#   training/bench.zsh <model id or local dir> [edit model] [--flag ...]
#   (edit model defaults to the cleanup model; trailing --flags go to PoptalkBench, e.g. --dictation-prompt-file F)
# 1. Ship gate: the full Pipeline on d-*, e-*, l-* (cleanup levels, #96: a level model needs --levels, else every
#    case is sent as Clean), s-* and held-out h-*.
# 2. Model only: d-*, e-*, l-* and h-* again with every repair and reject off (`--guards -repairs,-rejects`; the prepass
#    stays, it shapes the model's input), so no repair or raw fallback hides what the model did. Its result files end
#    in -model: compare them with other -model files only.
# Then a summary line per set and pass: cases passing every run, and runs passed; for d, l and h also the "other" word
# changes (training/word_changes.py, #126, #141): grammar and content rewrites per 100 runs, and the % of runs with one,
# which mustContain alone misses. They align the case transcript, before the prepass, with each run's output.
# The speech set hears the app's default speech model (Parakeet TDT v2); `--speech-model v3` overrides it.
# Real voice (#99, docs/real-voice-bench.md): add `--audio-dir bench/audio-real`. Only the speech set uses it, and its
# results go to the gitignored bench/results-real/: they hold what you said, so commit or post only counts
# (WER, recall, pass counts), never the files or transcripts.
set -euo pipefail
m=$1; shift
edit=()
[[ ${1:-} == (|--*) ]] || { edit=(--edit-model $1); shift }
b=(.build/release/PoptalkBench --provider mlx --cleanup-model $m $edit "$@")
log=$(mktemp "${TMPDIR:-/tmp}/bench.XXXXXX")
trap 'rm -f -- $log' EXIT
files=()
run() { $b "$@" | tee $log; files+=("$(sed -n 's/^wrote //p' $log)") }
for guards in "" -repairs,-rejects; do
  g=(${guards:+--guards} $guards)
  run --runs 3 --filter 'd-*' $g
  run --runs 3 --filter 'e-*' $g
  run --runs 3 --filter 'l-*' $g
  [[ -n $guards ]] || run --runs 1 --filter 's-*'
  run --runs 3 --cases training/heldout.jsonl --filter 'h-*' $g
done
other() {  # "other" word changes in a results file's dictation runs (h-* also has edits), against its cases file
  jq -c --slurpfile c $2 '($c | map({key: .id, value: .}) | from_entries) as $k
    | .cases[] | select(.kind == "dictation") | $k[.id] as $x | .runs[] | select(.output != null)
    | {transcript: $x.transcript, output, screen: "\($x.context // "")\n\($x.ocr // "")", vocabulary: ($x.vocabulary // [])}' $1 \
    | uv run --script training/word_changes.py | awk '$1 == "total" { printf ", other %s/100, %s%% runs", $(NF-2), $NF }'
}
print
for f in $files; do
  jq -j --arg f ${f:t} 'def ok: (.failures // []) == []; [.cases[] | select(all(.runs[]; ok))] as $ok | [.cases[].runs[]] as $r
    | "\($f): \($ok | length)/\(.cases | length) cases, \($r | map(select(ok)) | length)/\($r | length) runs"' $f
  case ${f:t:r} in
    *-h) other $f training/heldout.jsonl ;;
    *-[dl]) other $f bench/cases.jsonl ;;
  esac
  print
done
