#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Counts-only profile of real dictations (opt-in history) next to synthetic dictation pools (#103 realism).
Prints whole-percent rates per column, never text, and rounds the record count to tens.
Usage: training/pool_profile.py [--history FILE]... [POOL.jsonl ...]
  --history defaults to this Mac's history plus every Mac's synced file; `--history none` leaves the real column out.
  POOL: gen.py items (d-* dictation items, no selection), e.g. training/out/items.jsonl.
A real dictation is a request with no selection, deduped by id; screen and vocabulary come from its recorded prompt,
so those rows count only dictations that called a model ("n prompt")."""
import html
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lexicon as L  # noqa: E402

HOME = Path.home()
HISTORY = [HOME / "Library/Application Support/Poptalk/history/history.jsonl",
           *sorted((HOME / "Library/Mobile Documents/com~apple~CloudDocs/PopTalk/history").glob("history-*.jsonl"))]
PROMPT = re.compile(r'^<screen app="[^"]*" window="[^"]*">\n(.*)\n</screen>(?:\n<vocabulary>(.*)</vocabulary>)?\n<transcript>', re.S)
# The e4b prompt's cue list and Pipeline.cancelCue (#102).
CUES = ["no wait", "no", "make that", "sorry", "actually", "I mean", "rather", "scratch that"]
CUE_RE = re.compile(r"\b(?:" + "|".join(c.replace(" ", r"\W+") for c in CUES) + r")\b", re.I)
CANCEL_RE = re.compile(r"\b(?:scratch that|never ?mind|(?<!n't )(?<!not )forget (?:that|it|the))\b", re.I)
STRONG_RE = re.compile(r"\b(?:no\W+wait|make that|I mean|or rather|scratch that|never ?mind|I meant)\b", re.I)
FILLER_RE = re.compile(r"\b(?:" + "|".join(re.escape(f) for f in L.FILLERS) + r")\b", re.I)
STUTTER_RE = re.compile(r"\b(\w+)\W+\1\b", re.I)
WORD_BUCKETS = [(1, 5), (6, 15), (16, 40), (41, 100), (101, None)]
SCREEN_BUCKETS = [(1, 500), (501, 2000), (2001, 4000), (4001, None)]
STOP = {w.lower() for w in L.DAYS + L.MONTHS} | {"the", "this", "that", "and", "you", "can", "for", "with", "from",
                                                 "what", "when", "will", "just", "okay", "yes", "thanks"}


def screen_terms(screen):
    """Name-like screen tokens, as a cheap TermExtractor: CamelCase, acronyms, digits, or capitalized mid-sentence."""
    out = set(re.findall(r"\b[A-Za-z]*[a-z][A-Z]\w*|\b[A-Z]{2,}\w*|\b\w*\d\w*[A-Za-z]\w*", screen))
    out |= set(re.findall(r"(?<=[a-z,] )[A-Z][a-z]{2,}", screen))
    return {t for t in out if len(t) >= 3 and t.lower() not in STOP}


def word_in(term, text):
    return re.search(rf"(?<!\w){re.escape(term.lower())}(?!\w)", text.lower()) is not None


def row(transcript, screen, vocab):
    """One record's booleans and counts (never the text)."""
    words = re.findall(r"[\w']+", transcript)
    return {"words": len(words), "fillers": len(FILLER_RE.findall(transcript)),
            **{f: len(re.findall(rf"\b{f}\b", transcript, re.I)) for f in L.FILLERS},
            "punct": bool(re.search(r"[.!?]", transcript)), "lower": transcript == transcript.lower(),
            "cue": bool(CUE_RE.search(transcript)), "strong": bool(STRONG_RE.search(transcript)),
            "cancel": bool(CANCEL_RE.search(transcript)), "stutter": bool(STUTTER_RE.search(transcript)),
            "multi": bool(re.search(r"[.!?]\s+\S", transcript.strip())),
            "screen": None if screen is None else len(screen), "vocab": None if vocab is None else bool(vocab),
            "screenHit": None if screen is None else any(word_in(t, transcript) for t in screen_terms(screen)),
            "vocabHit": None if vocab is None else any(word_in(v, transcript) for v in vocab)}


def history_rows(files):
    recs = {}
    for f in files:
        for line in Path(f).read_text(errors="replace").splitlines():
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(r, dict) and r.get("type") == "request" and not (r.get("selection") or "") \
                    and isinstance(r.get("transcript"), str) and r["transcript"].strip():
                recs.setdefault(r.get("id"), r)
    for r in recs.values():
        users = [m for m in (r.get("messages") or []) if isinstance(m, dict) and m.get("role") == "user"]
        m = PROMPT.match(users[-1].get("content") or "") if users else None
        screen = html.unescape(m.group(1)) if m else None
        vocab = [html.unescape(v) for v in (m.group(2) or "").split(", ") if v] if m else None
        yield row(r["transcript"], screen, vocab)


