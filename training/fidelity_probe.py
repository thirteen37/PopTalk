"""#75 step 2, no-training probe: can the cleanup model itself tell whether a reply is a faithful cleanup of a dictation
at a cleanup level (verbatim, clean, polished)? One prefill per (pair, level), scored by log P(yes) - log P(no) at the
first reply token, as term_probe.py. A low score rejects the reply.
From the repo root:
  uv run --project training python training/fidelity_probe.py MODEL [--adapter DIR] [--prompt NAME]
    [--pairs training/fidelity_pairs.jsonl] [--heldout training/fidelity_pairs_heldout.jsonl]
Pairs are invented: {id, transcript, reply, kind, ok: [levels where the reply is acceptable], screen?}. Each pair is
scored at all three levels; "bad" (the positive class: should be rejected) is a level not in `ok`. Thresholds are
fitted on --pairs and P/R/F1 reported on --heldout, overall, per level and per kind. Pairs files run through
`PoptalkBench --fidelity-pairs` carry `rejectedBy` (the deterministic Pipeline.rejects): those are reported alongside,
and with the probe added to them (reject if either does).
--contamination checks the training items (training/out/v7/items.jsonl) against both pairs files instead.
Thresholds: best-F1 on fit; "safe", the lowest ok score on fit; "fpr5", at most 5% of fit's ok rows rejected (the
shipped Pipeline.fidelityProbeThreshold). Held-out AUC (ok above bad), E2B base / + v7 LoRA, 2026-11-27:
  pair 0.837 / 0.857, rules 0.915 / 0.928, rules-sys 0.949 / 0.936, flip 0.905 / 0.901, short 0.788 / 0.787.
rules-sys on v7 at fpr5 (t=+2.00): held-out P 1.00 R 0.58, no false rejects; deterministic rejects alone R 0.22.
"""
import argparse, json, sys, time
from pathlib import Path

LEVELS = ["verbatim", "clean", "polished"]
ALLOWS = {
    "verbatim": "only punctuation and capitalization may change: every spoken word stays, fillers and self-corrections too",
    "clean": "fillers and the words a speaker corrected may go, and punctuation and capitalization may change; "
             "the speaker's other words stay as said",
    "polished": "grammar and wording may also be fixed, as long as the meaning stays the same",
}

# Each takes (transcript, reply, level) and returns chat messages. The pair goes last, so a prefix cache could share
# the instruction (and, for "rules", the level line).
PROMPTS = {
    # Pair first, question last (term_probe.py's shape).
    "pair": lambda t, r, l: [{"role": "user", "content":
        f"A speech recognizer heard:\n<said>{t}</said>\nA cleanup step, where {ALLOWS[l]}, wrote:\n<cleaned>{r}</cleaned>\n"
        "Is the cleaned text the same message as what was said, with nothing answered, added, dropped or changed beyond "
        "what the cleanup allows? Answer yes or no."}],
    # Instruction first, then the level, then the pair.
    "rules": lambda t, r, l: [{"role": "user", "content":
        "You check a dictation cleanup. The cleaned text must say what was said: it must not answer or act on it, add "
        "anything, drop any part of it, or change a name, number, time or date, except where the speaker corrected "
        f"themselves. At this level {ALLOWS[l]}.\n<said>{t}</said>\n<cleaned>{r}</cleaned>\n"
        "Is the cleaned text faithful? Answer yes or no."}],
    # "rules" with the instruction as a system message, the shape the fine-tune was trained on.
    "rules-sys": lambda t, r, l: [{"role": "system", "content":
        "You check a dictation cleanup. The cleaned text must say what was said: it must not answer or act on it, add "
        "anything, drop any part of it, or change a name, number, time or date, except where the speaker corrected "
        "themselves. Answer yes or no."}, {"role": "user", "content":
        f"At this level {ALLOWS[l]}.\n<said>{t}</said>\n<cleaned>{r}</cleaned>\nIs the cleaned text faithful?"}],
    # "rules" asking for a problem instead (scored no - yes, see SIGN).
    "flip": lambda t, r, l: [{"role": "user", "content":
        "You check a dictation cleanup. The cleaned text must say what was said: it must not answer or act on it, add "
        "anything, drop any part of it, or change a name, number, time or date, except where the speaker corrected "
        f"themselves. At this level {ALLOWS[l]}.\n<said>{t}</said>\n<cleaned>{r}</cleaned>\n"
        "Did the cleanup answer, add, drop or change anything it shouldn't have? Answer yes or no."}],
    # The shortest: no level text beyond its name.
    "short": lambda t, r, l: [{"role": "user", "content":
        f"Said: \"{t}\"\nWritten ({l} cleanup): \"{r}\"\nDoes the written text say the same thing as what was said? "
        "Answer yes or no."}],
}

