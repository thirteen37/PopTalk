#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Training items for the Poptalk cleanup/edit fine-tune (#21). Run from the repo root via make_data.zsh.

  gen.py speak            → out/speak.jsonl       dictation items to synthesize and transcribe (PoptalkDatagen transcribe)
  gen.py teach            → out/teach.jsonl       edit items whose target comes from the E4B teacher
  gen.py build            → out/items.jsonl       every item with its target, filtered and contamination-checked
  gen.py split            → out/data/{train,valid}.jsonl from out/rendered.jsonl (PoptalkDatagen render)
  gen.py check            → asserts the v5 and v6 families are registered and shaped right (writes nothing)

Dictation targets are the clean source text; edit targets are exact where programmatic, else the
teacher's reply after checks. Items: {id, cat, transcript, selection?, context?, vocabulary?, target}."""
import difflib
import html
import json
import random
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lexicon as L  # noqa: E402
from contamination import Checker  # noqa: E402

OUT = Path("training/out")
VOICES = ["Samantha", "Daniel", "Karen", "Moira", "Rishi", "Aman", "Fred", "Kathy", "Ralph", "Eddy (English (US))",
          "Flo (English (UK))", "Reed (English (UK))", "Sandy (English (US))", "Shelley (English (UK))"]
RATES = [None, None, 160, 200, 230]


def R(seed):  # each stage gets its own stream so stages don't shift each other
    return random.Random(f"poptalk-21-{seed}")


# ---------- entities ----------

def invented(r):
    p, s = r.choice(L.PREFIX), r.choice(L.SUFFIX)
    kind = r.random()
    if kind < 0.45:
        name = p + (s.capitalize() if len(s) > 3 else s)
        alias = [f"{p.lower()} {s}", (p + s).lower()]
        return name, alias, "product"
    if kind < 0.8:
        word = p + s if len(s) <= 3 else p
        name = f"{word} {r.choice(L.COMPANY_TAIL)}"
        alias = [name.lower(), f"{word[:len(p)].lower()} {word[len(p):].lower()} {name.split()[1].lower()}".replace("  ", " ")]
        return name, alias, "company"
    name = f"{r.choice(L.PROJECT_HEAD)} {p}" if r.random() < 0.5 else f"{p} {r.choice(['Roadmap', 'Pilot', 'Rewrite', 'Migration', 'Launch'])}"
    return name, [name.lower()], "project"


def person(r, surname=False):
    f, fa = r.choice(L.PEOPLE)
    if not surname:
        return f, fa, "person"
    s, sa = r.choice(L.SURNAMES)
    return f"{f} {s}", [f"{r.choice(fa)} {r.choice(sa)}", f"{f.lower()} {r.choice(sa)}"], "person"


def tech(r):
    t, ta = r.choice(L.TECH)
    return t, ta, "product"


def fill(r, template):
    """Fills slots; returns (text, entities) where entities are (written, aliases, kind)."""
    ents = []
    def ent(e):
        ents.append(e)
        return e[0]
    slots = {"P": lambda: ent(person(r)), "P2": lambda: ent(person(r)), "S": lambda: ent((lambda s: (s[0], s[1], "person"))(r.choice(L.SURNAMES))),
             "T": lambda: ent(tech(r)), "T2": lambda: ent(tech(r)), "C": lambda: ent(invented(r)),
             "PRJ": lambda: ent((lambda e: e if e[2] == "project" else (f"Project {e[0].split()[0]}", [f"project {e[0].split()[0].lower()}"], "project"))(invented(r))),
             "D": lambda: r.choice(L.DAYS), "TM": lambda: r.choice(L.TIMES), "N": lambda: r.choice(L.NUMBERS),
             "M": lambda: r.choice(L.MONTHS), "PL": lambda: r.choice(L.PLACES)}
    text = re.sub(r"\{(\w+)\}", lambda m: slots[m.group(1)](), template)
    return text, [e for e in ents if e[0] in text]


# ---------- screen context ----------

def mention(r, e):
    who = person(r)[0]
    n, kind = e[0], e[2]
    if kind == "person":
        return r.choice([f"{n}: sounds good, I'll take it", f"cc {n}", f"{n} joined the channel", f"Owner: {n}",
                         f"{n}: can we sync later today?", f"From: {n}", f"Assigned to {n}", f"{who}: thanks {n}!"])
    return r.choice([f"{who}: has anyone tried {n} yet?", f"{who}: the {n} rollout is next", f"Re: {n} renewal",
                     f"{n} — status: in review", f"{who}: notes from the {n} sync are up", f"Tags: {n}, backlog",
                     f"{who}: {n} is down again", f"Our new partner is {n}." if kind == "company" else f"Docs: {n} setup guide"])


def distractors(r, k):
    pool = [person(r), person(r, True), tech(r), invented(r), invented(r), tech(r)]
    return r.sample(pool, k)