def pool_rows(path):
    for line in Path(path).read_text().splitlines():
        it = json.loads(line) if line.strip() else {}
        if not str(it.get("cat", "")).startswith("d-") or it.get("selection"):
            continue
        ctx = it.get("context") or {}
        screen = "\n".join(s for s in (ctx.get("ocrText"), ctx.get("text")) if s)
        yield row(it["transcript"], screen, [v["text"] for v in it.get("vocabulary") or []])


def table(columns):
    """columns: [(name, rows)] → rows of strings: rates as whole percents, record counts rounded to tens."""
    def pct(rows, pred, base=lambda x: True):
        b = [x for x in rows if base(x)]
        return f"{round(100 * sum(1 for x in b if pred(x)) / len(b))}%" if b else "-"
    rng = lambda k, lo, hi: (lambda x: x[k] is not None and x[k] >= lo and (hi is None or x[k] <= hi))
    has = lambda k: (lambda x: x[k] is not None)
    lines = [("n (≈)", lambda rs: str(round(len(rs), -1))),
             ("n prompt (≈)", lambda rs: str(round(sum(1 for x in rs if x["screen"] is not None), -1)))]
    for lo, hi in WORD_BUCKETS:
        lines.append((f"words {lo}–{hi}" if hi else f"words {lo - 1}+", lambda rs, lo=lo, hi=hi: pct(rs, rng("words", lo, hi))))
    lines += [("sentence punctuation", lambda rs: pct(rs, lambda x: x["punct"])),
              ("all lowercase", lambda rs: pct(rs, lambda x: x["lower"])),
              ("fillers / 100 words", lambda rs: f"{100 * sum(x['fillers'] for x in rs) / max(1, sum(x['words'] for x in rs)):.1f}"),
              *((f"  {f} / 100 words", lambda rs, f=f: f"{100 * sum(x[f] for x in rs) / max(1, sum(x['words'] for x in rs)):.1f}")
                for f in L.FILLERS),
              ("prompt cue (no, sorry, actually…)", lambda rs: pct(rs, lambda x: x["cue"])),
              ("strong cue (no wait, I mean…)", lambda rs: pct(rs, lambda x: x["strong"])),
              ("cancel cue (#102)", lambda rs: pct(rs, lambda x: x["cancel"])),
              ("repeated adjacent word", lambda rs: pct(rs, lambda x: x["stutter"])),
              ("2+ sentences", lambda rs: pct(rs, lambda x: x["multi"])),
              ("any screen | prompt", lambda rs: pct(rs, lambda x: x["screen"] > 0, has("screen")))]
    for lo, hi in SCREEN_BUCKETS:
        lines.append((f"  screen {lo}–{hi} chars" if hi else f"  screen {lo - 1}+ chars",
                      lambda rs, lo=lo, hi=hi: pct(rs, rng("screen", lo, hi), has("screen"))))
    lines += [("any vocabulary | prompt", lambda rs: pct(rs, lambda x: x["vocab"], has("vocab"))),
              ("screen term in transcript | screen", lambda rs: pct(rs, lambda x: x["screenHit"], lambda x: bool(x["screen"]))),
              ("vocab term in transcript | vocab", lambda rs: pct(rs, lambda x: x["vocabHit"], lambda x: bool(x["vocab"])))]
    return [["", *(n for n, _ in columns)]] + [[label, *(f(rs) for _, rs in columns)] for label, f in lines]


def main(argv):
    hist, pools, i = [], [], 0
    while i < len(argv):
        if argv[i] == "--history":
            hist.append(argv[i + 1])
            i += 2
        else:
            pools.append(argv[i])
            i += 1
    files = [] if hist == ["none"] else hist or [f for f in HISTORY if f.exists()]
    columns = ([("real", list(history_rows(files)))] if files else []) + [(Path(p).stem, list(pool_rows(p))) for p in pools]
    rows = table(columns)
    w = [max(len(r[k]) for r in rows) for k in range(len(rows[0]))]
    for r in rows:
        print("  ".join(c.ljust(w[k]) if k == 0 else c.rjust(w[k]) for k, c in enumerate(r)))


if __name__ == "__main__":
    main(sys.argv[1:])
