#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["gepa", "tokenizers"]
# ///
"""GEPA prompt optimization for models without a PopTalk fine-tune (#74). From the repo root, after
`swift build -c release` and `gen.py teach && gen.py build` (training/out/items.jsonl):

  training/gepa_prompts.py [--model mlx-community/gemma-4-e4b-it-4bit] [--budget 1500] [--reflector claude]
                           [--component dictation|edit] [--out training/out/gepa] [--compress training/out/gepa]

Candidates are scored through the real pipeline: PoptalkBench --dictation-prompt-file/--edit-prompt-file.
Train/val come from the synthetic items only; bench and held-out stay out of the loop (test them after,
back to back with --compare). The two prompts never meet in one case, so each gets its own GEPA run
(half --budget each). Writes <out>/{dictation,edit}.txt and GEPA's run dirs (a rerun resumes them).
--reflector claude sends the reflection prompts (synthetic items, failure feedback) to Claude via `claude -p`;
anything else is a litellm model id (e.g. a local OpenAI-compatible server)."""
import argparse, difflib, json, random, subprocess, sys, tempfile
from collections import defaultdict
from pathlib import Path

import gepa
from gepa.core.adapter import EvaluationBatch

BENCH = ".build/release/PoptalkBench"


def prompt(name):  # the current Prompts.swift text: the seed candidate
    src = Path("Sources/PoptalkCore/Prompts.swift").read_text()
    body = src.split(f"static var {name}System = \"\"\"\n", 1)[1].split('\n    """', 1)[0]
    lines = [l[4:] for l in body.split("\n")]
    return "\n".join(lines).replace("\\\n", "")  # Swift's trailing \ joins lines


def case(it):
    """A synthetic item as a bench case, scored exactly against its target."""
    ctx = it["context"]
    c = {"id": it["id"], "transcript": it["transcript"], "context": ctx.get("text", ""), "cat": it["cat"]}
    if "cursorOffset" in ctx: c["cursor"] = ctx["cursorOffset"]
    if ctx.get("ocrText"): c["ocr"] = ctx["ocrText"]
    if "selection" not in it:
        return c | {"kind": "dictation", "expectExact": it["target"]}
    t = json.loads(it["target"])
    return c | {"kind": "edit", "selection": it["selection"], "expectAction": t["action"],
                "expectExact": t["text"].strip(), "expectVocabOffer": (t.get("vocabulary") or {}).get("text")}


def itn(cases):
    """Dictation targets are written in words; like the fine-tune data, they get Pipeline.spokenNumbers (via
    PoptalkDatagen render, #59) so they carry the digits the pre-pass gives the model."""
    rows = [{"id": c["id"], "kind": "dictation", "transcript": c["transcript"], "target": c["expectExact"]}
            for c in cases if c["kind"] == "dictation"]
    p = subprocess.run([".build/release/PoptalkDatagen", "render"], input="".join(json.dumps(r) + "\n" for r in rows),
                       capture_output=True, text=True, check=True)
    digits = {r["id"]: r["messages"][-1]["content"] for r in map(json.loads, p.stdout.splitlines())}
    return [c | {"expectExact": digits[c["id"]]} if c["id"] in digits else c for c in cases]


def sample(items, per_cat, seed):
    by = defaultdict(list)
    for it in items:
        by[it["cat"]].append(it)
    r = random.Random(seed)
    return [case(it) for cat in sorted(by) for it in r.sample(by[cat], min(per_cat, len(by[cat])))]


def tokenizer(model):  # Gemma 4 E2B and E4B (v3's base) share one tokenizer; the text-only copies have it
    from tokenizers import Tokenizer
    name = "gemma-4-e4b-it-4bit-text" if "e4b" in model else "gemma-4-e2b-it-4bit-text"
    t = Tokenizer.from_file(str(Path.home() / "Library/Application Support/Poptalk/models" / name / "tokenizer.json"))
    return lambda s: len(t.encode(s, add_special_tokens=False).ids)


