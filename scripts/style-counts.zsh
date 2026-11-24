#!/usr/bin/env zsh
# Counts-only look at opt-in history for #96's evidence plan: buckets each correction, typed correction and
# redictation by the corrected request's app. Prints counts and rates per bundle ID (else app name), never text.
# Usage: style-counts.zsh [--since DATE] [history.jsonl ...]
#   (defaults: this Mac's history plus every Mac's synced file; DATE is UTC, e.g. 2026-11-24 or 2026-11-24T12:00)
# Pairs: typed correction = inserted text vs the user's version; correction = the voice edit's selection vs its
# replacement; redictation = the first take's text vs the second's. Columns (an event can count in several of
# case, period and list):
#   case    only the casing changed (trailing period and list markers aside); case1: just the first letter
#   period  only a trailing period added or removed (casing and list markers aside)
#   list    list markers added or removed (number of lines starting with -, *, • or 1. / 1) changed)
#   reword  other wording change, words still ≥ 60% alike (the "same meaning" bucket; noisy)
#   other   everything else, including identical text and a second take that inserted nothing
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
  def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
  def marker: "^\\s*([-*•]|[0-9]+[.)])\\s+";
  def markers: [split("\n")[] | select(test(marker))] | length;
  def plain: [split("\n")[] | sub(marker; "")] | join(" ") | gsub("\\s+"; " ") | trim | sub("\\.$"; "");
  def words: ascii_downcase | [splits("[^\\p{L}\\p{N}'"'"']+") | select(. != "")];
  # 2 × in-order matched words / total words, as Redictation.similarity.
  def similarity($a; $b):
    ($a | words) as $x | ($b | words) as $y
    | if ($x | length) == 0 or ($y | length) == 0 then 0 else
        (reduce $x[] as $w ([range(0; ($y | length) + 1) | 0];
           . as $p | reduce range(0; $y | length) as $j ([0];
             . + [if $w == $y[$j] then $p[$j] + 1 else ([.[$j], $p[$j + 1]] | max) end]))
         | .[-1]) * 2 / (($x | length) + ($y | length))
      end;
  def buckets($a; $b):
    ($a // "" | trim) as $a | ($b // "" | trim) as $b
    | ($a | plain) as $pa | ($b | plain) as $pb
    | {list: (($a | markers) != ($b | markers))}
    | if $a != $b and ($pa | ascii_downcase) == ($pb | ascii_downcase) then
        .case = ($pa != $pb) | .case1 = (.case and $pa[1:] == $pb[1:])
        | .period = (($a | endswith(".")) != ($b | endswith(".")))
        | .other = (.case or .period or .list | not)
      elif .list then .
      elif $a != $b and similarity($a; $b) >= 0.6 then .reword = true
      else .other = true end;

  [inputs | fromjson? | select(type == "object" and (.at | type) == "string" and .at >= $since)]
  | (map(select(.type == "request")) | unique_by(.id) | INDEX(.id)) as $req
  | (map(select(.type == ("correction", "typedCorrection", "redictation")) | {type, id, at, by, text})
     | unique | map(select($req[.id]))) as $events
  | def app: .bundleID // .app;
    ($req | map(app) | group_by(.) | map({key: .[0], value: length}) | from_entries) as $requests
  | ($events | map($req[.id] as $r | $req[.by // ""] as $by
      | {app: ($r | app)} + if .type == "typedCorrection" then buckets($r.text; .text)
        elif .type == "correction" then buckets($by.selection; $by.text)
        else buckets($r.text; $by.text) end)) as $rows
  | ["case", "case1", "period", "list", "reword", "other"] as $cols
  | def counts($app): ($rows | map(select($app == null or .app == $app))) as $r
      | [($requests | if $app then .[$app] else add // 0 end), ($r | length)]
        + [$cols[] as $c | $r | map(select(.[$c])) | length];
    def rates: .[0] as $n | [.[0], (.[1:][] | if $n > 0 then (. * 1000 / $n | round / 10 | tostring) + "%" else "-" end)];
    ($requests | to_entries | sort_by(-.value, .key) | map(.key)) as $apps
  | ["app", "requests", "events"] + $cols,
    ($apps[] | [.] + counts(.)), (["all"] + counts(null)),
    ["% of requests", "requests", "events"] + $cols,
    ($apps[] | [.] + (counts(.) | rates)), (["all"] + (counts(null) | rates))
  | @tsv' | column -t -s $'\t'
