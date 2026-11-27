#!/usr/bin/env zsh
# Check for fidelity-review.zsh: builds replay input from invented history and writes the review from an invented
# `--fidelity shadow` replay output.
set -euo pipefail
cd "${0:A:h}"
dir=$(mktemp -d "${TMPDIR:-/tmp}/fidelity-review-test.XXXXXX")
trap 'rm -rf -- $dir' EXIT

# req ID TRANSCRIPT [BUNDLE]
req() { jq -nc --arg id $1 --arg t $2 --arg b "${3:-}" '{type: "request", id: $id, at: "2026-11-25T10:00:0\($id)Z",
  bundleID: (if $b == "" then null else $b end), transcript: $t,
  messages: [{role: "user", content: "<screen app=\"App\($id)\" window=\"W\">\n\n</screen>\n<transcript>\($t)</transcript>"}]}' }
{
  req 1 'meet at three' com.example.chat
  req 2 'what time is it' com.example.mail
  req 3 'the fox & the hound' com.example.notes
  req 4 'send it now'
  req 5 'hello there'
  req 6 'call me later'
} > $dir/history.jsonl
zsh ./replay.zsh build $dir/history.jsonl | jq -c 'select(.skipped | not)' > $dir/in.jsonl

# out ID REPLY GUARD SCORE SECONDS PROBE_SECONDS: an empty REPLY is a timeout (no reply, not scored), an empty GUARD none.
out() { jq -nc --arg id $1 --arg r "$2" --arg g "$3" --argjson s $4 --argjson t $5 --argjson f $6 --arg u "$(jq -r --arg id $1 \
  'select(.id == $id) | "<screen app=\"\(.app)\" window=\"W\">\n\n</screen>\n<transcript>\(.transcript | gsub("&"; "&amp;"))</transcript>"' $dir/in.jsonl)" '
  {id: $id, label: "Dictated", output: $r, reply: (if $r == "" then null else $r end), user: $u,
   rejectedBy: (if $g == "" then null else $g end), repaired: [], seconds: $t}
  + (if $r == "" then {} else {fidelity: $s, fidelityRejects: ($s < 2), fidelitySeconds: $f} end)' }
{
  out 1 'Meet at four.' '' -3.5 0.4 0.06            # probe only
  out 2 'It is noon.' dropsContent -6.25 0.5 0.08   # both
  out 3 'The fox and the hound.' dropsContent 4 0.3 0.05  # guard only
  out 4 'Send it now.' '' 5 0.2 0.04                # neither
  out 5 '' '' 0 4.1 0                               # timeout
  out 6 'Call me.' '' 1.99 0.6 0.1                  # probe only
} > $dir/out.jsonl

diff =(zsh ./fidelity-review.zsh report $dir/in.jsonl $dir/out.jsonl $dir/review.md) =(print -r -- "replies: 5; probe rejects: 3 (with a guard 1, probe only 2); guard rejects the probe accepts: 1
probe ms p50 60, p90 100; dictation s p50 0.4, p90 4.1
written: $dir/review.md")
diff $dir/review.md - <<'EOF'
# Fidelity-probe review (#75)

Private: dictations from your opt-in history. **Delete this file after review.**

A `--fidelity shadow` replay of 5 replies: the probe (score below +2.0) would reject 3, 1 of them also rejected by a deterministic guard. The guards reject 1 more that the probe accepts. Is each a real failure?

## Probe rejects

### 1. com.example.chat: score -3.50, guard: none

**Transcript**

> meet at three

**Reply**

> Meet at four.

### 2. com.example.mail: score -6.25, guard: dropsContent

**Transcript**

> what time is it

**Reply**

> It is noon.

### 3. App6: score 1.99, guard: none

**Transcript**

> call me later

**Reply**

> Call me.

## Guard rejects the probe accepts

### 1. com.example.notes: score 4.00, guard: dropsContent

**Transcript**

> the fox & the hound

**Reply**

> The fox and the hound.
EOF
[[ $(stat -f %Lp $dir/review.md) == 600 ]]
print "fidelity-review: ok"
