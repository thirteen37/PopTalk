#!/usr/bin/env zsh
# Private review for the fidelity probe (#75 step 2): replays real history dictations once with the probe in shadow
# (E2B v7 by default, at Clean as recorded), then writes each reply the probe would reject, and each a deterministic
# guard rejects that the probe accepts, with its transcript, score and guard, to a Markdown file in the opt-in history
# folder for the owner to read. Run outside the sandbox. Prints counts, timings and the file's path only.
# Usage: scripts/fidelity-review.zsh [--model ID] [--timeout S] [--history FILE]... [--out FILE]
#   --history defaults to this Mac's file plus every Mac's synced file, --out to history/fidelity-review.md.
# Inputs and outputs are history content: they live in a private temp dir, deleted at exit, and are never printed.
# Internal, for scripts/test-fidelity-review.zsh: `fidelity-review.zsh report IN OUT FILE`.
set -euo pipefail
umask 077

report() {
  python3 -I - "$@" <<'PY'
import json, math, re, sys
inp, outp, path = sys.argv[1:]
ins = {r["id"]: r for r in map(json.loads, open(inp, encoding="utf-8"))}
outs = list(map(json.loads, open(outp, encoding="utf-8")))
threshold = 2.0  # Pipeline.fidelityProbeThreshold
quote = lambda s: "\n".join("> " + l for l in (s or "(empty)").split("\n"))
unesc = lambda s: s.replace("&quot;", '"').replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
def said(o):  # the pre-passed transcript the model and the probe saw
    m = re.findall(r"<transcript>(.*?)</transcript>", o.get("user") or "", re.S)
    return unesc(m[-1]) if m else ins.get(o["id"], {}).get("transcript", "")
def pct(xs, p): return sorted(xs)[math.ceil(len(xs) * p) - 1] if xs else 0
replies = [o for o in outs if o.get("reply") is not None]
guard = lambda o: o.get("rejectedBy") not in (None, "fidelityProbe")
probe = [o for o in replies if o.get("fidelityRejects") is True]
accepted = [o for o in replies if guard(o) and o.get("fidelityRejects") is False]
def entries(rows):
    for n, o in enumerate(rows, 1):
        r = ins.get(o["id"], {})
        yield (f"\n### {n}. {r.get('bundleID') or r.get('app', '?')}: score {o['fidelity']:.2f}, "
               f"guard: {o['rejectedBy'] if guard(o) else 'none'}\n\n**Transcript**\n\n{quote(said(o))}\n\n"
               f"**Reply**\n\n{quote(o['reply'])}\n")
both = sum(guard(o) for o in probe)
with open(path, "w", encoding="utf-8") as f:
    f.write("# Fidelity-probe review (#75)\n\nPrivate: dictations from your opt-in history. **Delete this file after review.**\n\n"
            f"A `--fidelity shadow` replay of {len(replies)} replies: the probe (score below +{threshold:.1f}) would reject "
            f"{len(probe)}, {both} of them also rejected by a deterministic guard. The guards reject {len(accepted)} more "
            "that the probe accepts. Is each a real failure?\n\n## Probe rejects\n")
    f.writelines(entries(probe))
    f.write("\n## Guard rejects the probe accepts\n")
    f.writelines(entries(accepted))
ms = [o["fidelitySeconds"] * 1000 for o in replies if o.get("fidelitySeconds") is not None]
secs = [o["seconds"] for o in outs]
print(f"replies: {len(replies)}; probe rejects: {len(probe)} (with a guard {both}, probe only {len(probe) - both}); "
      f"guard rejects the probe accepts: {len(accepted)}\n"
      f"probe ms p50 {pct(ms, 0.5):.0f}, p90 {pct(ms, 0.9):.0f}; dictation s p50 {pct(secs, 0.5):.2g}, p90 {pct(secs, 0.9):.2g}\n"
      f"written: {path}")
PY
}

if [[ ${1:-} == report ]]; then shift; report "$@"; exit; fi

zparseopts -D -E -F -- -model:=model -timeout:=timeout -history+:=hist -out:=o || exit 1
model=${model[-1]:-adapters/gemma-4-e2b-poptalk-v7} timeout=${timeout[-1]:-4}
out=${${o[-1]:-$HOME/Library/Application Support/Poptalk/history/fidelity-review.md}:A}
files=(${^${hist:#--history}}(:A))
(( $#files )) || files=(
  ~/Library/Application\ Support/Poptalk/history/history.jsonl(N)
  ~/Library/Mobile\ Documents/com~apple~CloudDocs/PopTalk/history/history-*.jsonl(N)
)
(( $#files )) || { print -u2 "No history files found."; exit 1 }

cd "${0:A:h:h}"
mkdir -p .build
swift build -c release --product PoptalkBench > .build/replay-build.log 2>&1 || { print -u2 "Build failed: .build/replay-build.log"; exit 1 }
dir=$(mktemp -d "${TMPDIR:-/tmp}/poptalk-fidelity.XXXXXX")
trap 'rm -rf -- $dir' EXIT
zsh scripts/replay.zsh build $files | jq -c 'select(.skipped | not)' > $dir/in.jsonl
scripts/wait-idle.zsh >&2
.build/release/PoptalkBench --replay $dir/in.jsonl $dir/out.jsonl --cleanup-model $model --cleanup-timeout $timeout --fidelity shadow >&2
report $dir/in.jsonl $dir/out.jsonl $out
