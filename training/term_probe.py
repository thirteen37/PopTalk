"""#75 step 2, no-training probe: can the cleanup model itself tell a sound-alike mishearing of a screen term?
One prefill per pair of "Is '<heard>' the term '<term>'?", scored by the yes-minus-no logit at the first reply token.
From the repo root:
  uv run --project training python training/term_probe.py MODEL [--adapter DIR] [--pairs training/term_pairs.jsonl]
Prints AUC, the best-F1 threshold's precision/recall, accuracy at 0, and milliseconds per pair. The pairs are invented.
"""
import argparse, json, time

import mlx.core as mx
from mlx_lm import load

ap = argparse.ArgumentParser()
ap.add_argument("model")
ap.add_argument("--adapter")
ap.add_argument("--pairs", default="training/term_pairs.jsonl")
a = ap.parse_args()
model, tok = load(a.model, adapter_path=a.adapter)
pairs = [json.loads(l) for l in open(a.pairs)]


def ids(words):
    """First token of each spelling, so " Yes" and "yes" both count."""
    return sorted({tok.encode(w, add_special_tokens=False)[0] for w in words})


YES, NO = ids(["yes", "Yes", " yes", " Yes", "YES"]), ids(["no", "No", " no", " No", "NO"])


def score(heard, term):
    msg = (f"A speech recognizer heard '{heard}'. Is that the term '{term}' (the same word or name, "
           f"misheard or split up)? Answer yes or no.")
    prompt = tok.apply_chat_template([{"role": "user", "content": msg}], add_generation_prompt=True, tokenize=False,
                                   enable_thinking=False)  # as the app sends it (MLXProvider)
    x = mx.array(tok.encode(prompt, add_special_tokens=False))[None]
    logits = model(x)[0, -1].astype(mx.float32)
    lp = logits - mx.logsumexp(logits)
    s = mx.logsumexp(lp[mx.array(YES)]) - mx.logsumexp(lp[mx.array(NO)])
    top = int(mx.argmax(logits).item())
    return s.item(), top in YES or top in NO


score("warm up", "Warmup")  # compile and load before timing
t0, out = time.perf_counter(), []
for p in pairs:
    s, yn = score(p["heard"], p["term"])
    out.append((s, p["match"], p["kind"], yn))
ms = (time.perf_counter() - t0) * 1000 / len(pairs)

pos, neg = [s for s, m, *_ in out if m], [s for s, m, *_ in out if not m]
AUC = lambda ps, ns: sum((p > n) + 0.5 * (p == n) for p in ps for n in ns) / (len(ps) * len(ns))
auc, auc_near = AUC(pos, neg), AUC(pos, [s for s, m, k, _ in out if k == "near-miss"])
best = (0, 0, 0, 0)
for t in sorted({s for s, *_ in out}):
    tp = sum(s >= t for s in pos); fp = sum(s >= t for s in neg)
    prec, rec = tp / max(1, tp + fp), tp / len(pos)
    f1 = 2 * prec * rec / max(1e-9, prec + rec)
    if f1 > best[0]: best = (f1, t, prec, rec)
acc0 = sum((s > 0) == m for s, m, *_ in out) / len(out)
by = {k: sum(s > 0 for s, m, kk, _ in out if kk == k) for k in ("sound-alike", "near-miss", "unrelated")}
n = {k: sum(kk == k for *_, kk, _ in out) for k in by}
print(f"{a.model}{' + ' + a.adapter if a.adapter else ''}: {len(pairs)} pairs ({len(pos)} match)")
print(f"  AUC {auc:.3f} (vs near-misses only {auc_near:.3f}); best F1 {best[0]:.2f} at {best[1]:+.2f}: precision {best[2]:.2f}, recall {best[3]:.2f}")
print(f"  at 0: accuracy {acc0:.2f}; said yes to " + ", ".join(f"{k} {by[k]}/{n[k]}" for k in by))
print(f"  top token is yes/no in {sum(yn for *_, yn in out)}/{len(out)}; {ms:.0f} ms per pair")
