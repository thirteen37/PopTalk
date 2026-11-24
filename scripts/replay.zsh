#!/usr/bin/env zsh
# Ship check for prompt, model and guard changes: replays real history dictations through Pipeline
# (`PoptalkBench --replay`) for each config, back to back, and prints counts only. Run outside the sandbox.
# Usage: scripts/replay.zsh [--model ID] [--timeout S] [--subset REGEX] [--history FILE]... [CONFIG ...]
#   CONFIG: `current` (the built prompt; the default) or a dictation system prompt file (--dictation-prompt-file).
#   --model defaults to E4B, --timeout to the app's 4 s; --history to this Mac's file plus every Mac's synced file.
#   --subset adds rows for dictations whose transcript matches REGEX (jq regex, case-insensitive).
# Input: opt-in history dictations (no selection) that called a model, deduped by id; app, window, screen text and
#   vocabulary are read back from the recorded prompt, the transcript is the one Pipeline got. Older prompt formats
#   that don't parse are skipped and counted.
# Columns:
#   raw      raw transcript inserted ("(raw)" label) though the model replied: a guard rejected the reply
#   len content protect echo notext   raw split by the guard that rejected the reply: maxCleanupLength,
#            dropsContent, dropsProtected, echoesContext, or nothing left after stripping chatter
#   timeout  "(raw)" with no reply: the model timed out or failed
#   stray    output has a list line ("- ", "* ", "1. ") and the transcript has none (spoken lists count too)
#   empty    Nothing inserted, or blank output
#   diff     output differs from the first config's for the same dictation
#   raw+ raw-  raw or timeout here but not in the first config, and the reverse
#   mean/p50/p90  seconds per dictation
# Inputs and outputs are history content: they live in a private temp dir, deleted at exit, and are never printed.
# Internal, for scripts/test-replay.zsh: `replay.zsh build HISTORY...` and `replay.zsh counts IN OUT...`.
set -euo pipefail
umask 077

