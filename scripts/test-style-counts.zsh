#!/usr/bin/env zsh
# Check for style-counts.zsh: runs it on invented history (split across two files, as when synced) and diffs counts.
set -euo pipefail
cd "${0:A:h}"
dir=$(mktemp -d "${TMPDIR:-/tmp}/style-counts.XXXXXX")
trap 'rm -rf -- $dir' EXIT

req() { print -r -- '{"type":"request","id":"'$1'","at":"'$2'","app":"'$3'","bundleID":"'$4'","action":"'$5'","text":'$6${7:+',"selection":'$7}'}' }
ev() { print -r -- '{"type":"'$1'","id":"'$2'","at":"'$3'"'${4:+',"by":"'$4'"'}${5:+',"text":'$5}'}' }
u() { print 00000000-0000-0000-0000-00000000000$1 }

{
  req $(u 1) 2026-11-25T10:00:00Z Chat com.example.chat insert '"Hello there"'
  ev typedCorrection $(u 1) 2026-11-25T10:00:05Z '' '"hello there"'                    # case, case1
  req $(u 2) 2026-11-25T10:01:00Z Chat com.example.chat insert '"See you soon."'
  req $(u 3) 2026-11-25T10:01:10Z Chat com.example.chat insert '"See you soon"'
  ev redictation $(u 2) 2026-11-25T10:01:10Z $(u 3)                                   # period
  req $(u 4) 2026-11-25T10:02:00Z Term com.example.terminal insert '"- run the build"'
  ev typedCorrection $(u 4) 2026-11-25T10:02:05Z '' '"run the build"'                 # list
  req $(u 5) 2026-11-25T10:03:00Z Notes com.example.notes insert '"the meeting is on monday"'
  req $(u 6) 2026-11-25T10:03:20Z Notes com.example.notes replace '"MONDAY"' '"monday"'
  ev correction $(u 5) 2026-11-25T10:03:20Z $(u 6)                                    # case
  ev undo $(u 5) 2026-11-25T10:03:30Z                                                 # not counted
  print 'not json'
} > $dir/history.jsonl
{
  req $(u 1) 2026-11-25T10:00:00Z Chat com.example.chat insert '"Hello there"'        # synced copy: deduped
  ev typedCorrection $(u 1) 2026-11-25T10:00:05Z '' '"hello there"'
  req $(u 7) 2026-11-25T10:04:00Z Notes com.example.notes insert '"we should get started now"'
  ev typedCorrection $(u 7) 2026-11-25T10:04:09Z '' '"we should begin now"'           # reword
  req $(u 8) 2026-11-25T10:05:00Z Notes com.example.notes insert '"buy milk"'
  ev typedCorrection $(u 8) 2026-11-25T10:05:09Z '' '"call the bank tomorrow"'        # other
  req $(u 9) 2026-11-20T09:00:00Z Mail com.example.mail insert '"thanks"'              # before --since
  ev typedCorrection $(u 9) 2026-11-20T09:00:09Z '' '"see you later"'
} > $dir/history-B.jsonl

counts() { zsh ./style-counts.zsh "$@" | sed -n '2,/^all/p' | awk '{$1=$1; print}' }
diff =(counts --since 2026-11-24 $dir/*.jsonl) - <<'EOF'
com.example.notes 4 3 1 0 0 0 1 1
com.example.chat 3 2 1 1 1 0 0 0
com.example.terminal 1 1 0 0 0 1 0 0
all 8 6 2 1 1 1 1 1
EOF
diff =(counts $dir/*.jsonl | rg '^(all|com.example.mail) ') - <<'EOF'
com.example.mail 1 1 0 0 0 0 0 1
all 9 7 2 1 1 1 1 2
EOF
print "style-counts: ok"
