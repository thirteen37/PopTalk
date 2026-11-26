#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Where dictation cleanup changes words (#126): aligns each transcript (after the pre-pass) with its output, word by
word, ignoring case and punctuation, and buckets every change. Prints counts and rates only, never text.

  word_changes.py [--by FIELD]... [FILE]   JSONL in (stdin if no FILE), one table out
  word_changes.py test                     self-test

A line is {user, output, ...} or {transcript, output, screen?, vocabulary?, ...}: `user` is the cleanup prompt's
user message (<screen>, <vocabulary>, <transcript>), as rendered for training or recorded by a replay. With
`phrases` (a list) instead of `output`, each phrase (a bench case's mustContain) is aligned to the stretch of the
transcript it matches, so only changes inside that stretch count. `--by` groups rows by a field; `len` is built in:
the transcript's word count, as <=5, 6-20 or >20.

Buckets, first rule that holds per change: filler (only fillers, hesitations, a word repeated right next to it or
a cut-off word removed), cue (a self-correction: a cue within 4 words, a restated stretch removed, or a value said
later put in place), term (a new word is a screen or vocabulary term:
capitalized, digits or mixed case on screen, or any vocabulary word), number (digits or number words on either
side), format (spelled letters, or spoken punctuation, list or address words removed: "at", "dot", "bullet"), then
other, split into function (only function words inserted, removed or swapped), homophone (lexicon.HOMOPHONES), form (same stem, contraction or irregular form:
"go" → "goes", "was" → "were", "it's" → "it is") and content."""
import difflib
import html
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lexicon as L  # noqa: E402

FILLERS = {"um", "uh", "er", "erm", "hm", "hmm", "mm", "ah", "like", "basically"}
FILLER_PAIRS = {("you", "know"), ("i", "mean")}
CUES = ["actually", "no", "sorry", "i mean", "i meant", "make that", "make it", "wait", "rather", "scratch that",
        "never mind", "nevermind", "forget that", "forget it", "instead", "correction", "oops"]
NUMBERS = set(("zero oh one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen "
               "sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred "
               "thousand million billion first second third fourth fifth sixth seventh eighth ninth tenth half "
               "quarter percent point am pm o'clock dollars dollar bucks k").split())
FORMAT = set("at dot slash dash hyphen underscore colon bullet point new line paragraph period comma question mark "
             "exclamation sign quote unquote open close paren parenthesis bracket hashtag hash star asterisk".split())
FUNCTION = set((
    "a an the this that these those my your his her its our their some any each every no all both "  # determiners
    "i me you he him she it we us they them myself yourself itself ourselves themselves mine yours ours theirs "
    "who whom whose which what "  # pronouns
    "is am are was were be been being have has had do does did will would shall should can could may might must "
    "'s 're 've 'll 'd 'm "  # auxiliaries
    "of in on at to for with from by about as into onto over under after before between through during "
    "without within up down off out than via per "  # prepositions
    "and or but so nor yet if because while when then though although also just too not n't").split())
CONTRACT = {"'s": ["is"], "'re": ["are"], "'ll": ["will"], "'ve": ["have"], "'d": ["would"], "'m": ["am"],
            "n't": ["not"]}
IRREGULAR = [set(g.split()) for g in (
    "be am is are was were been being", "have has had having", "do does did done doing", "go goes went gone going",
    "get gets got gotten getting", "make makes made making", "say says said saying", "take takes took taken",
    "come comes came coming", "see sees saw seen", "know knows knew known", "think thinks thought",
    "send sends sent sending", "can could", "will would", "shall should", "may might",
    "i me my mine", "we us our ours", "they them their theirs", "he him his", "she her hers",
    "this these", "that those", "a an")]
HOMOPHONES = {frozenset(p) for p in L.HOMOPHONES}
WORD = re.compile(r"[^\W_]+(?:'[^\W_]+)*")


def words(s):
    return WORD.findall(s.lower().replace("’", "'"))


def expand(ws):
    """Contractions spelled out: "it's" → "it is", "don't" → "do not" ("won't", "can't" → "will", "can")."""
    out = []
    for w in ws:
        for tail, full in CONTRACT.items():
            if w.endswith(tail) and len(w) > len(tail):
                head = w[: -len(tail)]
                out += [{"wo": "will", "ca": "can", "sha": "shall"}.get(head, head)] + full
                break
        else:
            out.append(w)
    return out


def stem(w):
    for suf in ("ies", "ing", "ed", "es", "s", "'s"):
        if w.endswith(suf) and len(w) - len(suf) >= 3:
            return w[: -len(suf)]
    return w


def same_form(a, b):
    return a != b and (stem(a) == stem(b) or (len(a) >= 4 and len(b) >= 4 and a[:4] == b[:4]
                                              and abs(len(a) - len(b)) <= 3) or any(a in g and b in g for g in IRREGULAR))


def only_fillers(ws):
    i = 0
    while i < len(ws):
        if tuple(ws[i:i + 2]) in FILLER_PAIRS:
            i += 2
        elif ws[i] in FILLERS:
            i += 1
        else:
            return False
    return True


def cue_near(old, i1, i2, span=4):
    near = " ".join(old[max(0, i1 - span):i2 + span])
    return any(re.search(rf"\b{re.escape(c)}\b", near) for c in CUES)


def is_number(w):
    return any(c.isdigit() for c in w) or w in NUMBERS


def other(a, b):
    """function, form or content, for a change of words a → b that no earlier bucket claims."""
    ea, eb = expand(a), expand(b)
    if len(a) == len(b) == 1 and frozenset(a + b) in HOMOPHONES:
        return "homophone"
    if a and b and (ea == eb or len(ea) == len(eb) and all(x == y or same_form(x, y) for x, y in zip(ea, eb))):
        return "form"
    return "function" if all(w in FUNCTION for w in a + b) else "content"


def changes(old, new, terms=frozenset(), formatted=False):
    """The bucket of each word-level change from old to new (word lists)."""
    out = []
    sm = difflib.SequenceMatcher(None, old, new, autojunk=False)
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == "equal":
            continue
        a, b = old[i1:i2], new[j1:j2]
        after = old[i2:]
        repeat = a and (after[:len(a)] == a or old[max(0, i1 - len(a)):i1] == a
                        or len(a) == 1 and after and after[0] != a[0] and after[0].startswith(a[0]))  # "the pres presentation"
        restated = len(a) >= 3 and sum(w in after[:len(a) + 3] for w in a) >= 0.6 * len(a)  # said again, changed
        moved = b and not all(w in FUNCTION for w in b) and all(w in after for w in b)  # a later fix put in place
        if not b and (only_fillers(a) or repeat):
            out.append("filler")
        elif cue_near(old, i1, i2) or (not b and restated) or moved:
            out.append("cue")
        elif sum(len(w) == 1 and w.isalpha() for w in a) >= max(2, len(a) - 1):  # spelled letters (and a misheard try)
            out.append("format")
        elif any(w in terms for w in b) or ("".join(b) in terms and b):
            out.append("term")
        elif any(map(is_number, a + b)):
            out.append("number")
        elif formatted and not b and all(w in FORMAT for w in a):
            out.append("format")
        else:
            out.append(other(a, b))
    return out


def parse(row):
    """(transcript, screen, vocabulary) from a row's prompt user message or its own fields."""
    if u := row.get("user"):
        tag = lambda t: (m.group(1) if (m := re.search(rf"<{t}\b[^>]*>(.*?)</{t}>", u, re.S)) else "")
        return html.unescape(tag("transcript")), html.unescape(tag("screen")), html.unescape(tag("vocabulary"))
    return row["transcript"], row.get("screen") or "", ", ".join(row.get("vocabulary") or [])


def term_set(screen, vocabulary):
    caps = {w for w in re.findall(r"[\w'.@-]+", screen) if re.search(r"[A-Z0-9]", w)}
    return frozenset({w for t in caps for w in words(t)} - FUNCTION) | frozenset(words(vocabulary))


def classify(row):
    t, screen, vocab = parse(row)
    old, terms = words(t), term_set(screen, vocab)
    if "phrases" in row:
        out = []
        for p in row["phrases"]:
            if p.lower() in t.lower():  # as said, or part of a word said ("nvite")
                continue
            new = words(p)
            blocks = [b for b in difflib.SequenceMatcher(None, old, new, autojunk=False).get_matching_blocks() if b.size]
            # No word of it in the transcript ("FluidAudio" for "fluid audio"): the whole phrase is an insert.
            out += changes(old[blocks[0].a:blocks[-1].a + blocks[-1].size] if blocks else [], new, terms)
        return len(old), out
    y = row.get("output") or ""
    formatted = bool(re.search(r"[@/_]|\w\.\w|^\s*([-*]|\d+\.) ", y, re.M))
    return len(old), changes(old, words(y), terms, formatted)


OTHER = ["function", "form", "homophone", "content"]
BUCKETS = ["filler", "cue", "term", "number", "format"] + OTHER


def length_bin(n):
    return "<=5" if n <= 5 else "6-20" if n <= 20 else ">20"


def table(rows, by):
    groups, items, with_other = defaultdict(Counter), Counter(), Counter()
    for row in rows:
        n, cs = classify(row)
        key = tuple(length_bin(n) if f == "len" else str(row.get(f, "")) for f in by) or ("all",)
        for k in (key, ("total",) * max(1, len(by))):
            groups[k].update(cs)
            items[k] += 1
            with_other[k] += any(c in OTHER for c in cs)
    order = sorted((k for k in groups if k[0] != "total"),
                   key=lambda k: -sum(groups[k][b] for b in OTHER))
    head = (by or ["set"]) + ["items"] + BUCKETS + ["other", "other/100", "items w/ other", "%"]
    lines = [head]
    for k in order + [("total",) * max(1, len(by))]:
        c, n = groups[k], items[k]
        o = sum(c[b] for b in OTHER)
        lines.append(list(k) + [n] + [c[b] for b in BUCKETS] + [o, f"{100 * o / n:.1f}", with_other[k],
                                                                    f"{100 * with_other[k] / n:.1f}"])
    widths = [max(len(str(r[i])) for r in lines) for i in range(len(head))]
    return "\n".join("  ".join(str(v).ljust(w) for v, w in zip(r, widths)).rstrip() for r in lines)


def test():
    c = lambda t, y, **kw: classify({"transcript": t, "output": y, **kw})[1]
    assert c("um so the build is green", "So the build is green.") == ["filler"]
    assert c("send it you know by friday", "Send it by Friday.") == ["filler"]
    assert c("send the the slides", "Send the slides.") == ["filler"]
    assert c("meet on tuesday no thursday", "Meet on Thursday.") == ["cue"]
    assert c("call two pm sorry four pm", "Call four PM.") == ["cue"]
    assert c("review the fluid audio pr", "Review the FluidAudio PR.", screen="PR for FluidAudio?") == ["term"]
    assert c("ping dmitry", "Ping Dmitri.", vocabulary=["Dmitri"]) == ["term"]
    assert c("book it for three people", "Book it for 3 people.") == ["number"]
    assert c("mail john at example dot com", "Mail john@example.com.") == ["format", "format"]
    assert c("he go to the store", "He goes to the store.") == ["form"]
    assert c("they was late", "They were late.") == ["form"]
    assert c("it's done", "It is done.") == ["form"]
    assert c("we going home", "We are going home.") == ["function"]
    assert c("i went to store", "I went to the store.") == ["function"]
    assert c("can you check", "Could you check?") == ["form"]  # can/could: one modal, two tenses
    assert c("send a link", "Send the link.") == ["function"]
    assert c("the cat sat", "The dog sat.") == ["content"]
    assert c("put it over their", "Put it over there.") == ["homophone"]
    assert c("send the pres presentation", "Send the presentation.") == ["filler"]
    assert c("book the room for monday book the room for friday", "Book the room for Friday.") == ["cue"]
    assert c("move it to monday the venue confirmed oh i meant friday",
             "Move it to Friday. The venue confirmed.") == ["cue", "cue"]  # in place, then the cue and value go
    assert c("i'm casey c a s e y", "I'm Casey.") == ["format"]
    assert c("i'm kasey k a y l a", "I'm Kayla.") == ["format"]
    assert c("Keep it as said.", "keep it, as said") == []
    assert classify({"transcript": "call priya about the q three okrs", "phrases": ["the Q 3 OKRs", "Q3"]})[1] == ["number"] * 2
    assert classify({"transcript": "he go home now", "phrases": ["he goes home", "ome"]})[1] == ["form"]
    assert c("ask soren", "Ask Søren.", screen="Søren: hi") == ["term"]
    assert classify({"user": "<screen app=\"A\" window=\"W\">\nHi Kestrel &amp; co\n</screen>\n<transcript>ask kestral</transcript>",
                     "output": "Ask Kestrel."})[1] == ["term"]
    rows = [{"transcript": "he go home", "output": "He goes home.", "cat": "x"}, {"transcript": "ok", "output": "OK.", "cat": "y"}]
    t = table(rows, ["cat"]).splitlines()
    assert t[1].split()[:2] == ["x", "1"] and t[-1].split()[0] == "total", t
    print("word_changes self-test ok")


def main(argv):
    if argv[:1] == ["test"]:
        return test()
    by, files = [], []
    it = iter(argv)
    for a in it:
        if a == "--by":
            by.append(next(it))
        else:
            files.append(a)
    src = open(files[0]) if files else sys.stdin
    print(table((json.loads(line) for line in src if line.strip()), by))


if __name__ == "__main__":
    main(sys.argv[1:])