class Adapter:
    propose_new_texts = None

    def __init__(self, model, component, count=None, ref_tokens=None):
        self.model, self.component = model, component
        # --compress: count(text) → tokens, ref_tokens = the Prompts.swift seed's length (brevity 1.0 there)
        self.count, self.ref_tokens, self.tokens = count, ref_tokens, None

    def brevity(self, text):
        return min(1.0, self.ref_tokens / self.count(text))

    def evaluate(self, batch, candidate, capture_traces=False):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "prompt.txt").write_text(candidate[self.component])
            (d / "cases.jsonl").write_text("".join(json.dumps(c) + "\n" for c in batch))
            p = subprocess.run([BENCH, "--provider", "mlx", "--cleanup-model", self.model, "--runs", "1",
                                "--cases", d / "cases.jsonl", "--out", d / "res",
                                f"--{self.component}-prompt-file", d / "prompt.txt"],
                               capture_output=True, text=True)
            if p.returncode:
                sys.exit(f"PoptalkBench failed:\n{p.stderr[-2000:]}")
            runs = {r["id"]: r["runs"][0] for r in json.loads(next((d / "res").glob("*.json")).read_text())["cases"]}
        outs, scores = [], []
        for c in batch:
            run = runs[c["id"]]
            # Partial credit for near misses, so one wrong comma still tells GEPA it was close.
            sim = difflib.SequenceMatcher(a=run["output"], b=c["expectExact"]).ratio()
            outs.append(run)
            scores.append(1.0 if not run["failures"] else 0.5 * sim)
        trajectories = [{"case": c, "run": o} for c, o in zip(batch, outs)] if capture_traces else None
        objectives = None
        if self.count:
            b = self.brevity(candidate[self.component])
            objectives = [{"accuracy": s, "brevity": b} for s in scores]
        return EvaluationBatch(outputs=outs, scores=scores, trajectories=trajectories, objective_scores=objectives)

    def make_reflective_dataset(self, candidate, eval_batch, components_to_update):
        if self.count:  # read by the reflector next: the prompt it is about to shorten
            self.tokens = self.count(candidate[self.component])
        return {k: reflective(eval_batch, k) for k in components_to_update}


class NoAccuracyForLength:
    """--compress acceptance: `scores` stay pure accuracy. A child passes if it is more accurate on the
    minibatch, or shorter and within 0.01 per example of its parent; length never buys accuracy away."""

    def __init__(self, adapter):
        self.a = adapter

    def should_accept(self, p, state):
        n = len(p.subsample_scores_after)
        before, after = sum(p.subsample_scores_before), sum(p.subsample_scores_after)
        parent = state.program_candidates[p.parent_program_ids[0]][self.a.component]
        shorter = self.a.count(p.candidate[self.a.component]) < self.a.count(parent)
        return after > before or (shorter and after >= before - 0.01 * n)


COMPRESS_TEMPLATE = """I gave a small on-device model (Gemma) these instructions; they are {tokens} tokens long:
```
<curr_param>
```

Here are task inputs, the model's outputs and feedback on them:
```
<side_info>
```

The model re-reads every token of the instructions on every request, so a shorter prompt is directly faster on-device. \
Write a SHORTER version that keeps the same behavior: remove or merge rules and examples that don't change outcomes, \
collapse repeated points, and prefer one crisp example over several. Keep every tested rule (the ones the feedback \
above exercises) and fix any failures shown. Don't add new content that isn't needed for the failures above.

Provide the new instructions within ``` blocks."""


def reflective(eval_batch, component):
    recs = []
    for t, s in zip(eval_batch.trajectories, eval_batch.scores):
        c, run = t["case"], t["run"]
        if c["kind"] != component:
            continue
        inputs = {"screen": c["context"][-600:], "transcript": c["transcript"]} | ({"selection": c["selection"]} if "selection" in c else {})
        fb = "Correct." if s == 1.0 else f"Wrong: {'; '.join(run['failures'])}. Expected exactly: {c['expectExact']!r}" + (
            f" with action {c['expectAction']}" if c["kind"] == "edit" else "")
        recs.append({"Inputs": inputs, "Generated Outputs": run["output"] + (f" [action {run['action']}]" if c["kind"] == "edit" else ""), "Feedback": fb})
    return recs


