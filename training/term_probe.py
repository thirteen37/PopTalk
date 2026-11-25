"""#75 step 2, no-training probe: can the cleanup model itself tell a sound-alike mishearing of a screen term?
One prefill per pair of "Is '<heard>' the term '<term>'?", scored by the yes-minus-no logit at the first reply token.
From the repo root:
  uv run --project training python training/term_probe.py MODEL [--adapter DIR] [--pairs training/term_pairs.jsonl]
    [--heldout training/term_pairs_heldout.jsonl] [--cache]
Prints AUC, the best-F1 threshold's precision/recall, accuracy at 0, and milliseconds per pair. The pairs are invented.
With --heldout, thresholds are fitted on --pairs and P/R/F1 reported on the held-out pairs. Pairs files run through
`PoptalkBench --term-shortlist` carry `candidate` (the shortlist's run, or null): those are also scored with the
shortlist in front, a dropped pair counting as "no".
--cache prefills the prompt head every pair shares (chat template, "A speech recognizer heard '") once and reuses
its KV cache per pair. An instruction-first prompt (more to share) scored far worse: AUC 0.84 held-out on E2B base.
"""
import argparse, json, time

import mlx.core as mx
from mlx_lm import load
from mlx_lm.models.cache import make_prompt_cache

ap = argparse.ArgumentParser()
ap.add_argument("model")
ap.add_argument("--adapter")
ap.add_argument("--pairs", default="training/term_pairs.jsonl")
ap.add_argument("--heldout")
ap.add_argument("--cache", action="store_true")
a = ap.parse_args()
model, tok = load(a.model, adapter_path=a.adapter)


def ids(words):
    """First token of each spelling, so " Yes" and "yes" both count."""
    return sorted({tok.encode(w, add_special_tokens=False)[0] for w in words})


YES, NO = mx.array(ids(["yes", "Yes", " yes", " Yes", "YES"])), mx.array(ids(["no", "No", " no", " No", "NO"]))


def prompt(heard, term):
    msg = (f"A speech recognizer heard '{heard}'. Is that the term '{term}' (the same word or name, "
           f"misheard or split up)? Answer yes or no.")
    return tok.apply_chat_template([{"role": "user", "content": msg}], add_generation_prompt=True, tokenize=False,
                                   enable_thinking=False)  # as the app sends it (MLXProvider)


def yes_no(logits):
    logits = logits.astype(mx.float32)
    lp = logits - mx.logsumexp(logits)
    return (mx.logsumexp(lp[YES]) - mx.logsumexp(lp[NO])).item()


def score(heard, term):
    x = mx.array(tok.encode(prompt(heard, term), add_special_tokens=False))[None]
    return yes_no(model(x)[0, -1])


# The prompt's shared head, prefilled once (--cache): each pair then prefills only its own tail.
x, y = (tok.encode(prompt(h, "Term"), add_special_tokens=False) for h in ("alpha", "zulu"))
head = x[:next(i for i, (u, v) in enumerate(zip(x, y)) if u != v)]
cache = None


def score_cached(heard, term):
    global cache
    full = tok.encode(prompt(heard, term), add_special_tokens=False)
    assert full[:len(head)] == head
    if cache is None:
        cache = make_prompt_cache(model)
        model(mx.array(head)[None], cache=cache)
        mx.eval([c.state for c in cache])
    tail = full[len(head):]
    s = yes_no(model(mx.array(tail)[None], cache=cache)[0, -1])
    for c in cache: c.trim(len(tail))
    return s


def run(pairs, fn):
    t0 = time.perf_counter()
    out = [fn(p["heard"], p["term"]) for p in pairs]
    return out, (time.perf_counter() - t0) * 1000 / len(pairs)


def prf(scores, pairs, t, shortlist=False):
    yes = [s >= t and (not shortlist or p.get("candidate") is not None) for s, p in zip(scores, pairs)]
    tp = sum(y and p["match"] for y, p in zip(yes, pairs)); fp = sum(y and not p["match"] for y, p in zip(yes, pairs))
    pos = sum(p["match"] for p in pairs)
    prec, rec = tp / max(1, tp + fp), tp / pos
    return prec, rec, 2 * prec * rec / max(1e-9, prec + rec), fp


def fit(scores, pairs, shortlist=False):
    """Best-F1 threshold, and the strict one: the lowest with precision 1 (just above every scored non-match)."""
    best = max(sorted(set(scores)), key=lambda t: (prf(scores, pairs, t, shortlist)[2], -t))
    negs = [s for s, p in zip(scores, pairs) if not p["match"] and (not shortlist or p.get("candidate") is not None)]
    return best, (max(negs) + 1e-3 if negs else min(scores))


def report(name, scores, pairs):
    pos = [s for s, p in zip(scores, pairs) if p["match"]]
    neg = [s for s, p in zip(scores, pairs) if not p["match"]]
    AUC = lambda ps, ns: sum((x > y) + 0.5 * (x == y) for x in ps for y in ns) / (len(ps) * len(ns))
    near = [s for s, p in zip(scores, pairs) if p["kind"] == "near-miss"]
    print(f"  {name}: {len(pairs)} pairs ({len(pos)} match), AUC {AUC(pos, neg):.3f} (vs near-misses {AUC(pos, near):.3f})")


cal = [json.loads(l) for l in open(a.pairs)]
held = [json.loads(l) for l in open(a.heldout)] if a.heldout else []
fn = score_cached if a.cache else score
score(cal[0]["heard"], cal[0]["term"]); fn(cal[0]["heard"], cal[0]["term"])  # compile and load before timing
cs, ms_cal = run(cal, fn)
hs, ms_held = run(held, fn) if held else ([], 0)
print(f"{a.model}{' + ' + a.adapter if a.adapter else ''}{', prefix cache' if a.cache else ''}")
report("calibration", cs, cal)
if held: report("held-out", hs, held)
if a.cache:
    _, cold = run(cal, score)
    drift = max(abs(score(p["heard"], p["term"]) - s) for p, s in zip(cal[:8], cs))
    print(f"  ms per pair: {ms_cal:.0f} with the prefix cache ({len(head)} tok shared), {cold:.0f} cold; "
          f"cached-vs-cold score drift {drift:.3f}")
else:
    print(f"  ms per pair: {ms_cal:.0f} cold")
for sl in ([False, True] if "candidate" in cal[0] else [False]):
    best, strict = fit(cs, cal, sl)
    kept = sum(p.get("candidate") is not None for p in held or cal) if sl else len(held or cal)
    print(f"  {'shortlist + score' if sl else 'score alone'} ({kept}/{len(held or cal)} pairs scored):")
    for label, t in (("best-F1", best), ("strict", strict)):
        cp, cr, cf, _ = prf(cs, cal, t, sl)
        line = f"    {label} t={t:+.2f}: calibration P {cp:.2f} R {cr:.2f} F1 {cf:.2f}"
        if held:
            hp, hr, hf, hfp = prf(hs, held, t, sl)
            line += f" | held-out P {hp:.2f} R {hr:.2f} F1 {hf:.2f} ({hfp} false yes)"
        print(line)
