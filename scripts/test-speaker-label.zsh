#!/usr/bin/env zsh
# Check for speaker-label.zsh: an invented history folder and review table, keys fed on stdin, a logging stub
# in place of afplay; checks the label files, resume, back, jump and --all.
set -euo pipefail
cd "${0:A:h}"
dir=$(mktemp -d "${TMPDIR:-/tmp}/speaker-label-test.XXXXXX")
trap 'rm -rf -- $dir' EXIT
export POPTALK_HISTORY_DIR=$dir/hist SPEAKER_LABEL_PLAYER=$dir/player
mkdir $POPTALK_HISTORY_DIR
print -r -- '#!/bin/sh
echo "${1##*/}" >> '$dir'/played' > $dir/player
chmod +x $dir/player

req() { jq -nc --arg id $1 --arg a "${2:-}" '{type: "request", id: $id, at: "2026-11-25T10:00:00Z", transcript: "secret",
  audio: (if $a == "" then null else $a end)}' }
{
  req AAA AAA.m4a; req BBB BBB.m4a; req CCC CCC.m4a; req DDD DDD.m4a; req EEE
  print 'not json'
  print '{"type": "wipe", "id": "x", "at": "2026-11-25T10:00:00Z"}'
} > $POPTALK_HISTORY_DIR/history.jsonl
for id in AAA BBB CCC DDD; do
  ffmpeg -v error -f lavfi -i sine=frequency=440:duration=3 -c:a aac $POPTALK_HISTORY_DIR/$id.m4a
done
# AAA, DDD, EEE pass the default filter; BBB scores too high, CCC is too short.
cat > $POPTALK_HISTORY_DIR/speaker-review.md <<'EOF'
# Speaker review (#128 spike)

| # | id | recorded | dur s | whole | min 1.5 s window | min 1.0 s window | low windows start at (s) |
|---|---|---|---|---|---|---|---|
| 1 | AAA | 2026-11-25 10:00:00 | 3.0 | 0.300 | 0.100 | 0.050 | 0.5, 1.5 |
| 2 | BBB | 2026-11-25 10:00:01 | 3.0 | 0.600 | 0.150 | 0.100 | 1.0 |
| 3 | CCC | 2026-11-25 10:00:02 | 1.5 | 0.400 | 0.200 | 0.150 | - |
| 4 | DDD | 2026-11-25 10:00:03 | 2.5 | 0.500 | 0.250 | 0.200 | - |
| 5 | EEE | 2026-11-25 10:00:04 | 4.0 | 0.450 | 0.300 | 0.250 | 2.0 |
EOF
print HAND > $POPTALK_HISTORY_DIR/speaker-labels.txt  # typed in by hand earlier; kept

# Keys arrive slowly, as typed, so each playback starts before the next key stops it.
keys() { sleep 1; for k in ${(s::)1}; do print -n $k; sleep 0.5; done }
run() { keys $1 | zsh ./speaker-label.zsh "${@:2}" }
labels() { cat $POPTALK_HISTORY_DIR/speaker-labels.txt }
answers() { sort $POPTALK_HISTORY_DIR/speaker-labels-done.tsv }

# AAA: replay, jump twice, yes. DDD: unknown key, no. EEE: back to DDD, yes, then quit at EEE.
out=$(run rjjyxnbyq)
[[ $out == *'1/3  #1  AAA  dur 3.0  whole 0.300  min1.5 0.100'* ]]
[[ $out == *'from 0.5 s'*'from 1.5 s'* ]]
[[ $out == *'(was n)'* ]]
[[ $out == *'answered 2, remaining 1 of 3, positives 3'* ]]
[[ $out != *secret* ]]
diff =(labels) - <<<$'AAA\nDDD\nHAND'
diff =(answers) - <<<$'AAA\ty\nDDD\ty'
diff $dir/played - <<<$'AAA.m4a\nAAA.m4a\nseek.wav\nseek.wav\nDDD.m4a\nDDD.m4a'
[[ $(stat -f %Lp $POPTALK_HISTORY_DIR/speaker-labels.txt $POPTALK_HISTORY_DIR/speaker-labels-done.tsv) == $'600\n600' ]]

# Resume: only EEE is left; it has no audio. EOF on stdin quits.
out=$(run n)
[[ $out == *'1/1  #5  EEE'*'(no audio file)'* && $out == *'answered 3, remaining 0 of 3, positives 3'* ]]
diff =(answers) - <<<$'AAA\ty\nDDD\ty\nEEE\tn'

# --all adds BBB and CCC.
out=$(run yn --all)
[[ $out == *'1/2  #2  BBB'*'2/2  #3  CCC'* && $out == *'answered 5, remaining 0 of 5, positives 4'* ]]
diff =(labels) - <<<$'AAA\nBBB\nDDD\nHAND'

[[ $(zsh ./speaker-label.zsh --help) == usage:* ]]
! zsh ./speaker-label.zsh --bogus 2>/dev/null
print "speaker-label: ok"