build() {
  cat -- "$@" | jq -cnR '
    def unesc: gsub("&quot;"; "\"") | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&amp;"; "&");
    # Pipeline joins OCR and field text with "\n" and clips them to 3000 and 4000 characters: split back at a
    # newline that keeps both within budget, so the replayed prompt is the recorded one.
    def split_screen: . as $b
      | if length <= 4000 then {ocr: "", ax: .} else
          ([indices("\n")[] | select(. <= 3000 and ($b | length) - . - 1 <= 4000)] | first) as $p
          | if $p then {ocr: .[:$p], ax: .[$p + 1:]} else {ocr: "", ax: .} end
        end;
    [inputs | fromjson? | select(type == "object" and .type == "request" and (.selection // "") == ""
                                 and (.messages | type) == "array")]
    | unique_by(.id) | sort_by(.at)[]
    | .id as $id | .transcript as $t
    | ([.messages[] | select(.role == "user")] | last | .content // ""
       | capture("^<screen app=\"(?<app>[^\"]*)\" window=\"(?<window>[^\"]*)\">\n(?<screen>.*)\n</screen>(\n<vocabulary>(?<vocab>.*)</vocabulary>)?\n<transcript>"; "p")
         // null) as $m
    | if $m == null then {skipped: true} else
        {id: $id, transcript: $t, app: ($m.app | unesc), window: ($m.window | unesc),
         vocabulary: [($m.vocab // "") | split(", ")[] | select(. != "") | unesc]}
        + ($m.screen | unesc | split_screen)
      end'
}

counts() {
  local input=$1 f; shift
  integer k=0
  for f; do jq -c --argjson k $((k++)) '.cfg = $k' $f; done | jq -nr --arg subset "$subset" --slurpfile in $input '
    def lists: [split("\n")[] | select(test("^\\s*([-*]|[0-9]+\\.) "))] | length > 0;
    def pct($p): if length == 0 then 0 else .[(length * $p | ceil) - 1] end;
    def r2: . * 100 | round / 100;
    ($in | map({key: .id, value: .transcript}) | from_entries) as $t
    | $ARGS.positional as $names
    | [inputs] as $all | [range($names | length) as $k | $all | map(select(.cfg == $k))] as $runs
    | ($runs[0] | map({key: .id, value: .output}) | from_entries) as $first
    | def raws: map(select(.label | contains("(raw)")) | .id);
      ($runs[0] | raws) as $firstRaw
    | def by($g): map(select(.rejectedBy == $g)) | length;
      ["config", "set", "n", "raw", "len", "content", "protect", "echo", "notext", "timeout", "stray", "empty", "diff", "raw+", "raw-", "mean", "p50", "p90"],
      ($runs | to_entries[] | .key as $k | .value
       | (["all", .], (if $subset == "" then empty else ["subset", map(select($t[.id] // "" | test($subset; "i")))] end))
       | .[1] as $r | ($r | map(.seconds) | sort) as $s
       | [$names[$k], .[0], ($r | length),
          ($r | map(select((.label | contains("(raw)")) and .reply != null)) | length),
          ($r | by("length")), ($r | by("dropsContent")), ($r | by("dropsProtected")), ($r | by("echoesContext")),
          ($r | by("empty")),
          ($r | map(select((.label | contains("(raw)")) and .reply == null)) | length),
          ($r | map(select((.output | lists) and ($t[.id] // "" | lists | not))) | length),
          ($r | map(select(.label == "Nothing" or (.output | test("^\\s*$")))) | length),
          ($r | map(select(.output != $first[.id])) | length),
          ($r | raws - $firstRaw | length), ($r | map(.id) - ($r | raws) | map(select(IN($firstRaw[]))) | length),
          (if $s == [] then 0 else $s | add / length | r2 end), ($s | pct(0.5) | r2), ($s | pct(0.9) | r2)])
    | @tsv' --args $names | column -t -s $'\t'
}

subset=""
names=()
if [[ ${1:-} == build ]]; then shift; build "$@"; exit; fi
if [[ ${1:-} == counts ]]; then
  shift; zparseopts -D -E -F -- -subset:=s || exit 1; subset=${s[-1]:-}
  names=(${@[2,-1]:t}); counts "$@"; exit
fi

zparseopts -D -E -F -- -model:=model -timeout:=timeout -subset:=s -history+:=hist || exit 1
model=${model[-1]:-mlx-community/gemma-4-e4b-it-4bit} timeout=${timeout[-1]:-4} subset=${s[-1]:-}
files=(${^${hist:#--history}}(:A))
(( $#files )) || files=(
  ~/Library/Application\ Support/Poptalk/history/history.jsonl(N)
  ~/Library/Mobile\ Documents/com~apple~CloudDocs/PopTalk/history/history-*.jsonl(N)
)
(( $#files )) || { print -u2 "No history files found."; exit 1 }
configs=()
for c in ${@:-current}; do
  [[ $c == current || -r $c ]] || { print -u2 "Can't read prompt file $c"; exit 1 }
  if [[ $c == current ]]; then configs+=(""); else configs+=(${c:A}); fi
  names+=${c:t}
done

cd "${0:A:h:h}"
mkdir -p .build
swift build -c release --product PoptalkBench > .build/replay-build.log 2>&1 || { print -u2 "Build failed: .build/replay-build.log"; exit 1 }
dir=$(mktemp -d "${TMPDIR:-/tmp}/poptalk-replay.XXXXXX")
trap 'rm -rf -- $dir' EXIT
build $files > $dir/all.jsonl
jq -c 'select(.skipped | not)' $dir/all.jsonl > $dir/in.jsonl
print "history files: $#files; dictations: $(jq -s length $dir/all.jsonl), replayed: $(jq -s length $dir/in.jsonl)"

outs=()
for c in "${configs[@]}"; do
  scripts/wait-idle.zsh
  outs+=$dir/out-$#outs.jsonl
  print "== ${names[$#outs]}"
  .build/release/PoptalkBench --replay $dir/in.jsonl $outs[-1] --cleanup-model $model --cleanup-timeout $timeout \
    ${c:+--dictation-prompt-file} $c
done
counts $dir/in.jsonl $outs
