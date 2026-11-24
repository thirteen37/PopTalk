#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["gepa", "tokenizers"]
# ///
"""GEPA prompt optimization for models without a PopTalk fine-tune (#74). From the repo root, after
`swift build -c release` and `gen.py teach && gen.py build` (training/out/items.jsonl):

  training/gepa_prompts.py [--model mlx-community/gemma-4-e4b-it-4bit] [--budget 1500] [--reflector claude]
                           [--component dictation|edit] [--out training/out/gepa] [--seed DIR] [--length] [--dry-run]

Candidates are scored through the real pipeline: PoptalkBench --dictation-prompt-file/--edit-prompt-file.
Train/val come from the synthetic items only; bench and held-out stay out of the loop (test them after,
back to back with --compare). The two prompts never meet in one case, so each gets its own GEPA run
(half --budget each). Writes <out>/{dictation,edit}.txt, the sampled <out>/pool-{train,val}.jsonl and GEPA's
run dirs (a rerun resumes them).
The seed is the model's prompt in Prompts.swift (E4B: e4bDictationSystem / e4bEditSystem), or <DIR>/<prompt>.txt.
--length adds prompt length (tokens) as a second objective in the same run (#103): reflections alternate between
fixing failures and shortening, a child is kept only if it is more accurate or shorter at the same accuracy, and
the pick is the shortest candidate on the (val accuracy, tokens) Pareto front within 0.01 of the front's best accuracy.
A child longer than the seed is never accepted. Each candidate's mean val latency is logged next to its tokens.
--dry-run builds and writes the pool, counts the seed's tokens and checks the scoring, then stops (no model, no API).
--reflector claude sends the reflection prompts (synthetic items, failure feedback) to Claude via `claude -p`;
anything else is a litellm model id (e.g. a local OpenAI-compatible server)."""
import argparse, difflib, json, random, subprocess, sys, tempfile
from collections import Counter, defaultdict
from pathlib import Path

import gepa
from gepa.core.adapter import EvaluationBatch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from contamination import swift_prompt  # noqa: E402

BENCH = ".build/release/PoptalkBench"


def prompt(comp, model):  # the Prompts.swift text the app uses for `model`: the seed candidate
    return swift_prompt(f"e4b{comp.capitalize()}System" if "e4b" in model else f"{comp}System")


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


def score(run, case):
    """1 for a pass; partial credit for near misses, so one wrong comma still tells GEPA it was close."""
    return 1.0 if not run["failures"] else 0.5 * difflib.SequenceMatcher(a=run["output"], b=case["expectExact"]).ratio()


class Adapter:
    propose_new_texts = None

    def __init__(self, model, component, count=None, ref_tokens=None):
        self.model, self.component = model, component
        # --length: count(text) → tokens, ref_tokens = the seed's length (brevity 1.0 there, uncapped: shorter scores higher)
        self.count, self.ref_tokens, self.tokens = count, ref_tokens, None
        self.val_ids, self.latency = set(), {}  # mean seconds per case on the full val set, per prompt text

    def brevity(self, text):
        return self.ref_tokens / self.count(text)

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
        outs = [runs[c["id"]] for c in batch]
        if {c["id"] for c in batch} == self.val_ids:
            self.latency[candidate[self.component]] = sum(o["seconds"] for o in outs) / len(outs)
        scores = [score(o, c) for o, c in zip(outs, batch)]
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
    """--length acceptance: `scores` stay pure accuracy. A child longer than the seed never passes; otherwise it
    passes if it is more accurate on the minibatch, or shorter and within 0.01 per example of its parent."""

    def __init__(self, adapter):
        self.a = adapter

    def should_accept(self, p, state):
        n = len(p.subsample_scores_after)
        before, after = sum(p.subsample_scores_before), sum(p.subsample_scores_after)
        parent = state.program_candidates[p.parent_program_ids[0]][self.a.component]
        tokens = self.a.count(p.candidate[self.a.component])
        if tokens > self.a.ref_tokens:
            return False
        return after > before or (tokens < self.a.count(parent) and after >= before - 0.01 * n)


LENGTH_TEMPLATE = """I gave a small on-device model (Gemma) these instructions; they are {tokens} tokens long:
```
<curr_param>
```

Here are task inputs, the model's outputs and feedback on them:
```
<side_info>
```

The model re-reads every token of the instructions on every request, so a shorter prompt is directly faster on-device. \
{goal}

Provide the new instructions within ``` blocks."""

