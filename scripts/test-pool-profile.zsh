#!/usr/bin/env zsh
# Check for training/pool_profile.py: runs it on invented history (split across two files, as when synced) and an
# invented pool, and diffs the table.
set -euo pipefail
cd "${0:A:h}/.."
dir=$(mktemp -d "${TMPDIR:-/tmp}/pool-profile.XXXXXX")
trap 'rm -rf -- $dir' EXIT

# req ID TRANSCRIPT [SCREEN [VOCAB]]: a dictation; with SCREEN it called a model, so it has a recorded prompt.
req() {
  local msg=''
  (( $# >= 3 )) && msg=',"messages":[{"role":"system","content":"x"},{"role":"user","content":"<screen app=\"Notes\" window=\"w\">\n'$3'\n</screen>'${4:+'\n<vocabulary>'$4'</vocabulary>'}'\n<transcript>'$2'</transcript>"}]'
  print -r -- '{"type":"request","id":"'$1'","at":"2026-11-25T10:00:00Z","action":"insert","transcript":"'$2'"'$msg'}'
}
{
  req a1 'um I I think the kestrelbase sync is down' 'Status: the Kestrelbase sync is slow &amp; flaky.'
  req a2 'send it to the team. thanks.'
  print -r -- '{"type":"request","id":"a3","action":"replace","selection":"x","transcript":"make it shorter"}'
  print 'not json'
} > $dir/history.jsonl
{
  req a1 'um I I think the kestrelbase sync is down' 'Status: the Kestrelbase sync is slow &amp; flaky.'  # synced copy
  req a4 'scratch that, open wrenpad' '' 'Wrenpad, Fernloop'
} > $dir/history-B.jsonl
{
  print -r -- '{"id":"d-1","cat":"d-filler-text","transcript":"Uh, the roof leaks, like, again.","context":{"text":"Repair notes"},"target":"The roof leaks again."}'
  print -r -- '{"id":"e-1","cat":"e-replace","transcript":"make it shorter","selection":"x","target":"y"}'
} > $dir/pool.jsonl

diff =(./training/pool_profile.py --history $dir/history.jsonl --history $dir/history-B.jsonl $dir/pool.jsonl | sed 's/  */ /g') - <<'EOF'
 real pool
n (≈) 0 0
n prompt (≈) 0 0
words 1–5 33% 0%
words 6–15 67% 100%
words 16–40 0% 0%
words 41–100 0% 0%
words 100+ 0% 0%
sentence punctuation 33% 100%
all lowercase 67% 0%
fillers / 100 words 5.3 33.3
 um / 100 words 5.3 0.0
 uh / 100 words 0.0 16.7
 like / 100 words 0.0 16.7
 you know / 100 words 0.0 0.0
 basically / 100 words 0.0 0.0
 I mean / 100 words 0.0 0.0
prompt cue (no, sorry, actually…) 33% 0%
strong cue (no wait, I mean…) 33% 0%
cancel cue (#102) 33% 0%
repeated adjacent word 33% 0%
2+ sentences 33% 0%
any screen | prompt 50% 100%
 screen 1–500 chars 50% 100%
 screen 501–2000 chars 0% 0%
 screen 2001–4000 chars 0% 0%
 screen 4000+ chars 0% 0%
any vocabulary | prompt 50% 0%
screen term in transcript | screen 100% 0%
vocab term in transcript | vocab 100% -
EOF
print "pool-profile: ok"
