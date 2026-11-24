#!/usr/bin/env zsh
# Check for selfcorrect-counts.zsh: runs it on invented history (split across two files, as when synced) and diffs counts.
set -euo pipefail
cd "${0:A:h}"
dir=$(mktemp -d "${TMPDIR:-/tmp}/selfcorrect-counts.XXXXXX")
trap 'rm -rf -- $dir' EXIT

# req ID AT RAW TEXT [ACTION SELECTION]
req() { print -r -- '{"type":"request","id":"'$1'","at":"'$2'","app":"Notes","bundleID":"com.example.notes","rawTranscript":"'$3'","transcript":"'$3'","action":"'${5:-insert}'","text":"'$4'"'${6:+',"selection":"'$6'"'}'}' }
ev() { print -r -- '{"type":"'$1'","id":"'$2'","at":"'$3'"'${4:+',"by":"'$4'"'}'}' }
u() { print 00000000-0000-0000-0000-00000000000$1 }

{
  req $(u 1) 2026-11-25T10:00:00Z 'meet at two, no, wait, three' 'Meet at three.'
  ev undo $(u 1) 2026-11-25T10:00:05Z                                               # cue: no wait, dropped
  req $(u 2) 2026-11-25T10:01:00Z 'sorry i actually meant five' 'Sorry, I actually meant five.'
  ev typedCorrection $(u 2) 2026-11-25T10:01:09Z                                    # cues: actually, sorry, both kept
  req $(u 3) 2026-11-25T10:02:00Z 'buy milk' 'Buy milk.'
  req $(u 4) 2026-11-25T10:02:10Z 'buy milk please' 'Buy milk, please.'
  ev redictation $(u 3) 2026-11-25T10:02:10Z $(u 4)                                 # no cue
  req $(u 5) 2026-11-25T10:02:30Z 'scratch that' 'Buy bread.' replace 'Buy milk.'   # an edit: not a dictation
  ev correction $(u 3) 2026-11-25T10:02:30Z $(u 5)
  print 'not json'
} > $dir/history.jsonl
{
  req $(u 1) 2026-11-25T10:00:00Z 'meet at two, no, wait, three' 'Meet at three.'  # synced copy: deduped
  ev undo $(u 1) 2026-11-25T10:00:05Z
  req $(u 6) 2026-11-25T10:03:00Z 'Tell them yes. Scratch that. Ask them.' 'Ask them.'  # cue: scratch that, dropped
  req $(u 7) 2026-11-25T10:04:00Z 'i meant the blue one' 'I meant the blue one.'   # "meant" is not "i mean"
  req $(u 8) 2026-11-20T09:00:00Z "i'd rather walk" "I'd rather walk."             # before --since; rather, kept
  ev undo $(u 8) 2026-11-20T09:00:05Z
} > $dir/history-B.jsonl

counts() { zsh ./selfcorrect-counts.zsh "$@" | awk '{$1=$1; print}' }
diff =(counts --since 2026-11-24 $dir/*.jsonl) - <<'EOF'
cue dictations % of all kept % kept
no wait 1 16.7% 0 0%
actually 1 16.7% 1 100%
sorry 1 16.7% 1 100%
scratch that 1 16.7% 0 0%
i mean 0 0% 0 -
rather 0 0% 0 -
make that 0 0% 0 -
instead 0 0% 0 -
never mind 0 0% 0 -
any cue 3 50% 1 33.3%
group dictations undo typedCorrection correction redictation
cue 3 1 1 0 0
no cue 3 0 0 1 1
all 6 1 1 1 1
% of group dictations undo typedCorrection correction redictation
cue 3 33.3% 33.3% 0% 0%
no cue 3 0% 0% 33.3% 33.3%
all 6 16.7% 16.7% 16.7% 16.7%
EOF
diff =(counts $dir/*.jsonl | rg '^(rather|any cue|cue|all) [0-9]') - <<'EOF'
rather 1 14.3% 1 100%
any cue 4 57.1% 2 50%
cue 4 2 1 0 0
all 7 2 1 1 1
cue 4 50% 25% 0% 0%
all 7 28.6% 14.3% 14.3% 14.3%
EOF
print "selfcorrect-counts: ok"
