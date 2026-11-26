#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Counts-only look at grouped spoken numbers (#125) in replayed history dictations. Driven by number-counts.zsh.
  number-counts.py filter < in.jsonl > subset.jsonl   replay inputs whose transcript has two number words in a row
  number-counts.py count out.jsonl                    per form: instances, raw fallbacks, and how the output wrote them
  number-counts.py test                               self-test on invented text
Forms, found in the transcript the model saw (`user`'s <transcript>, after the prepass), left to right:
  time    "at" + an hour and minutes ("at three thirty")                 written: 3:30
  cue     a cue word + 2+ digit words ("number four five six")           written: number 456
  run     3+ digit words, no cue ("one two three")                       written: as said
  groups  3+ number groups ("ten twenty thirty")                         written: as said
  pair    two groups ("one twenty", "twenty twenty six", "20 oh five")   written: 120, 2026, 2005 (not "... and 14")
  money   "twelve dollars fifty", as the prepass leaves it ("$12 50")     written: $12.50
Outcomes (outputs that aren't raw fallbacks): right (the table's form), words (said as words), wrong (a known wrong
digit form: "1 20", "1:20" for a pair, "330" for a time, "4 5 6" for a cue run, "$12 50", any digits for run/groups),
other. Pairs are the riskiest: "two twenty minute calls" counts as a pair, so "right" there is the table's form.
Never prints transcripts or outputs."""
import html
import json
import re
import sys
from collections import Counter

U = "one two three four five six seven eight nine".split()
T = "ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
X = "twenty thirty forty fifty sixty seventy eighty ninety".split()
VAL = {w: i + 1 for i, w in enumerate(U)} | {w: i + 10 for i, w in enumerate(T)} | {w: (i + 2) * 10 for i, w in enumerate(X)}
CUES = "issue number version v page step room item pr option q code".split()
alt = lambda ws: "(?:" + "|".join(ws) + r")\b"  # whole words: "four" isn't the start of "fourteen"
GROUP = rf"(?>{alt(X)}(?:[ -]{alt(U)})?|{alt(T)}|{alt(U)})"  # one number group: "twenty six", "twelve", "two"
MIN = rf"(?:{alt(X)}(?:[ -]{alt(U)})?|{alt(T)}|oh[ -]{alt(U)})"  # a second group: two digits, or "oh five"
DIGIT = alt(U + ["zero", "oh"])
NUMWORD = alt(U + T + X)
PATTERNS = [  # (form, regex); earlier forms win where they overlap
    ("time", rf"\bat (?P<h>{alt(U + ['ten', 'eleven', 'twelve'])}|1?\d(?= oh\b)) (?P<m>{MIN})\b(?! {alt(U + T + X + ['oh'])}\b)"),
    ("cue", rf"\b(?P<cue>{alt(CUES)}) (?P<d>{DIGIT}(?: {DIGIT})+)\b"),
    ("run", rf"\b{alt(U)}(?: {alt(U)}){{2,}}\b"),
    ("groups", rf"\b{GROUP}(?: {GROUP}){{2,}}\b"),
    ("pair", rf"\b(?P<a>{GROUP}|\d{{1,2}}(?= oh\b)) (?P<b>{MIN})\b(?! and (?:{NUMWORD}|\d))"),  # not a list
    ("money", r"\$(?P<d>\d+) (?P<c>\d\d)\b"),  # "twelve dollars fifty", as the prepass leaves it: "$12 50"
]
FORMS = [f for f, _ in PATTERNS]
RAW = re.compile(rf"\b{NUMWORD} (?:{NUMWORD}|oh)\b|\bdollars? {NUMWORD}\b", re.I)


def value(g):
    """A number group's value: "twenty six" → 26, "oh five" → 5, "20" → 20."""
    return int(g) if g.isdigit() else sum(VAL.get(w, 0) for w in re.split(r"[ -]", g))


def find(t):
    """[(form, span, expected written form or None)] for the grouped forms in transcript t, left to right."""
    t, taken, out = t.lower(), [], []
    for form, rx in PATTERNS:
        for m in re.finditer(rx, t):
            if any(m.start() < e and s < m.end() for s, e in taken):
                continue
            if form == "time" and value(m["m"]) > 59:
                continue
            taken.append(m.span())
            exp = {"time": lambda: f"{value(m['h'])}:{value(m['m']):02d}",
                   "cue": lambda: m["cue"] + " " + "".join(str(VAL.get(w, 0)) for w in m["d"].split()),
                   "pair": lambda: f"{value(m['a'])}{value(m['b']):02d}", "money": lambda: f"${m['d']}.{m['c']}"}.get(form, lambda: None)()
            out.append((form, m.group(0), exp, m))
    return sorted(out, key=lambda x: x[3].start())


def outcome(form, span, exp, m, output):
    o = output.lower()
    flat = re.sub(r"\s+", " ", re.sub(r"[-,.]", " ", o))
    has = lambda s: re.search(rf"(?<![\d.:,]){re.escape(s)}(?![\d:])", o) is not None
    if form in ("run", "groups"):
        if span.replace("-", " ") in flat:
            return "right"
        return "wrong" if re.search(r"\d", o) else "other"
    if form == "cue":
        cue, digits = exp.split(" ")
        if re.search(rf"\b{cue}\W*#?{digits}\b", o):
            return "right"
        if re.search(rf"\b{cue}\W*" + r"[ ,-]+".join(digits), o):
            return "wrong"
    elif form == "pair":
        a, b = value(m["a"]), value(m["b"])
        if has(exp) or has(f"{exp[:-3]},{exp[-3:]}" if len(exp) == 4 else exp):
            return "right"
        if any(has(s) for s in (f"{a} {b}", f"{a}:{b:02d}", f"{a}.{b:02d}", f"{a} {b:02d}")):
            return "wrong"
    elif form == "money":
        if exp in o:
            return "right"
        if re.search(rf"\${m['d']}\W*{m['c']}\b", o):
            return "wrong"
    elif form == "time":
        if has(exp):
            return "right"
        h, mm = exp.split(":")
        if any(has(s) for s in (h + mm, f"{h} {int(mm)}", f"{h}.{mm}")):
            return "wrong"
    return "words" if re.sub(r"\s+", " ", span.replace("-", " ")) in flat else "other"


def said(row):
    m = re.search(r"<transcript>(.*?)</transcript>", row.get("user") or "", re.S)
    return html.unescape(m.group(1)) if m else None


def count(path):
    rows = [json.loads(l) for l in open(path) if l.strip()]
    n, hit, c = Counter(), 0, {f: Counter() for f in FORMS}
    for row in rows:
        t = said(row)
        if t is None:
            n["no transcript"] += 1
            continue
        found = find(t)
        hit += bool(found)
        raw = "(raw)" in (row.get("label") or "")
        for form, span, exp, m in found:
            c[form]["n"] += 1
            c[form]["raw" if raw else outcome(form, span, exp, m, row.get("output") or "")] += 1
    print(f"replayed {len(rows)}, with a grouped form {hit}" + (f", no transcript {n['no transcript']}" if n else ""))
    cols = ["n", "raw", "right", "words", "wrong", "other"]
    print("\t".join(["form"] + cols))
    for f in FORMS:
        print("\t".join([f] + [str(c[f][k]) for k in cols]))


def test():
    f = lambda t: [(x[0], x[2]) for x in find(t)]
    assert f("we meet at three thirty by the gate") == [("time", "3:30")]
    assert f("we meet at one seventy") == [("pair", "170")]  # not a clock time
    assert f("open since twenty fourteen") == [("pair", "2014")] and f("closes at 10 oh four") == [("time", "10:04")]
    assert f("skip counts twenty forty sixty eighty") == [("groups", None)]
    assert f("seats one twenty guests") == [("pair", "120")]
    assert f("in twenty twenty six") == [("pair", "2026")] and f("in 20 oh five") == [("pair", "2005")]
    assert f("built in nineteen ninety nine") == [("pair", "1999")] and f("suite two oh five") == [("pair", "205")]
    assert f("my locker is number four five six") == [("cue", "number 456")]
    assert f("code one two three") == [("cue", "code 123")]
    assert f("she said one two three") == [("run", None)] and f("ten twenty thirty go") == [("groups", None)]
    assert f("twenty five people and one or two more") == [] and f("sizes ten twelve and 14") == []
    assert f("takes $12 50 today") == [("money", "$12.50")]
    o = lambda t, out: outcome(*find(t)[0], out)
    assert o("seats one twenty guests", "Seats 120 guests.") == "right"
    assert o("seats one twenty guests", "Seats 1 20 guests.") == "wrong"
    assert o("seats one twenty guests", "Seats one-twenty guests.") == "words"
    assert o("climbs twelve fifty meters", "Climbs 1,250 meters.") == "right"
    assert o("at three thirty", "At 330.") == "wrong" and o("at three thirty", "At 3:30.") == "right"
    assert o("number four five six", "Number 456.") == "right" and o("number four five six", "Number 4-5-6.") == "wrong"
    assert o("she said one two three", "She said one, two, three.") == "right"
    assert o("she said one two three", "She said 123.") == "wrong"
    assert RAW.search("One twenty") and not RAW.search("one of two")
    print("number-counts self-test ok")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "filter":
        k = 0
        for line in sys.stdin:
            if line.strip() and RAW.search(json.loads(line).get("transcript") or ""):
                sys.stdout.write(line)
                k += 1
        print(f"filter: {k} dictations with two number words in a row", file=sys.stderr)
    elif cmd == "count":
        count(sys.argv[2])
    elif cmd == "test":
        test()
    else:
        sys.exit(__doc__)