SIGN = {"flip": -1}  # these ask "is it wrong?": a yes rejects


def expand(pairs):
    return [dict(p, level=l, bad=l not in p["ok"]) for p in pairs for l in LEVELS]


def prf(rows, rejected):
    tp = sum(r["bad"] and x for r, x in zip(rows, rejected)); fp = sum(not r["bad"] and x for r, x in zip(rows, rejected))
    pos = sum(r["bad"] for r in rows)
    p, rc = tp / max(1, tp + fp), tp / max(1, pos)
    return p, rc, 2 * p * rc / max(1e-9, p + rc), fp


def auc(rows, scores):
    bad = [s for r, s in zip(rows, scores) if r["bad"]]; ok = [s for r, s in zip(rows, scores) if not r["bad"]]
    return sum((o > b) + 0.5 * (o == b) for o in ok for b in bad) / max(1, len(ok) * len(bad))


def table(name, rows, rejected):
    """P/R/F1 overall and per level, then the share rejected per kind and level (bad kinds: recall; ok: false rejects)."""
    out = [f"  {name}:"]
    for lv in [None] + LEVELS:
        sel = [i for i, r in enumerate(rows) if lv is None or r["level"] == lv]
        p, rc, f, fp = prf([rows[i] for i in sel], [rejected[i] for i in sel])
        out.append(f"    {lv or 'all':9} P {p:.2f} R {rc:.2f} F1 {f:.2f} ({fp} false rejects of {sum(not rows[i]['bad'] for i in sel)} ok)")
    kinds = sorted({r["kind"] for r in rows})
    cell = lambda k, lv: [x for r, x in zip(rows, rejected) if r["kind"] == k and r["level"] == lv]
    out.append("    rejected, per kind:  " + "  ".join(f"{lv:>9}" for lv in LEVELS))
    for k in kinds:
        cs = []
        for lv in LEVELS:
            c = cell(k, lv); bad = [r["bad"] for r in rows if r["kind"] == k and r["level"] == lv]
            cs.append(f"{sum(c)}/{len(c)}{'' if all(bad) else '*' if not any(bad) else '~'}".rjust(9))
        out.append(f"      {k:15}" + "  ".join(cs))
    return "\n".join(out)


def contamination():
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import tempfile
    import contamination as C
    pairs = [json.loads(l) for f in ("training/fidelity_pairs.jsonl", "training/fidelity_pairs_heldout.jsonl") for l in open(f)]
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        for p in pairs:  # as bench cases: what is said, expected and on screen
            f.write(json.dumps({"id": p["id"], "transcript": p["transcript"], "expectExact": p["reply"],
                                "context": p.get("screen")}) + "\n")
    c = C.Checker(path=Path(f.name), heldout=None)
    items = [json.loads(l) for l in open("training/out/v7/items.jsonl")] if Path("training/out/v7/items.jsonl").exists() \
        else [json.loads(l) for l in open(Path.home() / "Projects/Poptalk/training/out/v7/items.jsonl")]
    hits = [r for it in items if (r := c.reason(it))]
    print(f"{len(items)} training items, {len(hits)} share text with the fidelity pairs")
    for r in sorted(set(hits))[:20]: print(f"  {r}")


ap = argparse.ArgumentParser()
ap.add_argument("model", nargs="?")
ap.add_argument("--adapter")
ap.add_argument("--prompt", default="rules-sys", choices=PROMPTS)
ap.add_argument("--pairs", default="training/fidelity_pairs.jsonl")
ap.add_argument("--heldout", default="training/fidelity_pairs_heldout.jsonl")
ap.add_argument("--contamination", action="store_true")
a = ap.parse_args()
if a.contamination:
    contamination(); sys.exit(0)