def claude(p):
    text = p if isinstance(p, str) else "\n\n".join(m["content"] for m in p)
    # No tools, MCP or project CLAUDE.md (cwd outside the repo): a plain completion.
    r = subprocess.run(["claude", "-p", "--model", "opus", "--tools", "", "--no-session-persistence", "--strict-mcp-config",
                        "--system-prompt", "You revise system prompts for a small on-device LLM."],
                       input=text, capture_output=True, text=True, cwd=tempfile.gettempdir())
    if r.returncode:
        sys.exit(f"claude -p failed: {r.stderr[-1000:]}")
    return r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="mlx-community/gemma-4-e4b-it-4bit")
    ap.add_argument("--budget", type=int, default=1500, help="max rollouts (metric calls), split across the prompts")
    ap.add_argument("--train-per-cat", type=int, default=8)
    ap.add_argument("--val-per-cat", type=int, default=3)
    ap.add_argument("--reflector", default="claude")
    ap.add_argument("--component", choices=["dictation", "edit"], help="optimize only this prompt")
    ap.add_argument("--out", type=Path, default=Path("training/out/gepa"))
    ap.add_argument("--compress", type=Path, metavar="DIR",
                    help="compression pass: seed from DIR/<prompt>.txt (an earlier run's best) and add a length objective")
    a = ap.parse_args()
    items = [json.loads(l) for l in open("training/out/items.jsonl")]
    items = [it for it in items if "vocabulary" not in it]  # saved vocabulary isn't wired into bench cases
    val = sample(items, a.val_per_cat, seed=1)
    seen = {c["id"] for c in val}
    train = itn(sample([it for it in items if it["id"] not in seen], a.train_per_cat, seed=2))
    val = itn(val)
    a.out.mkdir(parents=True, exist_ok=True)
    comps = [a.component] if a.component else ["dictation", "edit"]
    for comp in comps:
        tr, va = [c for c in train if c["kind"] == comp], [c for c in val if c["kind"] == comp]
        print(f"{comp}: train {len(tr)}, val {len(va)}", file=sys.stderr, flush=True)
        lm = claude if a.reflector == "claude" else a.reflector
        if not a.compress:
            ad = Adapter(a.model, comp)
            res = gepa.optimize(seed_candidate={comp: prompt(comp)}, trainset=tr, valset=va, adapter=ad, reflection_lm=lm,
                                reflection_minibatch_size=6, max_metric_calls=a.budget // len(comps),
                                run_dir=str(a.out / f"run-{comp}"), cache_evaluation=True)
            best = res.best_idx
        else:
            count = tokenizer(a.model)
            ad = Adapter(a.model, comp, count, count(prompt(comp)))
            # "hybrid" keeps per-example winners plus the best mean of each objective (most accurate, shortest)
            # as parents. No perfect-minibatch skip: a perfect minibatch can still be said in fewer tokens.
            res = gepa.optimize(seed_candidate={comp: (a.compress / f"{comp}.txt").read_text()}, trainset=tr, valset=va,
                                adapter=ad, reflection_lm=lambda p: claude(p.replace("{tokens}", str(ad.tokens))),
                                reflection_prompt_template=COMPRESS_TEMPLATE, frontier_type="hybrid",
                                acceptance_criterion=NoAccuracyForLength(ad), skip_perfect_score=False,
                                reflection_minibatch_size=6, max_metric_calls=a.budget // len(comps),
                                run_dir=str(a.out / f"run-{comp}"), cache_evaluation=True)
            # The shortest candidate whose val accuracy is within 0.01 of the (long) seed's.
            ok = [i for i, s in enumerate(res.val_aggregate_scores) if s >= res.val_aggregate_scores[0] - 0.01]
            best = min(ok, key=lambda i: count(res.candidates[i][comp]))
            print(f"{comp}: tokens " + ", ".join(f"#{i} {count(c[comp])} @ {res.val_aggregate_scores[i]:.3f}"
                                                  for i, c in enumerate(res.candidates)), file=sys.stderr, flush=True)
        (a.out / f"{comp}.txt").write_text(res.candidates[best][comp])
        print(f"{comp}: best val {res.val_aggregate_scores[best]:.3f} (seed {res.val_aggregate_scores[0]:.3f}), "
              f"{res.num_candidates} candidates, {res.total_metric_calls} rollouts; wrote {a.out}/{comp}.txt",
              file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
