#!/usr/bin/env zsh
# Check for skipgate-review.zsh: builds replay input from invented history and writes the review from invented
# gate-off and gate-on replay outputs.
set -euo pipefail
cd "${0:A:h}"
dir=$(mktemp -d "${TMPDIR:-/tmp}/skipgate-review-test.XXXXXX")
trap 'rm -rf -- $dir' EXIT

# req ID TRANSCRIPT [BUNDLE]
req() { jq -nc --arg id $1 --arg t $2 --arg b "${3:-}" '{type: "request", id: $id, at: "2026-11-25T10:00:0\($id)Z",
  bundleID: (if $b == "" then null else $b end), transcript: $t,
  messages: [{role: "user", content: "<screen app=\"App\($id)\" window=\"W\">\n\n</screen>\n<transcript>\($t)</transcript>"}]}' }
{
  req 1 'hello there' com.example.chat
  req 2 'um see you tomorrow' com.example.mail
  req 3 'meet at the cafe' com.example.notes
  req 4 'send it now' com.example.chat
  req 5 'long one' com.example.chat
  req 6 'the red fox ran far away'
} > $dir/history.jsonl
zsh ./replay.zsh build $dir/history.jsonl | jq -c 'select(.skipped | not)' > $dir/in.jsonl

# out ID OUTPUT SKIPPED
out() { jq -nc --arg id $1 --arg o $2 --argjson s $3 '{id: $id, label: "Dictated", output: $o, repaired: [], seconds: 1, skippedLLM: $s}' }
{ out 1 'Hello there.' false; out 2 'See you tomorrow.' false; out 3 'Meet at the café.' false
  out 4 'Send it now, please.' false; out 5 'Something else.' false; out 6 'The red box ran away.' false } > $dir/off.jsonl
{ out 1 'hello, there' true; out 2 'Um, see you tomorrow.' true; out 3 'Meet at the cafe.' true
  out 4 'Send it now.' true; out 5 'Long one.' false; out 6 'The red fox ran far away.' true } > $dir/on.jsonl

diff =(zsh ./skipgate-review.zsh report $dir/in.jsonl $dir/off.jsonl $dir/on.jsonl $dir/review.md) =(print -r -- "skips: 5; entries: 4 (added 1, removed (first word only) 1, replaced 1, replaced+removed 1)
written: $dir/review.md")
diff $dir/review.md - <<'EOF'
# Skip-gate review (#120)

Private: dictations from your opt-in history. **Delete this file after review.**

4 of 5 skipped dictations insert different words from the model's (case and punctuation ignored). Did the model fix misheard words that the gate leaves in?

## 1. com.example.mail: removed (first word only)

**As heard (gate)**

> Um, see you tomorrow.

**Cleaned (model)**

> See you tomorrow.

**Differs:** removed `um`

## 2. com.example.notes: replaced

**As heard (gate)**

> Meet at the cafe.

**Cleaned (model)**

> Meet at the café.

**Differs:** `cafe` → `café`

## 3. com.example.chat: added

**As heard (gate)**

> Send it now.

**Cleaned (model)**

> Send it now, please.

**Differs:** added `please`

## 4. App6: replaced+removed

**As heard (gate)**

> The red fox ran far away.

**Cleaned (model)**

> The red box ran away.

**Differs:** `fox` → `box`; removed `far`
EOF
[[ $(stat -f %Lp $dir/review.md) == 600 ]]
print "skipgate-review: ok"
