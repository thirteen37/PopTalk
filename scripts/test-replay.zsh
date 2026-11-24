#!/usr/bin/env zsh
# Check for replay.zsh: builds replay input from invented history (split across two files, as when synced) and
# counts invented replay outputs for two configs.
set -euo pipefail
cd "${0:A:h}"
dir=$(mktemp -d "${TMPDIR:-/tmp}/replay-test.XXXXXX")
trap 'rm -rf -- $dir' EXIT

# req ID TRANSCRIPT USER-MESSAGE [SELECTION]
req() { jq -nc --arg id $1 --arg t $2 --arg u $3 --arg sel "${4:-}" '{type: "request", id: $id, at: "2026-11-25T10:00:0\($id[-1:])Z",
  transcript: $t, selection: (if $sel == "" then null else $sel end),
  messages: [{role: "system", content: "sys"}, {role: "user", content: $u}]}' }
long=${(l:3000::o:)${:-}}$'\n'${(l:3500::a:)${:-}}
{
  req 1 'hello there' $'<screen app="Chat" window="Say &quot;hi&quot; &amp; more">\na &lt;b&gt; c\n</screen>\n<vocabulary>Acme, Bo &amp; Co</vocabulary>\n<transcript>hello there</transcript>'
  req 2 'fix this' $'<screen app="Notes" window="N">\n\n</screen>\n<transcript>fix this</transcript>' 'selected'
  req 3 'old format' 'old format'
  print -r -- '{"type":"request","id":"4","at":"2026-11-25T10:00:04Z","transcript":"no model call"}'
  print 'not json'
} > $dir/history.jsonl
{
  req 1 'hello there' $'<screen app="Chat" window="dup">\n\n</screen>\n<transcript>hello there</transcript>'
  req 5 'scratch that buy eggs' $'<screen app="Mail" window="M">\n'$long$'\n</screen>\n<transcript>scratch that buy eggs</transcript>'
} > $dir/history-B.jsonl

zsh ./replay.zsh build $dir/history.jsonl $dir/history-B.jsonl > $dir/all.jsonl
diff =(jq -c '{id, skipped, app, window, vocabulary, ax: (.ax | length), ocr: (.ocr | length)}' $dir/all.jsonl) - <<'EOF'
{"id":"1","skipped":null,"app":"Chat","window":"Say \"hi\" & more","vocabulary":["Acme","Bo & Co"],"ax":7,"ocr":0}
{"id":null,"skipped":true,"app":null,"window":null,"vocabulary":null,"ax":0,"ocr":0}
{"id":"5","skipped":null,"app":"Mail","window":"M","vocabulary":[],"ax":3500,"ocr":3000}
EOF
diff =(jq -r 'select(.id == "1") | .ax' $dir/all.jsonl) =(print 'a <b> c')

jq -c 'select(.skipped | not)' $dir/all.jsonl > $dir/in.jsonl
out() { jq -nc --arg id $1 --arg l $2 --arg o $3 --argjson r $4 --argjson s $5 --arg g "${6:-}" \
  '{id: $id, label: $l, output: $o, reply: $r, seconds: $s, rejectedBy: (if $g == "" then null else $g end)}' }
{ out 1 Dictated 'Hello there.' '"x"' 1; out 5 'Dictated (raw)' 'scratch that buy eggs' null 3 } > $dir/a.jsonl
{ out 1 'Dictated (raw)' $'- Hello\n- there' '"x"' 2 dropsContent; out 5 Dictated 'Buy eggs.' '"x"' 4 } > $dir/b.jsonl
diff =(zsh ./replay.zsh counts --subset 'scratch that' $dir/in.jsonl $dir/a.jsonl $dir/b.jsonl | awk '{$1=$1; print}') - <<'EOF'
config set n raw len content protect echo notext timeout stray empty diff raw+ raw- mean p50 p90
a.jsonl all 2 0 0 0 0 0 0 1 0 0 0 0 0 2 1 3
a.jsonl subset 1 0 0 0 0 0 0 1 0 0 0 0 0 3 3 3
b.jsonl all 2 1 0 1 0 0 0 0 1 0 2 1 1 3 2 4
b.jsonl subset 1 0 0 0 0 0 0 0 0 0 1 0 1 4 4 4
EOF
print "replay: ok"