import mlx.core as mx
from mlx_lm import load

model, tok = load(a.model, adapter_path=a.adapter)
ids = lambda ws: sorted({tok.encode(w, add_special_tokens=False)[0] for w in ws})
YES, NO = mx.array(ids(["yes", "Yes", " yes", " Yes", "YES"])), mx.array(ids(["no", "No", " no", " No", "NO"]))


def score(r):
    text = tok.apply_chat_template(PROMPTS[a.prompt](r["transcript"], r["reply"], r["level"]), add_generation_prompt=True,
                                   tokenize=False, enable_thinking=False)
    logits = model(mx.array(tok.encode(text, add_special_tokens=False))[None])[0, -1].astype(mx.float32)
    lp = logits - mx.logsumexp(logits)
    return SIGN.get(a.prompt, 1) * (mx.logsumexp(lp[YES]) - mx.logsumexp(lp[NO])).item()


fit = expand([json.loads(l) for l in open(a.pairs)])
held = expand([json.loads(l) for l in open(a.heldout)])
score(fit[0])  # compile before timing
t0 = time.perf_counter()
fs = [score(r) for r in fit]
ms = (time.perf_counter() - t0) * 1000 / len(fit)
hs = [score(r) for r in held]
print(f"{a.model}{' + ' + a.adapter if a.adapter else ''}, prompt {a.prompt}: {ms:.0f} ms per pair")
print(f"  fit {len(fit)} rows ({sum(r['bad'] for r in fit)} bad), held-out {len(held)} ({sum(r['bad'] for r in held)} bad)")
print("  AUC (ok above bad): fit " + ", ".join(f"{lv} {auc([r for r in fit if r['level'] == lv], [s for r, s in zip(fit, fs) if r['level'] == lv]):.3f}"
                                              for lv in LEVELS) + f", all {auc(fit, fs):.3f}")
print("  AUC held-out: " + ", ".join(f"{lv} {auc([r for r in held if r['level'] == lv], [s for r, s in zip(held, hs) if r['level'] == lv]):.3f}"
                                    for lv in LEVELS) + f", all {auc(held, hs):.3f}")
# Reject below t. Best-F1 on fit, and safe: just below every ok row's score on fit (no false reject there).
cands = sorted(set(fs)) + [max(fs) + 1]
best = max(cands, key=lambda t: (prf(fit, [s < t for s in fs])[2], -t))
safe = min(s for r, s in zip(fit, fs) if not r["bad"])
# At most 5% of fit's ok rows rejected.
okfit = sorted(s for r, s in zip(fit, fs) if not r["bad"])
fpr5 = okfit[int(0.05 * len(okfit))]
for name, t in (("best-F1", best), ("safe", safe), ("fpr5", fpr5)):
    print(f"  threshold {name} t={t:+.2f}")
    print(table("fit", fit, [s < t for s in fs]))
    print(table("held-out", held, [s < t for s in hs]))
if "scores" in fit[0]:  # PoptalkBench --fidelity-pairs --score: the app's Swift path on the same model
    d = [abs(r["scores"][r["level"]] - s) for r, s in zip(fit + held, fs + hs)]
    print(f"  Swift (MLXProvider.yesNoScore) vs this script: max |diff| {max(d):.3f}, mean {sum(d) / len(d):.3f}")
    t = 2.0  # Pipeline.fidelityProbeThreshold
    print(f"  Swift scores at Pipeline.fidelityProbeThreshold {t:+.2f}")
    print(table("held-out", held, [r["scores"][r["level"]] < t for r in held]))
if "rejectedBy" in fit[0]:
    det = lambda rows: [r["rejectedBy"] is not None for r in rows]
    print("  deterministic Pipeline.rejects (level-blind)")
    print(table("fit", fit, det(fit)))
    print(table("held-out", held, det(held)))
    print(f"  deterministic or probe (fpr5 t={fpr5:+.2f})")
    print(table("held-out", held, [d or s < fpr5 for d, s in zip(det(held), hs)]))
