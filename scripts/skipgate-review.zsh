#!/usr/bin/env zsh
# Private review for the skip gate (#120): replays real history dictations with the gate off, then on (E2B v6 by
# default), and for each dictation the gate skipped whose words differ from the model's insert (case and punctuation
# ignored), writes both inserts to a Markdown file in the opt-in history folder for the owner to read.
# Run outside the sandbox. Prints counts and the file's path only.
# Usage: scripts/skipgate-review.zsh [--model ID] [--timeout S] [--history FILE]... [--out FILE]
#   --history defaults to this Mac's file plus every Mac's synced file, --out to history/skipgate-review.md.
# Inputs and outputs are history content: they live in a private temp dir, deleted at exit, and are never printed.
# Internal, for scripts/test-skipgate-review.zsh: `skipgate-review.zsh report IN OFF ON OUT`.
set -euo pipefail
umask 077

report() {
  python3 -I - "$@" <<'PY'
import collections, difflib, json, re, sys
inp, off, on, out = sys.argv[1:]
load = lambda p: {r["id"]: r for r in map(json.loads, open(p, encoding="utf-8"))}
ins, offs, ons = load(inp), load(off), load(on)
words = lambda s: [re.sub(r"['’]", "", w) for w in re.findall(r"\w+(?:['’]\w+)*", s.casefold())]
quote = lambda s: "\n".join("> " + l for l in (s or "(empty)").split("\n"))
names = {"replace": "replaced", "delete": "removed", "insert": "added"}
skips, entries = 0, []
for id, r in ins.items():
    g, m = ons.get(id), offs.get(id)
    if not (g and m and g.get("skippedLLM")): continue
    skips += 1
    a, b = words(g["output"]), words(m["output"])
    if a == b: continue
    ops = [o for o in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes() if o[0] != "equal"]
    kind = "+".join(names[k] for k in names if any(o[0] == k for o in ops))
    if all(i2 <= 1 and j2 <= 1 for _, _, i2, _, j2 in ops): kind += " (first word only)"
    diffs = []
    for t, i1, i2, j1, j2 in ops:
        x, y = " ".join(a[i1:i2]), " ".join(b[j1:j2])
        diffs.append({"replace": f"`{x}` → `{y}`", "delete": f"removed `{x}`", "insert": f"added `{y}`"}[t])
    entries.append((r.get("bundleID") or r["app"], kind, g["output"], m["output"], diffs))
kinds = collections.Counter(e[1] for e in entries)
with open(out, "w", encoding="utf-8") as f:
    f.write("# Skip-gate review (#120)\n\nPrivate: dictations from your opt-in history. **Delete this file after review.**\n\n"
            f"{len(entries)} of {skips} skipped dictations insert different words from the model's (case and punctuation ignored). "
            "Did the model fix misheard words that the gate leaves in?\n")
    for n, (app, kind, gate, model, diffs) in enumerate(entries, 1):
        f.write(f"\n## {n}. {app}: {kind}\n\n**As heard (gate)**\n\n{quote(gate)}\n\n**Cleaned (model)**\n\n{quote(model)}\n\n"
                f"**Differs:** {'; '.join(diffs)}\n")
print(f"skips: {skips}; entries: {len(entries)} ("
      + ", ".join(f"{k} {c}" for k, c in sorted(kinds.items(), key=lambda kc: (-kc[1], kc[0]))) + f")\nwritten: {out}")
PY
}

if [[ ${1:-} == report ]]; then shift; report "$@"; exit; fi

zparseopts -D -E -F -- -model:=model -timeout:=timeout -history+:=hist -out:=o || exit 1
model=${model[-1]:-adapters/gemma-4-e2b-poptalk-v6} timeout=${timeout[-1]:-4}
out=${${o[-1]:-$HOME/Library/Application Support/Poptalk/history/skipgate-review.md}:A}
files=(${^${hist:#--history}}(:A))
(( $#files )) || files=(
  ~/Library/Application\ Support/Poptalk/history/history.jsonl(N)
  ~/Library/Mobile\ Documents/com~apple~CloudDocs/PopTalk/history/history-*.jsonl(N)
)
(( $#files )) || { print -u2 "No history files found."; exit 1 }

cd "${0:A:h:h}"
mkdir -p .build
swift build -c release --product PoptalkBench > .build/replay-build.log 2>&1 || { print -u2 "Build failed: .build/replay-build.log"; exit 1 }
dir=$(mktemp -d "${TMPDIR:-/tmp}/poptalk-skipgate.XXXXXX")
trap 'rm -rf -- $dir' EXIT
zsh scripts/replay.zsh build $files | jq -c 'select(.skipped | not)' > $dir/in.jsonl
for g in off on; do
  scripts/wait-idle.zsh >&2
  print -u2 "== skip gate $g"
  .build/release/PoptalkBench --replay $dir/in.jsonl $dir/$g.jsonl --cleanup-model $model --cleanup-timeout $timeout --skip-gate $g >&2
done
report $dir/in.jsonl $dir/off.jsonl $dir/on.jsonl $out
