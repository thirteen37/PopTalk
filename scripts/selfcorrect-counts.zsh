#!/usr/bin/env zsh
# Counts-only look at opt-in history for #98: how many dictations carry a self-correction cue, whether the cue
# survives into the inserted text, and how cue dictations fare against the rest. Prints counts and rates, never text.
# Usage: selfcorrect-counts.zsh [--since DATE] [history.jsonl ...]
#   (defaults: this Mac's history plus every Mac's synced file; DATE is UTC, e.g. 2026-11-24 or 2026-11-24T12:00)
# A dictation is an insert with no selection. Cues are matched case-insensitively as whole words in Parakeet's raw
# transcript ("no, wait" counts as "no wait"; "I meant" is not "I mean"); "kept": the same cue is in the inserted
# text. Second table: dictations with at least one undo, typed correction, voice correction (`correction`) or
# redictation, cue dictations against the rest.
set -euo pipefail
zparseopts -D -E -F -- -since:=since || exit 1
since=${since[-1]:-}
files=("$@")
(( $#files )) || files=(
  ~/Library/Application\ Support/Poptalk/history/history.jsonl(N)
  ~/Library/Mobile\ Documents/com~apple~CloudDocs/PopTalk/history/history-*.jsonl(N)
)
(( $#files )) || { print -u2 "No history files found."; exit 1 }

cat -- $files | jq -nrR --arg since "$since" '
  ["no wait", "actually", "sorry", "scratch that", "i mean", "rather", "make that", "instead", "never mind"] as $cues
  | def has($c): test("\\b" + ($c | gsub(" "; "\\W+")) + "\\b"; "i");
    def pct($a; $b): if $b > 0 then ($a * 1000 / $b | round / 10 | tostring) + "%" else "-" end;
  [inputs | fromjson? | select(type == "object" and (.at | type) == "string" and .at >= $since)]
  | (map(select(.type == ("undo", "typedCorrection", "correction", "redictation")) | {type, id}) | unique
     | group_by(.id) | map({key: .[0].id, value: map(.type)}) | from_entries) as $events
  | [map(select(.type == "request" and .action == "insert" and (.selection // "") == "")) | unique_by(.id)[]
     | (.rawTranscript // .transcript // "") as $said | (.text // "") as $text
     | {cues: [$cues[] as $c | select($said | has($c)) | $c], events: ($events[.id] // [])}
     | .kept = [.cues[] as $c | select($text | has($c)) | $c]] as $rows
  | ($rows | length) as $n
  | ["cue", "dictations", "% of all", "kept", "% kept"],
    (($cues[] as $c | [$c, ($rows | map(select(any(.cues[]; . == $c))) | length),
                           ($rows | map(select(any(.kept[]; . == $c))) | length)]),
     ["any cue", ($rows | map(select(.cues != [])) | length), ($rows | map(select(.kept != [])) | length)]
     | [.[0], .[1], pct(.[1]; $n), .[2], pct(.[2]; .[1])]),
    (["undo", "typedCorrection", "correction", "redictation"] as $types
     | [["cue", ($rows | map(select(.cues != [])))], ["no cue", ($rows | map(select(.cues == [])))], ["all", $rows]]
     | map([.[0], (.[1] | length)] + [$types[] as $t | .[1] | map(select(any(.events[]; . == $t))) | length]) as $counts
     | ["group", "dictations"] + $types, $counts[],
       ["% of group", "dictations"] + $types, ($counts[] | .[1] as $d | [.[0], $d] + [.[2:][] | pct(.; $d)]))
  | @tsv' | column -t -s $'\t'