GOALS = {
    "fix": "Revise the instructions so the model gets the failed examples above right, with the smallest change that \
does it. Generalize from the failures instead of quoting them, keep every rule the correct examples rely on, and don't \
make the instructions longer than the fix needs; merge or cut something else if you can.",
    "shorten": "Write a SHORTER version that keeps the same behavior: remove or merge rules and examples that don't \
change outcomes, collapse repeated points, and prefer one crisp example over several. Keep every tested rule (the ones \
the feedback above exercises) and fix any failures shown. Don't add new content that isn't needed for the failures above.",
}


class LengthReflector:
    """--length: odd calls fix failures, even calls (and any minibatch with none) shorten, so one run does both."""

    def __init__(self, adapter):
        self.a, self.n = adapter, 0

    def goal(self, p):
        self.n += 1
        return "fix" if self.n % 2 and "Wrong:" in p else "shorten"

    def __call__(self, p):
        return claude(p.replace("{tokens}", str(self.a.tokens)).replace("{goal}", GOALS[self.goal(p)]))


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


def front(pts):
    """Indices of the (accuracy, tokens) Pareto front: no other point is as accurate and as short, and better at one."""
    return [i for i, (s, t) in enumerate(pts)
            if not any(s2 >= s and t2 <= t and (s2, t2) != (s, t) for s2, t2 in pts)]


def pick(pts, f):
    """The selection rule: the shortest front candidate within 0.01 val accuracy of the front's best."""
    top = max(pts[i][0] for i in f)
    return min((i for i in f if pts[i][0] >= top - 0.01 - 1e-9), key=lambda i: pts[i][1])