def context(r, ents, n_distract=None, long=False):
    """A screen snapshot that mentions `ents` among distractors, as the app captures it."""
    n_distract = r.randint(1, 4) if n_distract is None else n_distract
    lines = [mention(r, e) for e in ents] + [mention(r, d) for d in distractors(r, n_distract)]
    r.shuffle(lines)
    app, win = r.choice(L.APPS)
    win = win.format(ch=r.choice(L.CHANNELS), p=person(r)[0], prj=invented(r)[0], c=invented(r)[0])
    if app == "Slack":
        body = f"{win} — " + " ".join(l if ":" in l else l + "." for l in lines)
    elif app == "Mail":
        body = "\n".join(lines)
    else:
        body = " ".join(l if l[-1] in ".!?" else l + "." for l in lines)
    ctx = {}
    if r.random() < 0.5:
        ctx.update(appName=app, windowTitle=win)
    if long or r.random() < 0.15:
        filler = [r.choice(L.FILLER) for _ in range(r.randint(25, 70))]
        pos = r.randint(0, len(filler))
        doc = filler[:pos] + [body] + filler[pos:]
        if r.random() < 0.3:  # OCR'd thread around a short field, like a chat reply box
            ctx.update(text=r.choice(["Got it, ", "", "Sounds good. ", "Re: "]), ocrText="\n".join(doc))
            ctx["cursorOffset"] = len(ctx["text"].encode("utf-16-le")) // 2
        else:
            text = " ".join(doc)
            ctx.update(text=text, cursorOffset=len(text[: r.randint(len(text) // 3, len(text))].encode("utf-16-le")) // 2)
    else:
        ctx["text"] = body
    return ctx


def unrelated_context(r):
    return context(r, [], n_distract=r.randint(2, 5)) if r.random() < 0.7 else {}


# ---------- spoken forms ----------

def lower_transcript(s):
    """What a typed or unpunctuated recognizer transcript looks like: lowercase, no punctuation."""
    s = re.sub(r"[^\w\s'’-]", " ", s.lower())
    return re.sub(r"\s+", " ", s).strip()


def add_fillers(r, s, k=None):
    ws = s.split()
    for _ in range(k if k is not None else r.randint(1, 2)):
        f = r.choice(L.FILLERS)
        i = r.choice([0, 0] + [j for j, w in enumerate(ws) if w.endswith(",")] + [r.randint(1, max(1, len(ws) - 1))])
        ws.insert(i if i == 0 else i + 1 if ws[min(i, len(ws) - 1)].endswith(",") else i, f + ("," if i == 0 else ""))
    out = " ".join(ws)
    return out[0].upper() + out[1:] if out else out


def slot_pool(kind):
    return {"day": L.DAYS, "time": L.TIMES, "num": L.NUMBERS, "place": L.PLACES, "month": L.MONTHS,
            "person": [p for p, _ in L.PEOPLE if p.isascii()]}[kind]


def correction(r):
    """(spoken, clean) for a self-correction like "on Tuesday, no, Thursday"."""
    tmpl, kind = r.choice(L.CORRECTABLE)
    a, b = r.sample(slot_pool(kind), 2)
    cue = r.choice(L.CUES)
    spoken = tmpl.replace("{X}", f"{a}, {cue}, {b}" if r.random() < 0.5 else f"{a} {cue} {b}")
    return spoken, tmpl.replace("{X}", b)


def disfluent(r):
    """(spoken, clean, category)."""
    x = r.random()
    if x < 0.45:
        s, c = correction(r)
        return (add_fillers(r, s, 1) if r.random() < 0.3 else s), c, "d-correction"
    if x < 0.7:
        c = r.choice(L.PLAIN) if r.random() < 0.6 else fill(r, r.choice(L.NAMED))[0]
        return add_fillers(r, c), c, "d-filler"
    if x < 0.85:
        c = r.choice(L.KEEP)
        return c, c, "d-keep"
    c = r.choice(L.ASKS)
    return (add_fillers(r, c, 1) if r.random() < 0.3 else c), c, "d-question"


# ---------- dictation ----------

def speak_items():
    """Utterances to synthesize: names with their context, plus plain/disfluent speech."""
    r, items = R("speak"), []
    for i in range(1100):
        clean, ents = fill(r, r.choice(L.NAMED))
        spoken = add_fillers(r, clean, 1) if r.random() < 0.2 else clean
        items.append({"id": f"sp-named-{i}", "cat": "d-names-audio", "speak": spoken, "target": clean,
                      "context": context(r, ents, long=r.random() < 0.2), "voice": r.choice(VOICES), "rate": r.choice(RATES),
                      "terms": [e[0] for e in ents]})
    for i in range(500):
        spoken, clean, cat = disfluent(r)
        items.append({"id": f"sp-plain-{i}", "cat": cat + "-audio", "speak": spoken, "target": clean,
                      "context": unrelated_context(r), "voice": r.choice(VOICES), "rate": r.choice(RATES), "terms": []})
    return items


def norm(s):
    return re.findall(r"[\w']+", s.lower().replace("-", " ").replace("’", "'"))


def heard_ok(spoken, heard, ctx_terms):
    """True when every difference between what was said and what was heard is a context term
    (a misrecognition the context can fix) or a dropped hesitation."""
    allowed = {w for t in ctx_terms for w in norm(t)} | {"um", "uh"}
    sm = difflib.SequenceMatcher(a=norm(spoken), b=norm(heard), autojunk=False)
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        # "standup" vs "stand up" is fine; "four" vs "4" is not (the model would learn to respell numbers).
        if op != "equal" and not set(sm.a[i1:i2]) <= allowed and "".join(sm.a[i1:i2]) != "".join(sm.b[j1:j2]):
            return False
    return True


def ctx_terms(ctx):
    """Capitalized/odd tokens on screen, as a cheap stand-in for TermExtractor."""
    text = (ctx.get("text") or "") + " " + (ctx.get("ocrText") or "")
    return set(re.findall(r"[\w.+'-]*[A-Z0-9][\w.+'-]*", text))


def audio_dictation(speak, heard):
    out, dropped = [], 0
    for it in speak:
        h = heard.get(it["id"])
        if not h:
            continue
        terms = set(it["terms"]) | ctx_terms(it["context"])
        if not heard_ok(it["speak"], h["boosted"], terms):
            dropped += 1
            continue
        out.append({"id": it["id"], "cat": it["cat"], "transcript": h["boosted"], "context": it["context"], "target": it["target"]})
    print(f"audio: {len(out)} kept, {dropped} dropped (misheard beyond what context fixes)", file=sys.stderr)
    return out


def text_dictation():
    """Typed/unpunctuated transcripts with names misheard toward forms the context can fix."""
    r, out = R("text-dict"), []
    for i in range(900):
        clean, ents = fill(r, r.choice(L.NAMED))
        spoken = add_fillers(r, clean, 1) if r.random() < 0.3 else clean
        for e in ents:  # every misheard entity must be fixable from the screen
            if r.random() < 0.75:
                spoken = spoken.replace(e[0], r.choice(e[1]), 1)
        t = lower_transcript(spoken) if r.random() < 0.7 else spoken
        if r.random() < 0.12:  # saved vocabulary instead of the screen
            vocab = [{"text": e[0], "aliases": [], "weight": 10} for e in ents] + \
                    [{"text": d[0], "aliases": [], "weight": 10} for d in distractors(r, 2)]
            r.shuffle(vocab)
            out.append({"id": f"tx-vocab-{i}", "cat": "d-names-vocab", "transcript": t, "context": unrelated_context(r),
                        "vocabulary": vocab, "target": clean})
        else:
            out.append({"id": f"tx-named-{i}", "cat": "d-names-text", "transcript": t,
                        "context": context(r, ents, long=r.random() < 0.25), "target": clean})
    for i in range(1000):
        spoken, clean, cat = disfluent(r)
        out.append({"id": f"tx-plain-{i}", "cat": cat + "-text", "transcript": lower_transcript(spoken) if r.random() < 0.8 else spoken,
                    "context": unrelated_context(r), "target": clean})
    for i in range(250):  # a word on screen as part of a name, spoken as a plain word: keep it plain
        clean = r.choice(L.PLAIN)
        w = r.choice([w for w in re.findall(r"[a-z]{4,}", clean) if w not in {"that", "this", "with", "from", "they"}] or ["team"])
        trap = (w.capitalize() + r.choice(["ly", "ify", "Stack", "Labs", " Works"]), [], "product")
        out.append({"id": f"tx-echo-{i}", "cat": "d-no-echo", "transcript": lower_transcript(clean),
                    "context": context(r, [trap], long=r.random() < 0.2), "target": clean})
    for i in range(200):  # several sentences, usually ending in a question or request: keep every one (#47)
        parts = r.sample(L.PLAIN, r.randint(1, 2)) + [r.choice(L.ASKS)]
        if r.random() < 0.25:
            r.shuffle(parts)
        spoken = " ".join(add_fillers(r, p, 1) if r.random() < 0.3 else p for p in parts)
        out.append({"id": f"tx-multi-{i}", "cat": "d-multi-text", "transcript": lower_transcript(spoken) if r.random() < 0.8 else spoken,
                    "context": unrelated_context(r), "target": " ".join(parts)})
    return out


# ---------- edits ----------

def ej(action, text, vocab=None, remember=False):
    return json.dumps({"action": action, "text": text, "vocabulary": vocab, "remember": remember},
                      ensure_ascii=False, separators=(",", ":"))


def spell(name, r):
    parts = re.findall(r"[A-Z]?[a-z0-9]+|[A-Z]+(?![a-z])", name)
    sep = "-" if r.random() < 0.7 else " "
    letters = [sep.join(p.upper()) for p in parts]
    if name.islower():
        return "lowercase " + sep.join(name.upper())
    if len(parts) > 1:
        return ", ".join(("capital " if p[0].isupper() else "") + l for p, l in zip(parts, letters))
    return ("capital " if r.random() < 0.4 else "") + letters[0]


def cap(s):
    return s[0].upper() + s[1:] if s else s


def sentence(s):
    s = cap(s.strip())
    return s if s[-1:] in ".!?" else s + "."


def edit_ctx(r):
    return unrelated_context(r) if r.random() < 0.4 else {}


BEFORE = ["hi everyone", "quick update", "good morning team", "heads up", "sorry for the delay", "this is still a draft",
          "as discussed yesterday", "one more thing", "hope you had a great weekend", "welcome to the team"]


def program_edits():
    r, out = R("edits"), []
    add = lambda cat, i, t, sel, ctx, target: out.append(
        {"id": f"{cat}-{i}", "cat": cat, "transcript": t, "selection": sel, "context": ctx, "target": target})

    spellable = [e for e in [person(r) for _ in range(300)] + [invented(r) for _ in range(300)] + [tech(r) for _ in range(200)]
                 if re.fullmatch(r"[A-Za-z0-9]+", e[0])]
    for i in range(450):  # spelled corrections of a single term
        n, aliases, _ = r.choice(spellable)
        sel = r.choice(aliases)
        if sel.replace(" ", "") == n.lower() and r.random() < 0.5:
            sel = n.lower()
        t = r.choice(L.SPELL_INTRO).format(n=n, s=spell(n, r))
        rem = r.random() < 0.12
        if rem:
            t += r.choice(L.REMEMBER)
        if r.random() < 0.3:
            t = cap(t)
        add("e-correct-spelled", i, t, sel, edit_ctx(r) if r.random() < 0.7 else context(r, [(n, [], "x")]),
            ej("correct", n, {"text": n, "aliases": [sel.lower()]}, rem))

    for i in range(450):  # correct a misheard name from the screen, often far from the cursor
        e = r.choice([person(r, r.random() < 0.4), invented(r), invented(r), tech(r)])
        kind = "company" if e[2] == "company" else e[2] if e[2] in L.CONTEXT_FIX else "product"
        sel = r.choice(e[1])
        if sel.replace(" ", "") == e[0].lower().replace(" ", "") and " " not in sel and " " not in e[0]:
            sel = sel[: len(sel) // 2] + " " + sel[len(sel) // 2:]
        add("e-correct-context", i, r.choice(L.CONTEXT_FIX[kind]), sel, context(r, [e], long=r.random() < 0.45),
            ej("correct", e[0], {"text": e[0], "aliases": [sel.lower()]}))

    def typo(w):
        j = r.randrange(1, len(w) - 1)
        return r.choice([w[:j] + w[j + 1] + w[j] + w[j + 2:], w[:j] + w[j + 1:], w[:j] + w[j] + w[j:]])
    for i in range(200):  # typos
        clean = r.choice(L.PLAIN) if r.random() < 0.5 else fill(r, r.choice(L.NAMED))[0]
        ws = clean.split()
        cand = [j for j, w in enumerate(ws) if re.fullmatch(r"[a-z]{5,}", w)]
        if not cand:
            continue
        for j in r.sample(cand, min(len(cand), r.randint(1, 2))):
            ws[j] = typo(ws[j])
        if " ".join(ws) == clean:
            continue
        add("e-correct-typo", i, r.choice(L.TYPO), " ".join(ws), edit_ctx(r), ej("correct", clean))

    grammar = [("the reports is ready for review", "The reports are ready for review."),
               ("{P} have went to the {T} meetup twice", "{P} has gone to the {T} meetup twice."),
               ("we should of asked {P} first", "We should have asked {P} first."),
               ("their going to update the {T} config", "They're going to update the {T} config."),
               ("there is less bugs in this release", "There are fewer bugs in this release."),
               ("{P} don't like the new layout", "{P} doesn't like the new layout."),
               ("whose going to the {C} dinner", "Who's going to the {C} dinner?"),
               ("i seen the {T} logs this morning", "I saw the {T} logs this morning."),
               ("can you sends the file to {P}", "Can you send the file to {P}?"),
               ("we was planning to migrate to {T}", "We were planning to migrate to {T}."),
               ("{P} and {P2} is leading the {PRJ} work", "{P} and {P2} are leading the {PRJ} work."),
               ("its a easy fix for the {T} bug", "It's an easy fix for the {T} bug."),
               ("the team have finish the migration", "The team has finished the migration."),
               ("if i was you i would ask {P}", "If I were you, I would ask {P}."),
               ("each of the designers have a laptop", "Each of the designers has a laptop."),
               ("{P} could of fixed it yesterday", "{P} could have fixed it yesterday."),
               ("the data from {C} are wrong", "The data from {C} is wrong."),
               ("we doesn't need another {T} license", "We don't need another {T} license."),
               ("between you and i the demo was rough", "Between you and me, the demo was rough."),
               ("the {C} servers was down all night", "The {C} servers were down all night.")]
    for i in range(160):
        bad, good = r.choice(grammar)
        vals = {}
        def sub(m):
            k = m.group(1)
            if k not in vals:
                vals[k] = fill(r, "{" + k + "}")[0]
            return vals[k]
        bad_s, good_s = re.sub(r"\{(\w+)\}", sub, bad), re.sub(r"\{(\w+)\}", sub, good)
        add("e-correct-grammar", i, r.choice(L.GRAMMAR), bad_s, edit_ctx(r), ej("correct", good_s))

    for i in range(400):  # inserts
        before = i % 8 >= 5
        x = r.choice(BEFORE if before else L.PHRASES)
        said = add_fillers(r, x, 1).lower() if r.random() < 0.2 else x
        sel = r.choice(L.PLAIN) if r.random() < 0.6 else fill(r, r.choice(L.NAMED))[0]
        if not before:
            add("e-insert-after", i, r.choice(L.INSERT_AFTER).format(x=said), sel, edit_ctx(r), ej("insertAfter", " " + sentence(x)))
        else:
            add("e-insert-before", i, r.choice(L.INSERT_BEFORE).format(x=said), sel, edit_ctx(r), ej("insertBefore", sentence(x) + " "))

    for i in range(380):  # the utterance is the new text
        if i % 5 < 2:
            new = r.choice(L.TITLES)
            sel = r.choice([t for t in L.TITLES if t != new])
            said = new if r.random() < 0.6 else new.lower()
            add("e-replace", i, said, sel, edit_ctx(r), ej("replace", new))
        else:
            new = r.choice(L.PLAIN + L.KEEP) if r.random() < 0.6 else fill(r, r.choice(L.NAMED))[0]
            sel = r.choice(L.PLAIN)
            if new == sel:
                continue
            said = add_fillers(r, new, 1) if r.random() < 0.25 else new
            add("e-replace", i, lower_transcript(said) if r.random() < 0.5 else said, sel, edit_ctx(r), ej("replace", new))

    for i in range(260):  # make it shorter: padded core → core
        core = r.choice(L.CORES)
        sel = f"{r.choice(L.PADDING_OPEN)} {core}{r.choice(L.PADDING_CLOSE)}"
        add("e-shorter", i, r.choice(L.SHORTER), sel, edit_ctx(r), ej("edit", sentence(core)))

    verbs = {"book", "order", "send", "print", "update", "tag", "notify", "review", "schedule", "set", "vacuum", "take",
             "fold", "fix", "add", "improve", "write", "call", "renew", "finalize", "hire", "plan", "water", "feed",
             "collect", "draft", "invite", "test", "clean", "replace", "repaint", "post", "email"}

    def prose(items):
        a = items
        if a[0].split()[0] not in verbs:  # nouns: "We need a, b, and c."
            return r.choice([f"We need {', '.join(a[:-1])}, and {a[-1]}.", f"Things to get: {', '.join(a)}.",
                             f"Please pick up {', '.join(a[:-1])} and {a[-1]}.", f"Don't forget {', '.join(a[:-1])}, and {a[-1]}."])
        s = r.random()
        if s < 0.35:
            return f"We need to {', '.join(a[:-1])}, and {a[-1]}." if len(a) > 2 else f"We need to {a[0]} and {a[1]}."
        if s < 0.6:
            k = max(1, len(a) - 1)
            first = f"{', '.join(a[:k - 1])} and {a[k - 1]}" if k > 1 else a[0]
            return f"Don't forget to {first}." + (f" Also {a[k]}." if k < len(a) else "")
        if s < 0.8:
            return f"First {a[0]}, then " + ", then ".join(a[1:]) + "."
        return f"To do: {', '.join(a)}."
    for i in range(340):
        lst = r.choice(L.LISTS)
        items = lst[: r.randint(3, len(lst))] if len(lst) > 3 else lst[:]
        sel = prose(items)
        if i % 4 == 3:
            add("e-numbered", i, r.choice(L.NUMBERED), sel, edit_ctx(r),
                ej("edit", "\n".join(f"{k + 1}. {x}" for k, x in enumerate(items))))
        else:
            add("e-bullets", i, r.choice(L.BULLETS), sel, edit_ctx(r), ej("edit", "\n".join(f"- {x}" for x in items)))

    for i in range(100):
        t, how = r.choice(L.CASE)
        sel = r.choice(L.TITLES + L.PHRASES).lower() if how != "lower" else r.choice(L.TITLES).upper()
        target = {"upper": sel.upper(), "lower": sel.lower(), "title": " ".join(cap(w) for w in sel.split())}[how]
        if target != sel:
            add("e-case", i, t, sel, edit_ctx(r), ej("edit", target))
    return out


def teach_items():
    """Edits that need a writer: tone, translation, rephrasing. The teacher's reply becomes the target after checks."""
    r, out = R("teach"), []
    for i in range(380):
        src = fill(r, r.choice(L.INFORMAL if r.random() < 0.7 else L.FORMAL))[0]
        tone = r.choice(L.TONES)
        if src in L.FORMAL:
            tone = r.choice(["more casual", "friendlier", "less formal", "simpler"])
        t = r.choice(["make this {t}", "make it {t}", "rewrite this to be {t}", "can you make this {t}", "{t} please"]).format(t=tone)
        out.append({"id": f"e-tone-{i}", "cat": "e-tone", "transcript": t, "selection": src, "context": edit_ctx(r)})
    for i in range(300):
        lang, code = r.choice(L.LANGS)
        src = r.choice(L.PLAIN + L.PHRASES + L.KEEP) if r.random() < 0.7 else fill(r, r.choice(L.NAMED))[0]
        t = r.choice(["translate this to {l}", "translate into {l}", "in {l} please", "say this in {l}", "{l} translation"]).format(l=lang)
        out.append({"id": f"e-translate-{i}", "cat": "e-translate", "lang": code, "transcript": t, "selection": sentence(src),
                    "context": edit_ctx(r)})
    for i in range(160):
        src = fill(r, r.choice(L.NAMED))[0] if r.random() < 0.5 else r.choice(L.PLAIN)
        t = r.choice(["rephrase this", "make it a question", "simplify this", "say this more clearly", "reword this",
                      "make this sound more positive", "make it more enthusiastic"])
        out.append({"id": f"e-rephrase-{i}", "cat": "e-rephrase", "transcript": t, "selection": src, "context": edit_ctx(r)})
    return out


# ---------- v3 families (#60) ----------
# Dictation transcripts below are what the user says. PoptalkDatagen render runs Pipeline.dictationPrepass on them
# (spoken quotes/brackets/line breaks → marks, numbers → digits) and Pipeline.spokenNumbers on dictation targets;
# `split` then drops any row whose target doesn't carry the same marks and digits as the transcript the model sees.

def utf16(s):
    return len(s.encode("utf-16-le")) // 2


def long_screen(r):
    """A long chat, terminal or email screen with the cursor in the reply field (#47)."""
    kind = r.choice(["slack", "messages", "terminal", "mail"])
    pick = lambda pool, lo, hi: [r.choice(pool) for _ in range(r.randint(lo, hi))]
    if kind in ("slack", "messages"):
        p = person(r)[0]
        who = (lambda: person(r)[0]) if kind == "slack" else (lambda: r.choice([p, "Me"]))
        thread = "\n".join(f"{who()}: {l}" for l in pick(L.CHAT_LINES, 15, 40))
        return {"appName": "Slack" if kind == "slack" else "Messages", "windowTitle": r.choice(L.CHANNELS) if kind == "slack" else p,
                "text": "", "cursorOffset": 0, "ocrText": thread}
    if kind == "terminal":
        text = "\n".join(pick(L.TERMINAL_LINES, 25, 70)) + "\n$ "
        return {"appName": "Terminal", "windowTitle": "zsh — 120×40", "text": text, "cursorOffset": utf16(text)}
    return {"appName": "Mail", "windowTitle": f"Re: {r.choice(L.TITLES)}", "cursorOffset": 0,
            "text": "\n\n" + "\n".join(pick(L.MAIL_LINES + L.FILLER, 20, 50))}


def letters(name, r):
    """A name spelled out as Parakeet writes it: spaced, hyphenated or comma-separated capitals."""
    return r.choice([" ", " ", "-", ", "]).join(name.upper())


def spoken_address(s):
    return re.sub(r"\s+", " ", s.replace("@", " at ").replace(".", " dot ").replace("/", " slash ")
                  .replace("_", " underscore ").replace("-", " dash ")).strip()


def v3_dictation():
    out = []
    add = lambda cat, i, t, ctx, target: out.append({"id": f"{cat}-{i}", "cat": cat, "transcript": t, "context": ctx, "target": target})

    r = R("v3-multi")  # long chat/terminal/email screens: keep every sentence (#47)
    for i in range(150):
        parts = r.sample(L.MULTI_STATEMENTS, r.randint(1, 3)) + [r.choice(L.MULTI_REQUESTS + L.ASKS)]
        if r.random() < 0.2:
            r.shuffle(parts)
        spoken = " ".join(add_fillers(r, p, 1) if r.random() < 0.3 else p for p in parts)
        add("d-multi-screen", i, lower_transcript(spoken) if r.random() < 0.7 else spoken, long_screen(r), " ".join(parts))

    r = R("v3-marks")  # quotes, brackets and line breaks from the pre-pass stay (#48)
    for i in range(150):
        if i % 2 == 0:
            if r.random() < 0.5:
                q = r.choice(L.QUOTED)
                target = r.choice(L.QUOTE_T).format(q=q)
                spoken = target.replace(f"“{q}”", r.choice(["quote {q} unquote", "quote, {q}, end quote", "quote {q} end quote"]).format(q=q))
            else:
                p = r.choice(L.PAREN)
                target = r.choice(L.PAREN_T).format(p=p)
                spoken = target.replace(f"({p})", r.choice(["open paren {p} close paren", "open parenthesis {p} close parenthesis"]).format(p=p))
            x = r.random()
            t = target[0].lower() + target[1:-1] if x < 0.3 else lower_transcript(spoken) if x < 0.65 else spoken
        else:
            body = r.sample(L.MULTI_STATEMENTS + L.PLAIN, 2)
            shape = r.randrange(3)
            if shape == 0:
                segs, breaks = [fill(r, r.choice(L.GREETINGS))[0], " ".join(body)], ["line"]
            elif shape == 1:
                segs, breaks = body, ["paragraph"]
            else:
                segs, breaks = [body[0], r.choice(L.SIGNOFFS), person(r)[0]], ["paragraph", "line"]
            target, spoken = segs[0], segs[0]
            for seg, b in zip(segs[1:], breaks):
                target += ("\n" if b == "line" else "\n\n") + seg
                spoken += f" {r.choice(['new', 'New'])} {b}{r.choice(['.', ','])} {seg}"
            x = r.random()
            # Typed line breaks survive the pre-pass, paragraph breaks don't (stripHesitations collapses "\n\n"): say those.
            t = target if x < 0.3 and "\n\n" not in target else spoken.lower() if x < 0.55 else spoken
        add("d-keep-marks", i, t, unrelated_context(r), target)

    r = R("v3-list")  # "bullet … bullet …" / "first … second …" while dictating (#48)
    for i in range(120):
        lst = r.choice(L.LISTS)
        items = lst[: r.randint(3, len(lst))] if len(lst) > 3 else lst[:]
        lead = r.choice(L.LIST_LEADS) if r.random() < 0.6 else None
        cues = L.ORDINALS[: len(items)] if i % 3 == 2 else [r.choice(["bullet", "bullet point"])] * len(items)
        lines = [f"{k + 1}. {x}" if i % 3 == 2 else f"- {x}" for k, x in enumerate(items)]
        if r.random() < 0.5:
            t = " ".join(f"{c} {x}" for c, x in zip(cues, items))
            t = f"{lead} {t}" if lead else t
        else:
            t = " ".join(f"{cap(c)} {x}." for c, x in zip(cues, items))
            t = f"{cap(lead)}: {t}" if lead else t
        add("d-list", i, t, unrelated_context(r), "\n".join(([cap(lead) + ":"] if lead else []) + lines))

    r = R("v3-email")  # emails, URLs and handles (#48)
    firsts = [p.lower() for p, _ in L.PEOPLE if re.fullmatch(r"[A-Za-z]+", p)]
    lasts = [s.lower() for s, _ in L.SURNAMES if re.fullmatch(r"[A-Za-z]+", s)]
    for i in range(120):
        dom = f"{(r.choice(L.PREFIX) + r.choice(L.SUFFIX)).lower()}.{r.choice(L.TLDS)}"
        f, l = r.choice(firsts), r.choice(lasts)
        k = i % 3
        if k == 0:
            addr = r.choice([f, f"{f}.{l}", f"{f[0]}{l}", f"{f}_{l}", "hello", "billing"]) + "@" + dom
            tmpl, said = r.choice(L.EMAIL_T), spoken_address(addr)
        elif k == 1:
            addr = r.choice([dom, f"{dom}/{r.choice(L.URL_PATHS)}", f"docs.{dom}", f"{dom}/{r.choice(L.URL_PATHS)}/{r.choice(L.URL_PATHS)}"])
            tmpl, said = r.choice(L.URL_T), spoken_address(addr)
        else:
            addr = "@" + r.choice([f, f"{f}_{l}", dom.split(".")[0]])
            tmpl, said = r.choice(L.HANDLE_T), "at sign " + spoken_address(addr[1:])
        target, spoken = tmpl.format(e=addr, u=addr, h=addr), tmpl.format(e=said, u=said, h=said)
        add("d-email-url", i, lower_transcript(spoken) if r.random() < 0.7 else spoken, unrelated_context(r), target)

    r = R("v3-spell")  # spelling while dictating, often after a misheard name: the spelling wins (#48, #50)
    names = [(p, a) for p, a in L.PEOPLE if re.fullmatch(r"[A-Za-z]+", p)] + [(n, [s]) for n, s, _ in L.LETTER_NAMES]
    for i in range(80):
        n, heard = r.choice(names)
        x = f"{r.choice(heard) if r.random() < 0.6 else n}{r.choice([', ', ' '])}{letters(n, r)}"
        tmpl, d = r.choice(L.SPELL_DICT_T), r.choice(L.DAYS)
        spoken = tmpl.format(x=x, D=d)
        add("d-spelled", i, spoken if r.random() < 0.6 else spoken[0].lower() + spoken[1:-1], unrelated_context(r), tmpl.format(x=n, D=d))

    r = R("v3-num")  # spoken numbers: the ITN pass turns them into digits and the target keeps them (#59)
    for i in range(160):
        vals = {"CN": r.choice(L.COMPOUND), "U": r.choice(L.SMALL), "U2": r.choice(L.SMALL), "SM": r.choice(L.SMALL),
                "ORD": r.choice(L.ORD_COMPOUND), "CL": r.choice(L.CLOCK), "AP": r.choice(["pm", "am", "PM"]),
                "D": r.choice(L.DAYS), "M": r.choice(L.MONTHS)}
        clean = re.sub(r"\{(\w+)\}", lambda m: vals[m.group(1)], r.choice(L.NUM_T))
        x = r.random()
        t = lower_transcript(clean) if x < 0.6 else ("Um, " + clean[0].lower() + clean[1:]) if x < 0.75 else clean
        add("d-num", i, t, unrelated_context(r), clean)
    return out


def v3_edits():
    out = []
    add = lambda cat, i, t, sel, ctx, target: out.append(
        {"id": f"{cat}-{i}", "cat": cat, "transcript": t, "selection": sel, "context": ctx, "target": target})

    r = R("v3-spell-edit")  # spaced/hyphenated spelling after a misheard name → correct + vocabulary (#50)
    people = [(p, a, a) for p, a in L.PEOPLE if re.fullmatch(r"[A-Za-z]+", p)]
    products = [(e[0], [e[1][0]], e[1]) for e in (invented(r) for _ in range(200))
                if e[2] == "product" and re.fullmatch(r"[A-Z][a-z]+", e[0])]
    pools = [[(n, [s], sels) for n, s, sels in L.LETTER_NAMES], people, products]
    for i in range(120):
        n, heard, sels = r.choice(pools[i % 3])
        sel = r.choice(sels)
        if sel.lower() == n.lower():
            continue
        x = f"{r.choice(heard)}{r.choice([', ', ' '])}{letters(n, r)}"
        t = r.choice(L.SPELL_EDIT_T).format(x=x)
        rem = r.random() < 0.1
        if rem:
            t += r.choice(L.REMEMBER)
        add("e-spelled-misheard", i, cap(t) if r.random() < 0.4 else t, sel, edit_ctx(r),
            ej("correct", n, {"text": n, "aliases": [sel.lower()]}, rem))

    r = R("v3-join")  # the screen's form joins the selection's words: "pg bouncer" → "pgbouncer" (#45)
    joined = [(p + s, [f"{p} {s}", f"{' '.join(p)} {s}"]) for p in L.JOIN_PREFIX for s in L.JOIN_SUFFIX if p + s != "pgvector"]
    joined += [(t, [a for a in ta if " " in a]) for t, ta in L.TECH if " " not in t and t != "pgvector" and any(" " in a for a in ta)]
    for i in range(120):
        n, aliases = r.choice(joined)
        sel = r.choice(aliases)
        add("e-correct-joined", i, r.choice(L.JOIN_FIX), sel, context(r, [(n, aliases, "product")], long=r.random() < 0.45),
            ej("correct", n, {"text": n, "aliases": [sel.lower()]}))

    r = R("v3-bare")  # a bare phrase over a selection replaces it (#44)
    for i in range(100):
        new, sel = r.sample(L.SHORT_TERMS, 2)
        if r.random() < 0.3:
            sel = r.choice(L.TITLES)
        said = cap(new) + "." if r.random() < 0.5 else new
        add("e-replace-bare", i, ("um " + said) if r.random() < 0.15 else said, sel, edit_ctx(r), ej("replace", said.rstrip(".")))

    r = R("v3-tense")  # "Replaced this with X" (Parakeet's past tense) is still a replace with X (#53)
    for i in range(80):
        new = r.choice([r.choice(L.SHORT_TERMS), r.choice(L.TITLES), person(r)[0], tech(r)[0]])
        sel = r.choice(L.SHORT_TERMS + L.TITLES)
        if new.lower() == sel.lower():
            continue
        verb, obj = r.choice(L.REPLACE_VERBS), r.choice(L.REPLACE_OBJ)
        t = " ".join(w for w in [verb, obj, "with", new] if w) + ("." if r.random() < 0.6 else "")
        add("e-replace-tense", i, t, sel, edit_ctx(r), ej("replace", new))
    return out


# ---------- v4 families: from aggregate history counts ----------
# Both Macs' history, read as counts only: ~85% of dictations went to coding-agent terminals with screens of 4–6k
# characters, 10–19% were three words or fewer, and v3 put list markers on 5 of 60 dictations that had no list cue.

def agent_screen(r, extra=()):
    """A coding agent's terminal: tool calls, diffs and bullet lists, the cursor at its prompt."""
    lines, budget = [], r.randint(1500, 3500)  # under Prompts.window's 4000, so every `extra` line stays in view
    while sum(len(l) + 1 for l in lines) < budget:
        lines.append(r.choice(L.AGENT_LINES))
    for x in extra:
        lines.insert(r.randint(0, len(lines)), x)
    text = "\n".join(lines) + "\n\n> "
    app, win = r.choice(L.AGENT_APPS)
    return {"appName": app, "windowTitle": win.format(w=r.choice(L.REPO_WORDS)), "text": text, "cursorOffset": utf16(text)}


def heard(r, clean):
    """A clean sentence as it reaches the model: punctuated as Parakeet writes it (then the target is unchanged),
    bare lowercase, or with a filler."""
    x = r.random()
    if x < 0.45:
        return clean
    if x < 0.75:
        return lower_transcript(clean)
    s = add_fillers(r, clean if re.match(r"I\b", clean) else clean[0].lower() + clean[1:], 1)
    return lower_transcript(s) if r.random() < 0.5 else s


def ident(r):
    """(as on screen, as spoken): loadConfig / load_config / LoadConfig ↔ "load config"."""
    h, t = r.choice(L.ID_HEAD), r.choice(L.ID_TAIL)
    form = r.choice([h + t.capitalize(), h + t.capitalize(), f"{h}_{t}", h.capitalize() + t.capitalize()])
    return form, f"{h} {t}"


def v4_dictation():
    out = []
    add = lambda cat, i, t, ctx, target: out.append({"id": f"{cat}-{i}", "cat": cat, "transcript": t, "context": ctx, "target": target})

    r = R("v4-terminal")  # replies at a coding agent's prompt: keep them as said, no bullets, no screen text
    for i in range(300):
        x = r.random()
        parts = [r.choice(L.AGENT_SHORT)] if x < 0.3 else r.sample(L.AGENT_SAID, 1 if x < 0.7 else r.randint(2, 3))
        if x >= 0.7 and r.random() < 0.3:
            parts.insert(0, r.choice(L.AGENT_SHORT))
        target = " ".join(parts)
        add("d-terminal", i, heard(r, target), agent_screen(r), target)

    r = R("v4-ident")  # an identifier on the agent's screen, spoken as words: write it as the screen does
    for i in range(120):
        (n, spoken), others = ident(r), [ident(r)[0] for _ in range(r.randint(1, 3))]
        lines = [r.choice(L.IDENT_LINES).format(I=v) for v in [n] + [o for o in others if o.lower().replace("_", "") != n.lower().replace("_", "")]]
        tmpl = r.choice(L.IDENT_T)
        t = tmpl.format(I=spoken)
        t, ctx = lower_transcript(t) if r.random() < 0.6 else t, agent_screen(r, lines)
        assert n in ctx["text"][-4000:], "the identifier must stay inside the window the model sees"
        add("d-terminal-names", i, t, ctx, tmpl.format(I=n))

    r = R("v4-no-list")  # to-dos said as one sentence, no "bullet"/"first … second": prose, even over a bulleted screen
    for i in range(150):
        items = r.choice(L.LISTS + L.DEV_TODOS * 2)
        sel = r.sample(items, r.randint(2, min(3, len(items))))
        joined = " and ".join(sel) if len(sel) == 2 else ", ".join(sel[:-1]) + r.choice([" and ", ", and "]) + sel[-1]
        target = cap(r.choice(L.VERB_PROSE if " " in items[0] else L.NOUN_PROSE).format(L=joined))
        if r.random() < 0.3:
            target = r.choice(L.AGENT_SAID + L.AGENT_SHORT) + " " + target
        add("d-no-list", i, heard(r, target), agent_screen(r) if r.random() < 0.6 else unrelated_context(r), target)

    r = R("v4-openers")  # a sentence-opening So/Well/Okay is the speaker's, not filler: it stays
    for i in range(60):
        target = r.choice(L.KEEP_OPENERS)
        if r.random() < 0.3:
            target += " " + r.choice(L.PLAIN + L.AGENT_SAID)
        add("d-keep-opener", i, heard(r, target), agent_screen(r) if r.random() < 0.4 else unrelated_context(r), target)
    return out


# ---------- v5: short lowercase imperatives ----------
# On invented probes every model returned some lowercase commands ("send the slides to kwame") as heard, uncapitalized.

def v5_dictation():
    r, out = R("v5-imperative"), []
    short = [t for t in L.IMPERATIVES if len(t.split()) <= 5]
    while len(out) < 200:
        if r.random() < 0.15:  # two commands in one breath: two sentences
            (a, ea), (b, eb), j = fill(r, r.choice(short)), fill(r, r.choice(short)), r.choice(L.RUNON_JOIN)
            spoken, ents = a + j + b, ea + eb
            target = sentence(a) + " " + sentence((j.split()[-1] + " " if j.strip() else "") + b)
        else:
            c, ents = fill(r, r.choice(L.IMPERATIVES))
            x = r.random()
            if x < 0.2:
                c += ", please"
            elif x < 0.4:
                c = r.choice(L.IMPERATIVE_LEADS) + " " + c
            spoken = target = sentence(c)
        if not 3 <= len(target.split()) <= 15:
            continue
        t = lower_transcript(add_fillers(r, spoken, 1) if r.random() < 0.1 else spoken)
        ctx = context(r, ents) if ents and r.random() < 0.4 else r.choice([long_screen, agent_screen, unrelated_context])(r)
        out.append({"id": f"d-imperative-{len(out)}", "cat": "d-imperative", "transcript": t, "context": ctx, "target": target})
    return out


def v5_edits():
    """Inserted text said as a lowercase command comes back as a sentence."""
    r, out = R("v5-imperative-edit"), []
    for i in range(60):
        x = fill(r, r.choice(L.IMPERATIVES))[0]
        sel = r.choice(L.PLAIN) if r.random() < 0.6 else fill(r, r.choice(L.NAMED))[0]
        if i % 5 < 3:
            t, target = r.choice(L.INSERT_AFTER).format(x=lower_transcript(x)), ej("insertAfter", " " + sentence(x))
        else:
            t, target = r.choice(L.INSERT_BEFORE).format(x=lower_transcript(x)), ej("insertBefore", sentence(x) + " ")
        out.append({"id": f"e-insert-imperative-{i}", "cat": "e-insert-imperative", "transcript": t, "selection": sel,
                    "context": edit_ctx(r), "target": target})
    return out


def check_v5():
    """`gen.py check`: the v5 families are built and shaped as intended (no GPU, writes nothing)."""
    cats = Counter(it["cat"] for it in program_items())
    assert cats["d-imperative"] == 200 and cats["e-insert-imperative"] == 60, cats
    for it in v5_dictation():
        t, y = it["transcript"], it["target"]
        assert t == lower_transcript(t) and t[0].islower(), it
        assert y[0].isupper() and y[-1] in ".!?" and 3 <= len(y.split()) <= 15, it
        assert all(w in y for w in L.DAYS + L.MONTHS if w.lower() in t.split()), it
    for it in v5_edits():
        text = json.loads(it["target"])["text"].strip()
        assert it["transcript"] == it["transcript"].lower() and text[0].isupper() and text[-1] == ".", it
    print(f"v5 check ok: {cats['d-imperative']} d-imperative, {cats['e-insert-imperative']} e-insert-imperative")


# ---------- v6: self-corrections beyond "A no B" (#98 phase 2) ----------
# Cross-sentence fixes, cancellations, restatements and "A no B instead", plus look-alikes that stay.

def plain_or_lower(r, s):  # as Parakeet punctuates it or bare; no fillers, which can land inside a cue ("no, I mean forget that")
    return s if r.random() < 0.4 else lower_transcript(s)


def v6_later(r):  # a later sentence fixes an earlier value: change it in place, drop the correcting words
    tmpl, kind = r.choice(L.CORRECTABLE)
    a, b = r.sample(slot_pool(kind), 2)
    mid = r.sample(L.BETWEEN, r.randint(0, 2))
    said = " ".join([tmpl.replace("{X}", a)] + mid + [f"{r.choice(L.LATER_CUES)} {b}."])
    return plain_or_lower(r, said), " ".join([tmpl.replace("{X}", b)] + mid)


def v6_cancel(r):  # "scratch that" / "never mind" / "forget it": the cancelled sentence goes, the rest stays
    drop, keep = r.choice(L.CANCELS)
    lead = [r.choice(L.PLAIN)] if r.random() < 0.3 else []
    cue = r.choice(L.CANCEL_CUES)
    said, target = (lead + [drop, cue], lead) if lead and r.random() < 0.4 else (lead + [drop, cue, keep], lead + [keep])
    return plain_or_lower(r, " ".join(said)), " ".join(target)


def v6_restate(r):  # the same sentence again with one change, no cue: keep the second
    tmpl, kind = r.choice(L.CORRECTABLE)
    a, b = r.sample(slot_pool(kind), 2)
    first = tmpl.replace("{X}", a) if r.random() < 0.5 else sentence(tmpl.split("{X}")[0] + a)  # or restarted after it
    said = f"{first} {tmpl.replace('{X}', b)}"
    return lower_transcript(said) if r.random() < 0.8 else said, tmpl.replace("{X}", b)


def v6_instead(r):  # "A no B instead" swaps A for B; never "not A"
    tmpl, kind, prep = r.choice(L.INSTEAD_T)
    a, b = r.choice(kind) if isinstance(kind, list) else r.sample(slot_pool(kind), 2)
    fix = f"{prep} {b}" if prep and r.random() < 0.4 else b
    cue = r.choice(["no", "no", "no wait", "sorry no"])
    said = tmpl.replace("{X}", f"{a}, {cue}, {fix} instead" if r.random() < 0.3 else f"{a} {cue} {fix} instead")
    return lower_transcript(said) if r.random() < 0.7 else said, tmpl.replace("{X}", b)


def v6_keep(r):  # the cue words as content: nothing to drop
    s = r.choice(L.KEEP_CUES)
    return heard(r, s), s


V6 = {"d-correct-later": (150, v6_later), "d-cancel": (150, v6_cancel), "d-restate": (120, v6_restate),
      "d-instead": (120, v6_instead), "d-keep-cue": (60, v6_keep)}


def v6_dictation():
    """Each family draws until it has n items clean of bench, held-out and prompt-E text."""
    out, checker = [], Checker()
    for cat, (n, make) in V6.items():
        r, k = R(cat), 0
        while k < n:
            t, target = make(r)
            it = {"id": f"{cat}-{k}", "cat": cat, "transcript": t, "context": unrelated_context(r), "target": target}
            if not checker.reason(it):
                out.append(it)
                k += 1
    return out


def check_v6():
    """`gen.py check`: the v6 families are built, shaped as intended and clean of bench/held-out/prompt text."""
    cats = Counter(it["cat"] for it in program_items())
    assert all(cats[c] == n for c, (n, _) in V6.items()), cats
    has = lambda s, w: re.search(rf"(?<!\w){re.escape(w)}(?!\w)", s, re.I)
    checker, hits, ids = Checker(), [], set()
    for it in v6_dictation():
        ids.add((it["transcript"], it["target"]))
        t, y, cat = it["transcript"], it["target"], it["cat"]
        assert y[0].isupper() and y[-1] in ".!?", it
        if cat == "d-keep-cue":
            assert norm(t) == norm(y) or len(norm(t)) > len(norm(y)), it  # only fillers added
        else:
            assert len(norm(y)) < len(norm(t)), it
        if cat == "d-correct-later":
            assert not has(y, "meant") and not has(y, "correction"), it
        if cat == "d-cancel":
            assert not any(has(y, w) for w in ("scratch", "never mind", "forget")), it
        if cat == "d-instead":
            assert not has(y, "instead") and not has(y, "not"), it
        if (why := checker.reason(it)):
            hits.append(f"{it['id']}: {why}")
    assert not hits, "\n".join(hits)
    print("v6 check ok: " + ", ".join(f"{cats[c]} {c}" for c in V6) + f"; {len(ids)} distinct, 0 contaminated")


SCRIPTS = {"ja": r"[぀-ヿ一-鿿]", "zh": r"[一-鿿]", "ko": r"[가-힯]"}


def teacher_target(it, reply):
    """The teacher's reply as a training target, or None if it fails the checks."""
    m = re.search(r"\{.*\}", reply, re.S)
    if not m:
        return None
    try:
        j = json.loads(m.group(0))
    except json.JSONDecodeError:
        return None
    text, sel = (j.get("text") or "").strip(), it["selection"]
    if j.get("action") != "edit" or not text or text == sel or j.get("remember"):
        return None
    if not 0.3 <= len(text) / len(sel) <= 2.5 or text.lower().startswith(("sure", "here")):
        return None
    lang = it.get("lang")
    if lang in SCRIPTS and not re.search(SCRIPTS[lang], text):
        return None
    # No new names: capitalized words in the output must come from the selection (translations may add some).
    names = set(re.findall(r"(?<![.!?]\s)(?<!^)\b[A-Z][\w-]+", sel))
    # Translations may translate days, months and "Project", but keep the names themselves.
    keep = names - {"I"} - (set(L.DAYS) | set(L.MONTHS) | set(L.PROJECT_HEAD) if lang else set())
    if any(n not in text for n in keep):
        return None
    new = set(re.findall(r"\b[A-Z][a-z]+[A-Z]\w*", text)) - set(re.findall(r"\b[A-Z][a-z]+[A-Z]\w*", sel))
    if new:
        return None
    return ej("edit", text)


# ---------- held-out eval ----------
# Templates, sentences and phrasings below are used only here, never in training, so the held-out
# set measures generalization to new wording (names and tools still come from the shared lexicon).
HO_NAMED = ["Could {P} send the {T} runbook to {P2} before the incident review?",
            "I'm meeting {P} {S} from {C} next {D} to talk about pricing.",
            "The {C} invoice still lists {T} as a line item.", "Please add {P} as a reviewer on the {T} change.",
            "{P} thinks we should drop {T} and keep {T2}.", "Our {PRJ} demo uses {T} for the backend.",
            "Can you check whether {C} renewed their {T} seats?", "Thank {P} for the {T} workshop notes.",
            "The {PRJ} retro moved to {D} because {P} is traveling.", "{P} wrote the {C} onboarding checklist in {T}."]
HO_CORRECT = [("Set the alarm for {X} tomorrow.", "time"), ("Send the draft to {X} instead.", "person"),
              ("The party is on {X} evening.", "day"), ("We need {X} extra chairs.", "num")]
HO_KEEP = ["I actually think the old version was faster.", "No, the review is still on for today.",
           "Sorry, I didn't catch your name at the start.", "It sounds like the speakers are broken."]
HO_ASK = ["Can you remind everyone about the deadline?", "What should we name the new project?",
          "Write a summary of today's standup.", "How long does the battery last on these headphones?"]
HO_PLAIN = ["The bakery on the corner closes early on Sundays.", "My cousin is visiting for a few days next month.",
            "The elevator in our building is out of order again.", "We planted tomatoes and herbs on the balcony."]
HO_SHORTER = ["keep it short", "less wordy please", "make this tighter"]
HO_CORES = ["the shuttle to the venue leaves at eight", "the cafeteria is closed for renovation this week",
            "the board meeting has been moved to the afternoon"]
HO_LISTS = [["buy stamps", "mail the package", "return the library books"], ["carrots", "yogurt", "bananas", "honey"],
            ["back up the laptop", "update the router", "reset the guest password"]]
HO_BULLETS = ["make this into bullets", "can you bulletize this", "bulleted list please"]


def heldout(train_keys):
    r, cases = R("heldout"), []
    def ctx_fields(ctx):
        out = {"context": ctx.get("text", "")}
        if ctx.get("cursorOffset") is not None:
            out["cursor"] = ctx["cursorOffset"]
        if ctx.get("ocrText"):
            out["ocr"] = ctx["ocrText"]
        return out
    for i in range(16):  # names misheard toward forms the screen fixes
        clean, ents = fill(r, HO_NAMED[i % len(HO_NAMED)])
        heard = clean
        for e in ents:
            heard = heard.replace(e[0], r.choice(e[1]), 1)
        bad = [a for e in ents for a in e[1] if a.lower() not in clean.lower() and a.replace(" ", "") != e[0].lower()]
        cases.append({"id": f"h-d-names-{i}", "kind": "dictation", "transcript": lower_transcript(heard),
                      **ctx_fields(context(r, ents, long=i % 3 == 0)), "mustContain": [e[0] for e in ents],
                      "mustNotContain": [a for a in bad if a.lower() in lower_transcript(heard)], "maxLengthRatio": 1.6})
    for i in range(8):
        tmpl, kind = HO_CORRECT[i % len(HO_CORRECT)]
        pool = {"time": L.TIMES, "num": L.NUMBERS, "day": L.DAYS, "person": [p for p, _ in L.PEOPLE if p.isascii()]}[kind]
        a, b = r.sample(pool, 2)
        said = tmpl.replace("{X}", f"{a} {r.choice(L.CUES)} {b}")
        cases.append({"id": f"h-d-correction-{i}", "kind": "dictation", "transcript": lower_transcript(add_fillers(r, said, 1) if i % 2 else said),
                      "mustContain": [b], "mustNotContain": [a], "maxLengthRatio": 1.3})
    for i, s in enumerate(HO_KEEP + HO_ASK):
        cases.append({"id": f"h-d-keep-{i}", "kind": "dictation", "transcript": lower_transcript(s),
                      **ctx_fields(unrelated_context(r) or {"text": ""}), "mustContain": [s[:-1]], "maxLengthRatio": 1.3})
    for i, s in enumerate(HO_PLAIN):  # screen with a look-alike term: don't echo or "fix" toward it
        w = re.findall(r"[a-z]{5,}", s)[0]
        trap = w.capitalize() + "ly"
        cases.append({"id": f"h-d-noecho-{i}", "kind": "dictation", "transcript": lower_transcript(s),
                      **ctx_fields(context(r, [(trap, [], "product")])), "mustContain": [s[:-1]], "mustNotContain": [trap],
                      "maxLengthRatio": 1.3})
    spellable = [e for e in [person(r) for _ in range(50)] + [invented(r) for _ in range(50)] if re.fullmatch(r"[A-Za-z]+", e[0])]
    for i in range(8):
        n, aliases, _ = spellable[i]
        sel = aliases[0]
        cases.append({"id": f"h-e-spelled-{i}", "kind": "edit", "transcript": f"no, it's {n}, spelled {spell(n, r)}", "selection": sel,
                      "expectAction": "correct", "expectExact": n, "expectVocabOffer": n})
    for i in range(8):
        e = [person(r, True), invented(r), tech(r), invented(r)][i % 4]
        sel = e[1][0] if e[1][0].lower() != e[0].lower() or " " in e[1][0] else e[0].lower()
        kind = "company" if e[2] == "company" else e[2] if e[2] in L.CONTEXT_FIX else "product"
        cases.append({"id": f"h-e-context-{i}", "kind": "edit", "transcript": r.choice(["the name is wrong, fix it", "spell that correctly",
                      f"fix the {kind} name please"]), "selection": sel, **ctx_fields(context(r, [e], long=i % 2 == 0)),
                      "expectAction": "correct", "expectExact": e[0]})
    for i in range(6):
        core = HO_CORES[i % 3]
        sel = f"{L.PADDING_OPEN[i]} {core}{L.PADDING_CLOSE[i % len(L.PADDING_CLOSE)]}"
        cases.append({"id": f"h-e-shorter-{i}", "kind": "edit", "transcript": HO_SHORTER[i % 3], "selection": sel,
                      "expectAction": "edit", "mustContain": [core.split()[1]], "maxLengthRatio": 0.6})
    for i in range(6):
        items = HO_LISTS[i % 3]
        sel = (f"Please pick up {', '.join(items[:-1])} and {items[-1]}." if i % 3 == 1
               else f"Before Friday we have to {', '.join(items[:-1])}, and {items[-1]}.")
        cases.append({"id": f"h-e-bullets-{i}", "kind": "edit", "transcript": HO_BULLETS[i % 3], "selection": sel,
                      "expectAction": "edit", "mustContain": ["\n"] + [x.split()[-1] if " " in x else x[1:] for x in items], "maxLengthRatio": 2})
    for i in range(6):
        x = ["thanks for your patience", "the slides are in the shared folder", "see everyone next week"][i % 3]
        sel = HO_PLAIN[i % 4]
        after = i % 2 == 0
        t = (f"add this at the end: {x}" if after else f"put this before it: {x}")
        cases.append({"id": f"h-e-insert-{i}", "kind": "edit", "transcript": t, "selection": sel,
                      "expectAction": "insertAfter" if after else "insertBefore", "mustContain": [cap(x)],
                      "mustNotContain": [sel[:-1]], "expectVocabOffer": None})
    for i in range(6):
        new = ["Quarterly Planning Notes", "Lunch and Learn Ideas", "Vendor Shortlist",
               "We should revisit this after the holidays.", "The kitchen will be cleaned on Thursday.", "Parking is free after six."][i]
        cases.append({"id": f"h-e-replace-{i}", "kind": "edit", "transcript": new if i < 3 else lower_transcript(new),
                      "selection": HO_PLAIN[i % 4] if i >= 3 else r.choice(L.TITLES), "expectExact": new, "expectVocabOffer": None})
    cases = list({(c["transcript"], c.get("selection")): c for c in cases}.values())
    checker = Checker(heldout=None)  # the held-out set itself is being built
    as_item = lambda c: {"transcript": c["transcript"], "selection": c.get("selection"), "target": c.get("expectExact"),
                         "context": {"text": c.get("context"), "ocrText": c.get("ocr")}}
    keep = [c for c in cases if not checker.reason(as_item(c)) and (c["transcript"], c.get("selection")) not in train_keys]
    print(f"held-out: {len(keep)}/{len(cases)} cases (rest overlapped bench or training)", file=sys.stderr)
    return keep


# ---------- main ----------

def jl(path):
    return [json.loads(l) for l in Path(path).read_text().splitlines() if l.strip()]


def write(path, items):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(i, ensure_ascii=False) + "\n" for i in items))
    print(f"wrote {len(items)} → {path}", file=sys.stderr)


def list_keeps_casing(it):
    """Bullet/numbered targets keep each item as dictated ("- milk", not "- Milk"), as the bench and users expect."""
    if it["cat"] not in ("e-bullets", "e-numbered"):
        return True
    lines = json.loads(it["target"])["text"].split("\n")
    return all(re.sub(r"^(- |\d+\. )", "", l) in it["selection"] for l in lines)


def prepass_mismatch(row, cat):
    """Why a rendered dictation row's target doesn't carry the digits and marks the pre-pass left in its
    transcript, or None (#48, #59). Spoken lists add line breaks and numbered lines, so those are allowed."""
    m = re.search(r"<transcript>(.*)</transcript>", row["messages"][1]["content"], re.S)
    if not m or row["messages"][-1]["role"] != "assistant":
        return None
    said, target = html.unescape(m.group(1)), row["messages"][-1]["content"]
    nums = lambda s: Counter(re.findall(r"(?<![\w.])\d+(?:[.:,]\d+)*(?!\w)", re.sub(r"(?m)^\d+\. ", "", s)))
    if extra := nums(target) - nums(said):
        return f"target digits {sorted(extra)} not in transcript {said!r}"
    for mark in "“”()" + ("" if cat == "d-list" else "\n"):
        if target.count(mark) != said.count(mark):
            return f"{mark!r} count differs: {said!r} → {target!r}"
    return None


def program_items():
    """Every item whose target is built here (no audio, no teacher)."""
    return (text_dictation() + program_edits() + v3_dictation() + v3_edits() + v4_dictation() + v5_dictation() + v5_edits()
            + v6_dictation())


def main(cmd):
    if cmd == "check":
        check_v5()
        check_v6()
    elif cmd == "speak":
        write(OUT / "speak.jsonl", speak_items())
    elif cmd == "teach":
        write(OUT / "teach.jsonl", teach_items())
    elif cmd == "build":
        items, skipped = [], {}
        if (OUT / "heard.jsonl").exists():
            items += audio_dictation(jl(OUT / "speak.jsonl"), {h["id"]: h for h in jl(OUT / "heard.jsonl")})
        else:  # the manifest says so, or its counts read as dropped *-audio categories
            skipped["audio"] = "no heard.jsonl (PoptalkDatagen transcribe not run)"
        items += program_items()
        if not (OUT / "teach_out.jsonl").exists():  # SKIP_TEACH=1 make_data.zsh: build without teacher items
            n = len(jl(OUT / "teach.jsonl")) if (OUT / "teach.jsonl").exists() else 0
            print(f"teacher: skipped, no teach_out.jsonl ({n} items in teach.jsonl)", file=sys.stderr)
            skipped["teacher"] = "no teach_out.jsonl"
        else:
            replies = {o["id"]: o["output"] for o in jl(OUT / "teach_out.jsonl")}
            kept = 0
            for it in jl(OUT / "teach.jsonl"):
                if (t := teacher_target(it, replies.get(it["id"], ""))):
                    items.append({k: v for k, v in it.items() if k != "lang"} | {"target": t})
                    kept += 1
            print(f"teacher: {kept}/{len(replies)} kept", file=sys.stderr)
        bad = [it["id"] for it in items if not list_keeps_casing(it)]
        assert not bad, f"list targets must keep the dictated casing: {bad[:5]}"
        checker, clean, seen, rejected = Checker(), [], set(), {}
        for it in items:
            key = (it["transcript"], it.get("selection"), json.dumps(it.get("context"), sort_keys=True))
            if key in seen:
                continue
            seen.add(key)
            if (why := checker.reason(it)):
                rejected[it["cat"]] = rejected.get(it["cat"], 0) + 1
                print(f"contaminated {it['id']}: {why}", file=sys.stderr)
                continue
            clean.append(it)
        counts = {}
        for it in clean:
            counts[it["cat"]] = counts.get(it["cat"], 0) + 1
        write(OUT / "items.jsonl", clean)
        (Path("training") / "manifest.json").write_text(json.dumps(
            {"items": len(clean), "byCategory": dict(sorted(counts.items())), "contaminationRejected": rejected}
            | ({"skipped": skipped} if skipped else {}), indent=2) + "\n")
    elif cmd == "split":
        cats = {i["id"]: i["cat"] for i in jl(OUT / "items.jsonl")}
        rows, dropped = [], {}
        for row in jl(OUT / "rendered.jsonl"):
            if (why := prepass_mismatch(row, cats[row["id"]])):
                dropped[cats[row["id"]]] = dropped.get(cats[row["id"]], 0) + 1
                print(f"pre-pass mismatch {row['id']}: {why}", file=sys.stderr)
            else:
                rows.append(row)
        print(f"split: {len(rows)} rows, dropped for pre-pass mismatch: {dropped}", file=sys.stderr)
        R("split").shuffle(rows)
        n = max(100, len(rows) // 25)
        write(OUT / "data" / "valid.jsonl", [{"messages": r["messages"]} for r in rows[:n]])
        write(OUT / "data" / "train.jsonl", [{"messages": r["messages"]} for r in rows[n:]])
        Path("training/samples.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows[:40]))
    elif cmd == "heldout":
        keys = {(i["transcript"], i.get("selection")) for i in jl(OUT / "items.jsonl")}
        write(Path("training/heldout.jsonl"), heldout(keys))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "")
