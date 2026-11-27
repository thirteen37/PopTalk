#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Keeps bench/cases.jsonl and training/heldout.jsonl held out (#21, #60): rejects training items that share
names, sentences or near-paraphrases with any bench case, with the examples the E4B dictation prompt and the GEPA
seeds quote, or with what a held-out case says or expects
(held-out screens and selections reuse the shared lexicon, see bench_texts). `./contamination.py` runs the self-test;
`./contamination.py items.jsonl` checks a file and exits 1 on any hit, and on any phrase it shares with a bench or
held-out case (Phrases, #115) unless --allow-phrases."""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lexicon as L  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
BENCH = ROOT / "bench" / "cases.jsonl"
HELDOUT = ROOT / "training" / "heldout.jsonl"
PROMPTS = ROOT / "Sources" / "PoptalkCore" / "Prompts.swift"

# Names and terms that only exist because the bench uses them. Word-boundary, case-insensitive.
BLOCK = ["Priya", "Raman", "Marcus", "FluidAudio", "Fluid Audio", "Todoist", "Kubernetes", "TestFlight", "Test Flight",
         "Meal Prep", "Quillmate", "Quill mate", "Quilmark", "Brightwater", "Bright water", "Analytica", "Kateryna",
         "Katerina", "Shevchuk", "Oyelaran", "Tomasz", "Wrzesniewski", "Vreshnevski", "Wrisley", "Dana", "Whitfield",
         "gpt-4o", "GPT 4o", "OKR", "OKRs", "Poptalk", "App Store Connect", "iOS 27", "Q3", "Q three", "Jira", "Helsinki",
         "oat milk", "Ana", "田中", "plumber", "electricity bill", "Ajay", "Arjee",
         # #99's s-* cases (real-voice bench)
         "Oskar", "PaperTrail", "Paper Trail", "Tolu", "Adeyemi", "Halvorsen", "Ledgerly", "HelpNest", "Help Nest", "Tamsin",
         "Mireille", "Zentrix", "Imogen", "Brindle", "CloudNook", "Cloud Nook", "Corvel", "Lucan", "Pelham", "Okafor",
         "Wexford", "Beatriz", "Nadia", "Felix",
         # #96's l-* cases (cleanup levels)
         "Quorbit", "Quor bit"]
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


# Phrase check (#115): Checker matches whole texts and 5-grams of what bench cases say, but not held-out selections,
# which reuse the shared lexicon. A generator that shares a padding or list phrase with a held-out selection leaks its
# wording into training and GEPA (#103: "please plan accordingly", h-e-shorter-0). Phrases flags every word 4-gram a
# generated item says, selects or expects that a bench or held-out case also says, selects or expects, unless it has
# fewer than 2 content words ("let me know if", "in the middle of": everyday English, not a case's wording).
STOP = set("""a an the and or but if so as at by for from in into of on onto off out over to up with about after before
then than that this these those there here it its it's i i'm i'll i've me my we we're we'll our us you you're your
he she they them their his her him is are was were be been being am do does did done have has had having will would
shall should can could may might must not no yes all any some each every just also very really too only even still
again now please let lets let's know think want like get got go going gonna make made way thing things what which who
when where why how one more most much many well okay oh um uh yeah hey hi need today tomorrow tonight""".split())
# Slot values, correction cues ("oh sorry I meant Wednesday") and the lexicon's people and tools ("the hub spot
# change"): the task's own vocabulary, which held-out cases share with training on purpose (#98, gen.py heldout), so
# they don't count as content either.
STOP |= {w for xs in (L.DAYS, L.TIMES, L.NUMBERS, L.MONTHS, L.PLACES, L.CUES, L.LATER_CUES, L.CANCEL_CUES) for x in xs
         for w in words(x)}
STOP |= {w for xs in (L.PEOPLE, L.TECH) for name, heard in xs for x in [name, *heard] for w in words(x)}
PHRASE_N = 4
SOURCES = [ROOT / "training" / "lexicon.py", ROOT / "training" / "gen.py"]


def source_lines():
    """(file:line, normalized words) of the generator sources, minus gen.py's held-out section (#115 hits point at
    the training template, not at the held-out case's own)."""
    out, skip = [], False
    for p in SOURCES:
        for i, l in enumerate(p.read_text().splitlines(), 1):
            skip = (skip or l.startswith("# ---------- held-out")) and not l.startswith("# ---------- main")
            if not skip:
                out.append((f"{p.name}:{i}", " ".join(words(l))))
    return out


class Phrases:
    def __init__(self, n: int = PHRASE_N, cases: list[dict] | None = None):
        if cases is None:
            cases = [json.loads(l) for p in (BENCH, HELDOUT) for l in p.read_text().splitlines() if l.strip()]
        self.n, self.index = n, {}
        for c in cases:
            for k in ("transcript", "speak", "written", "selection", "expectExact"):
                for g in self.grams(c.get(k) or ""):
                    self.index.setdefault(g, []).append(c["id"])
        self.src = source_lines()

    def grams(self, s: str) -> set[tuple]:
        return {g for g in ngrams(words(s), self.n) if sum(len(w) > 1 and w not in STOP for w in g) >= 2}

    def hits(self, item: dict) -> list[tuple[str, str, list[str]]]:
        """(field, shared n-gram, case ids) for each phrase `item` shares with a bench or held-out case, in text order."""
        t = item.get("target") or ""
        if "selection" in item and t.startswith("{"):
            t = json.loads(t).get("text") or ""
        out = []
        for k, s in (("transcript", item.get("transcript")), ("selection", item.get("selection")), ("target", t)):
            ws, seen = words(s or ""), set()
            for i in range(len(ws) - self.n + 1):
                g = tuple(ws[i:i + self.n])
                if g in self.index and g not in seen:
                    seen.add(g)
                    out.append((k, " ".join(g), sorted(set(self.index[g]))))
        return out

    def source(self, gram: str) -> str:
        """Where a hit's wording lives in the generator (first gen.py/lexicon.py line that has it), or '?'."""
        return next((loc for loc, l in self.src if gram in l), "?")

    def report(self, items: list[dict], out=sys.stdout) -> int:
        """Prints one line per (family, n-gram) with its item count, source line and case ids; returns hit items."""
        by, bad = {}, 0
        for it in items:
            if h := self.hits(it):
                bad += 1
                for k, g, ids in h:
                    by.setdefault((it.get("cat", "?"), k, g), [0, ids])[0] += 1
        for (cat, k, g), (n, ids) in sorted(by.items()):
            print(f"{cat} {k}: {g!r} ×{n} ({self.source(g)}) shared with {', '.join(ids)}", file=out)
        print(f"{len(items)} items, {bad} share a {self.n}-word phrase with a bench or held-out case", file=out)
        return bad


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
    # Phrase check (#115) on invented cases: a shared 4-gram with 2+ content words is a hit, stop-word runs aren't.
    p = Phrases(cases=[{"id": "x-1", "selection": "Heads up, the zeppelin hangar opens at noon, so plan your visit."},
                       {"id": "x-2", "transcript": "and I think that it was in the middle of the"}])
    assert p.grams(" ".join(["the", "zeppelin", "hangar", "opens"])) == {("the", "zeppelin", "hangar", "opens")}
    assert not p.grams("and it was in the")  # only stop words
    assert not p.grams("in the middle of")  # one content word: generic
    assert not p.grams("capital q x z v") and not p.grams("oh sorry I meant Wednesday at nine")  # spelled letters, cues and slots
    assert not p.grams("on the hub spot change")  # a lexicon tool, said in held-out on purpose
    hits = p.hits({"cat": "e-test", "selection": "Our Zeppelin hangar opens at noon tomorrow.",
                   "target": json.dumps({"action": "edit", "text": "I think that it was in the middle of it"})})
    assert hits == [("selection", "zeppelin hangar opens at", ["x-1"]), ("selection", "hangar opens at noon", ["x-1"])], hits
    assert not p.hits({"cat": "e-test", "transcript": "the hangar is open at noon"})
    print(f"contamination self-test ok ({len(prompt_examples())} prompt examples)")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--allow-phrases"]
    if not args:
        self_test()
        sys.exit(0)
    c, bad, items = Checker(), 0, [json.loads(l) for l in Path(args[0]).read_text().splitlines()]
    for it in items:
        if r := c.reason(it):
            bad += 1
            print(f"{it.get('id')}: {r}")
    print(f"{len(items)} items, {bad} contaminated")
    shared = Phrases().report(items, sys.stderr)  # stderr: make_data*.zsh keep it on screen
    if shared and "--allow-phrases" in sys.argv:
        print("--allow-phrases: not failing on shared phrases", file=sys.stderr)
        shared = 0
    sys.exit(1 if bad or shared else 0)