def dry_run(comp, train, seed, count):
    """Checks the scoring, the length objective and the reflection prompt on fixed strings; prints its size."""
    c = {"id": "x", "kind": comp, "cat": "x", "transcript": "move the review to monday sorry i meant tuesday",
         "context": "", "expectExact": "Move the review to Tuesday."} | ({"selection": "x", "expectAction": "edit"} if comp == "edit" else {})
    ok, near, wrong = ({"output": o, "failures": f, "action": "edit"} for o, f in [
        ("Move the review to Tuesday.", []), ("Move the review to Tuesday", ["not exact"]), ("Sure! Here it is.", ["not exact"])])
    assert score(ok, c) == 1.0 and 0.45 < score(near, c) < 0.5 and score(wrong, c) < 0.2, (score(near, c), score(wrong, c))
    ad = Adapter("dry-run", comp, count, count(seed))
    lengths = [seed + "\n" + seed, seed, seed[: 3 * len(seed) // 4], seed[: len(seed) // 2]]
    b = [ad.brevity(t) for t in lengths]
    assert b[1] == 1.0 and b == sorted(b) and len(set(b)) == 4, b  # uncapped: shorter is always better
    assert front([(0.80, 900), (0.81, 905), (0.75, 600), (0.74, 650), (0.70, 1000)]) == [0, 1, 2]
    assert pick([(0.80, 900), (0.81, 905), (0.75, 600)], [0, 1, 2]) == 0
    batch = EvaluationBatch(outputs=[ok, near], scores=[1.0, score(near, c)], trajectories=[{"case": c, "run": ok}, {"case": c, "run": near}])
    recs = reflective(batch, comp)
    assert recs[0]["Feedback"] == "Correct." and recs[1]["Feedback"].startswith("Wrong: not exact."), recs
    r = LengthReflector(ad)
    assert [r.goal("Wrong: x"), r.goal("Wrong: x"), r.goal("Correct."), r.goal("Correct.")] == ["fix", "shorten", "shorten", "shorten"]
    # One reflection call's prompt, with a 6-example minibatch of real pool cases (outputs = their targets).
    side = [{"Inputs": {"screen": t["context"][-600:], "transcript": t["transcript"]}, "Generated Outputs": t["expectExact"],
             "Feedback": "Wrong: … Expected exactly: " + repr(t["expectExact"])} for t in train[:6]]
    p = LENGTH_TEMPLATE.replace("<curr_param>", seed).replace("<side_info>", json.dumps(side, indent=1, ensure_ascii=False))
    ad.tokens = count(seed)
    print(f"{comp}: dry run ok; categories {dict(Counter(t['cat'] for t in train))}; one reflection prompt ≈ "
          f"{count(p.replace('{goal}', GOALS['fix']))} tokens in, a reply ≈ {count(seed)} tokens", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="mlx-community/gemma-4-e4b-it-4bit")
    ap.add_argument("--budget", type=int, default=1500, help="max rollouts (metric calls), split across the prompts")
    ap.add_argument("--train-per-cat", type=int, default=8)
    ap.add_argument("--val-per-cat", type=int, default=3)
    ap.add_argument("--reflector", default="claude")
    ap.add_argument("--component", choices=["dictation", "edit"], help="optimize only this prompt")
    ap.add_argument("--out", type=Path, default=Path("training/out/gepa"))
    ap.add_argument("--seed", type=Path, metavar="DIR", help="seed from DIR/<prompt>.txt (e.g. an earlier run's best)")
    ap.add_argument("--length", action="store_true", help="add prompt length (tokens) as an objective")
    ap.add_argument("--dry-run", action="store_true", help="write the pool and check the scoring; no model, no API")
    a = ap.parse_args()
    if a.length and a.reflector != "claude":
        sys.exit("--length reflects through claude -p only")
    items = [json.loads(l) for l in open("training/out/items.jsonl")]
    items = [it for it in items if "vocabulary" not in it]  # saved vocabulary isn't wired into bench cases
    val = sample(items, a.val_per_cat, seed=1)
    seen = {c["id"] for c in val}
    train = itn(sample([it for it in items if it["id"] not in seen], a.train_per_cat, seed=2))
    val = itn(val)
    a.out.mkdir(parents=True, exist_ok=True)
    for name, cases in (("train", train), ("val", val)):
        (a.out / f"pool-{name}.jsonl").write_text("".join(json.dumps(c, ensure_ascii=False) + "\n" for c in cases))
    comps = [a.component] if a.component else ["dictation", "edit"]
    count = tokenizer(a.model) if a.length or a.dry_run else None
    for comp in comps:
        tr, va = [c for c in train if c["kind"] == comp], [c for c in val if c["kind"] == comp]
        seed = (a.seed / f"{comp}.txt").read_text() if a.seed else prompt(comp, a.model)
        print(f"{comp}: train {len(tr)}, val {len(va)} in {len({c['cat'] for c in tr})} categories; seed "
              + (f"{count(seed)} tokens" if count else f"{len(seed)} chars"), file=sys.stderr, flush=True)
        if a.dry_run:
            dry_run(comp, tr, seed, count)
            continue
        if not a.length:
            ad = Adapter(a.model, comp)
            res = gepa.optimize(seed_candidate={comp: seed}, trainset=tr, valset=va, adapter=ad,
                                reflection_lm=claude if a.reflector == "claude" else a.reflector,
                                reflection_minibatch_size=6, max_metric_calls=a.budget // len(comps),
                                run_dir=str(a.out / f"run-{comp}"), cache_evaluation=True)
            best = res.best_idx
        else:
            ad = Adapter(a.model, comp, count, count(seed))
            ad.val_ids = {c["id"] for c in va}
            # "hybrid" keeps per-example winners plus the best mean of each objective (most accurate, shortest)
            # as parents. No perfect-minibatch skip: a perfect minibatch can still be said in fewer tokens.
            res = gepa.optimize(seed_candidate={comp: seed}, trainset=tr, valset=va, adapter=ad,
                                reflection_lm=LengthReflector(ad), reflection_prompt_template=LENGTH_TEMPLATE,
                                frontier_type="hybrid", acceptance_criterion=NoAccuracyForLength(ad),
                                skip_perfect_score=False, reflection_minibatch_size=6,
                                max_metric_calls=a.budget // len(comps), run_dir=str(a.out / f"run-{comp}"),
                                cache_evaluation=True)
            # Pick from the (val accuracy, tokens) Pareto front: see pick().
            pts = [(s, count(c[comp])) for s, c in zip(res.val_aggregate_scores, res.candidates)]
            f = front(pts)
            best = pick(pts, f)
            print(f"{comp}: #  tokens  val-latency  accuracy  (* = Pareto front, > = pick)", file=sys.stderr)
            for i, ((s, t), c) in enumerate(zip(pts, res.candidates)):
                lat = ad.latency.get(c[comp])
                print(f"{'>' if i == best else '*' if i in f else ' '} #{i:<3} {t:5}  {f'{lat:.3f}s' if lat else '   -  '}  "
                      f"{s:.3f}", file=sys.stderr, flush=True)
        (a.out / f"{comp}.txt").write_text(res.candidates[best][comp])
        print(f"{comp}: best val {res.val_aggregate_scores[best]:.3f} (seed {res.val_aggregate_scores[0]:.3f}), "
              f"{res.num_candidates} candidates, {res.total_metric_calls} rollouts; wrote {a.out}/{comp}.txt",
              file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
