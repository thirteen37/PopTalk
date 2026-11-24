#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Keeps bench/cases.jsonl and training/heldout.jsonl held out (#21, #60): rejects training items that share
names, sentences or near-paraphrases with any bench case, with the examples the E4B dictation prompt and the GEPA
seeds quote, or with what a held-out case says or expects
(held-out screens and selections reuse the shared lexicon, see bench_texts). `./contamination.py` runs the self-test;
`./contamination.py items.jsonl` checks a file and exits 1 on any hit."""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BENCH = ROOT / "bench" / "cases.jsonl"
HELDOUT = ROOT / "training" / "heldout.jsonl"
PROMPTS = ROOT / "Sources" / "PoptalkCore" / "Prompts.swift"

# Names and terms that only exist because the bench uses them. Word-boundary, case-insensitive.
BLOCK = ["Priya", "Raman", "Marcus", "FluidAudio", "Fluid Audio", "Todoist", "Kubernetes", "TestFlight", "Test Flight",
         "Meal Prep", "Quillmate", "Quill mate", "Quilmark", "Brightwater", "Bright water", "Analytica", "Kateryna",
         "Katerina", "Shevchuk", "Oyelaran", "Tomasz", "Wrzesniewski", "Vreshnevski", "Wrisley", "Dana", "Whitfield",
         "gpt-4o", "GPT 4o", "OKR", "OKRs", "Poptalk", "App Store Connect", "iOS 27", "Q3", "Q three", "Jira", "Helsinki",
         "oat milk", "Ana", "田中", "plumber", "electricity bill", "Ajay", "Arjee"]
BLOCK_RE = re.compile("|".join(rf"(?<!\w){re.escape(b)}(?!\w)" for b in BLOCK), re.IGNORECASE)


def swift_prompt(name: str) -> str:
    """A system prompt's text as Swift builds it from its Prompts.swift literal (multi-line or raw)."""
    m = re.search(rf'static var {name} = (#?)"""\n(.*?)\n    """\1', PROMPTS.read_text(), re.S)
    body = "\n".join(l[4:] for l in m.group(2).split("\n"))
    return body if m.group(1) else body.replace("\\\n", "").replace('\\"', '"')  # a trailing \ joins lines


# Prompt E (#98, #103): no longer live, but GEPA seeds from it, so its examples stay out of the pool too.
GEPA_SEEDS = [ROOT / "training" / "gepa" / "e4b-dictation-E.txt"]


def prompt_examples() -> list[str]:
    """The quoted phrases (3+ words) in the live E4B dictation prompt and the GEPA seeds: their examples,
    kept out of training like bench text."""
    texts = [swift_prompt("e4bDictationSystem")] + [p.read_text() for p in GEPA_SEEDS]
    return sorted({q for t in texts for q in re.findall(r'"([^"]+)"', t) if len(words(q)) >= 3})


def words(s: str) -> list[str]:
    return re.findall(r"[\w']+", s.lower())


def ngrams(ws: list[str], n: int) -> set[tuple]:
    return {tuple(ws[i:i + n]) for i in range(len(ws) - n + 1)}


def bench_texts(path: Path = BENCH, heldout: bool = False):
    """(long texts for n-gram overlap, short spoken/selected texts per case). Held-out selections and screens
    are built from the shared lexicon (padding, filler, titles) on purpose, so for held-out cases only what is
    said or expected is matched as text; selections still count toward near-paraphrases."""
    longs, shorts = set(), []
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        c = json.loads(line)
        said = [c.get(k) for k in ("transcript", "speak", "selection", "expectExact") if c.get(k)]
        shorts.append(" ".join(said))
        longs.update(c[k] for k in ("transcript", "speak", "expectExact") if c.get(k)) if heldout else longs.update(said)
        for k in () if heldout else ("context", "ocr"):
            if c.get(k):
                longs.update(s for s in re.split(r"(?<=[.!?\n])\s*", c[k]) if s.strip())
    return longs, shorts


