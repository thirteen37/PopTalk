#!/usr/bin/env zsh
# Labels history recordings for the speaker-verification spike (#128): plays each recording in the private
# speaker-review.md and takes one key per recording. Prints ids and scores only, never history text.
set -uo pipefail
setopt no_bg_nice

usage() {
  print -r -- "usage: ${0:t} [--all]

Plays the recordings listed in speaker-review.md (most suspicious first) and asks, per recording, whether
someone else is talking in the background (a person, a call, a video).

  --all    every row (default: whole < 0.54 and dur >= 2.0 s)

Keys (any key stops playback first):
  y  background speaker      n  none
  r  replay                  j  play from the next low window (needs ffmpeg)
  b  back one                q  quit

Saved after every answer, so quit and run again to resume:
  speaker-labels.txt         the y ids, one per line (read by the spike's analyze.py)
  speaker-labels-done.tsv    id<TAB>y|n, answered rows are skipped on resume

Files live in \$POPTALK_HISTORY_DIR (default ~/Library/Application Support/Poptalk/history).
\$SPEAKER_LABEL_PLAYER replaces afplay (for tests)."
}

all=0
for a in "$@"; do
  case $a in
    --all) all=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

hist=${POPTALK_HISTORY_DIR:-$HOME/Library/Application Support/Poptalk/history}
player=${SPEAKER_LABEL_PLAYER:-afplay}
review=$hist/speaker-review.md labels=$hist/speaker-labels.txt answers=$hist/speaker-labels-done.tsv
[[ -r $review ]] || { print -u2 "no review file: $review"; exit 1 }
[[ -r $hist/history.jsonl ]] || { print -u2 "no history: $hist/history.jsonl"; exit 1 }
umask 077
tmp=$(mktemp -d "${TMPDIR:-/tmp}/speaker-label.XXXXXX")
pid=0
stop() { (( pid )) && kill $pid 2>/dev/null; pid=0 }
trap 'stop; rm -rf -- $tmp' EXIT

# id -> audio path; only the id and audio fields leave jq.
typeset -A audio
while IFS=$'\t' read -r id f; do audio[$id]=$hist/$f; done < <(
  jq -rR 'fromjson? | select(.type == "request" and .audio != null) | [.id, .audio] | @tsv' $hist/history.jsonl)

# Earlier answers, and positives (keeps ids typed into speaker-labels.txt by hand).
typeset -A ans pos
[[ -r $answers ]] && while IFS=$'\t' read -r id v; do [[ -n $id ]] && ans[$id]=$v; done < $answers
[[ -r $labels ]] && while IFS= read -r id; do [[ -n $id ]] && pos[$id]=1; done < $labels

save() {
  print -l -- ${(ko)pos} > $labels.tmp && mv -f $labels.tmp $labels
  for id v in ${(kv)ans}; do print -r -- "$id"$'\t'"$v"; done > $answers.tmp && mv -f $answers.tmp $answers
}

# Review rows: | # | id | recorded | dur s | whole | min 1.5 s window | min 1.0 s window | low windows start at (s) |
rows=() sel=0
while IFS= read -r line; do
  [[ $line == '| '[0-9]* ]] || continue
  f=("${(@s:|:)line}")
  rank=${f[2]// /} id=${f[3]// /} dur=${f[5]// /} whole=${f[6]// /} w15=${f[7]// /} lows=${f[9]// /}
  (( all || (whole < 0.54 && dur >= 2.0) )) || continue
  (( sel++ ))
  [[ -n ${ans[$id]:-} ]] && continue
  rows+=("$rank $id $dur $whole $w15 ${lows//,/ }")
done < $review

play() {
  stop
  [[ -f $1 ]] || { print "  (no audio file)"; return }
  $player "$1" &>/dev/null &
  pid=$!
}

i=1 total=${#rows}
while (( i <= total )); do
  r=(${=rows[i]}); id=$r[2] lows=(${r[6,-1]:#-}) jump=0
  print "\n$i/$total  #$r[1]  $id  dur $r[3]  whole $r[4]  min1.5 $r[5]${ans[$id]:+  (was ${ans[$id]})}"
  play "${audio[$id]:-}"
  while true; do
    print -n "  [y]es speaker  [n]o  [r]eplay  [j]ump  [b]ack  [q]uit: "
    if [[ -t 0 ]]; then read -k1 key; else read -u0 -k1 key; fi || key=q  # -u0 on a tty waits for Enter
    print
    stop
    case $key in
      y) ans[$id]=y pos[$id]=1; save; (( i++ )); break ;;
      n) ans[$id]=n; unset "pos[$id]"; save; (( i++ )); break ;;
      r) play "${audio[$id]:-}" ;;
      j) if (( ! ${#lows} )); then print "  (no low windows)"
         elif ! (( $+commands[ffmpeg] )); then print "  (jump needs ffmpeg)"
         else
           t=$lows[$(( jump % ${#lows} + 1 ))]; (( jump++ ))
           print "  from ${t} s"
           ffmpeg -v error -y -ss $t -i ${audio[$id]:-/nonexistent} $tmp/seek.wav 2>/dev/null \
             && play $tmp/seek.wav || print "  (could not cut audio)"
         fi ;;
      b) (( i > 1 )) && (( i-- )); break ;;
      q) i=$(( total + 1 )); break ;;
    esac
  done
done

left=0
for row in $rows; do r=(${=row}); [[ -z ${ans[$r[2]]:-} ]] && (( left++ )); done
print "\nanswered ${#ans}, remaining $left of $sel, positives ${#pos}"