class Checker:
    def __init__(self, path: Path = BENCH, n: int = 5, heldout: Path | None = HELDOUT):
        longs, shorts = bench_texts(path)
        if heldout and heldout.exists():
            hl, hs = bench_texts(heldout, heldout=True)
            longs |= hl
            shorts += hs
        for q in prompt_examples():  # what the prompts quote, matched like what a held-out case says
            longs.add(q)
            shorts.append(q)
        self.n = n
        self.grams = set().union(*(ngrams(words(t), n) for t in longs))
        self.short_norm = {" ".join(words(t)) for t in longs if len(words(t)) < n}
        self.shorts = [set(words(s)) for s in shorts]

    def reason(self, item: dict) -> str | None:
        """Why `item` (a gen.py item: transcript, selection, context, target, vocabulary) is contaminated, or None."""
        ctx = item.get("context") or {}
        fields = [item.get("transcript"), item.get("selection"), item.get("target"), item.get("speak"),
                  ctx.get("text"), ctx.get("ocrText"), ctx.get("windowTitle"),
                  json.dumps(item.get("vocabulary") or [], ensure_ascii=False)]
        for f in filter(None, fields):
            if m := BLOCK_RE.search(f):
                return f"bench name {m.group(0)!r}"
            ws = words(f)
            if hit := ngrams(ws, self.n) & self.grams:
                return f"bench {self.n}-gram {' '.join(next(iter(hit)))!r}"
            if ws and " ".join(ws) in self.short_norm:
                return f"bench text {f!r}"
        said = set(words(" ".join(filter(None, [item.get("transcript"), item.get("selection")]))))
        for s in self.shorts:
            if said and s and len(said & s) / len(said | s) >= 0.6:
                return f"near-paraphrase of bench case ({' '.join(sorted(s))[:60]})"
        return None


def self_test():
    c = Checker()
    cases = [json.loads(l) for l in BENCH.read_text().splitlines() if l.strip()]
    cases += [json.loads(l) for l in HELDOUT.read_text().splitlines() if l.strip()]
    for case in cases:  # every bench and held-out case must be caught by its own text
        item = {"transcript": case.get("transcript") or case.get("speak"), "selection": case.get("selection")}
        assert c.reason(item), case["id"]
    assert "bench name" in c.reason({"transcript": "ping priya about it"})
    assert c.reason({"transcript": "um let's meet on tuesday no thursday at three"})  # paraphrase
    assert c.reason({"transcript": "make it shorter", "selection": "Totally different text here."})
    assert c.reason({"context": {"text": "x. Marcus said the staging cluster was flaky. y"}})
    assert c.reason({"target": "Analytica"}) and not c.reason({"target": "Anaïs and Banana"})
    assert c.reason({"context": {"text": "Design shared three mockups and the second one won."}})
    assert c.reason({"transcript": "translate to Japanese", "selection": "Good night"})
    assert not c.reason({"transcript": "make this shorter", "selection": "The office will be closed next Friday."})
    assert not c.reason({"transcript": "ask siobhan to look at the terraform alerts before monday",
                         "context": {"text": "#ops — Siobhan: Terraform alerts are noisy"}})
    assert c.reason({"transcript": "the vote is on tuesday bring the agenda"})  # prompt E's own example
    assert swift_prompt("dictationSystem").startswith("You clean up dictated speech.")
    print(f"contamination self-test ok ({len(prompt_examples())} prompt examples)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        self_test()
        sys.exit(0)
    c, bad, n = Checker(), 0, 0
    for line in Path(sys.argv[1]).read_text().splitlines():
        it = json.loads(line)
        n += 1
        if r := c.reason(it):
            bad += 1
            print(f"{it.get('id')}: {r}")
    print(f"{n} items, {bad} contaminated")
    sys.exit(1 if bad else 0)
