#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# ///
"""Training items for the Poptalk cleanup/edit fine-tune (#21). Run from the repo root via make_data.zsh.

  gen.py speak            → out/speak.jsonl       dictation items to synthesize and transcribe (PoptalkDatagen transcribe)
  gen.py teach            → out/teach.jsonl       edit items whose target comes from the E4B teacher
  gen.py build            → out/items.jsonl       every item with its target, filtered and contamination-checked
  gen.py split            → out/data/{train,valid}.jsonl from out/rendered.jsonl (PoptalkDatagen render)

Dictation targets are the clean source text; edit targets are exact where programmatic, else the
teacher's reply after checks. Items: {id, cat, transcript, selection?, context?, vocabulary?, target}."""
import difflib
import json
import random
import re
import sys
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


def correction(r):
    """(spoken, clean) for a self-correction like "on Tuesday, no, Thursday"."""
    tmpl, kind = r.choice(L.CORRECTABLE)
    pool = {"day": L.DAYS, "time": L.TIMES, "num": L.NUMBERS, "place": L.PLACES, "month": L.MONTHS,
            "person": [p for p, _ in L.PEOPLE if p.isascii()]}[kind]
    a, b = r.sample(pool, 2)
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
                ej("edit", "\n".join(f"{k + 1}. {cap(x)}" for k, x in enumerate(items))))
        else:
            add("e-bullets", i, r.choice(L.BULLETS), sel, edit_ctx(r), ej("edit", "\n".join(f"- {cap(x)}" for x in items)))

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
    checker = Checker()
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


def main(cmd):
    if cmd == "speak":
        write(OUT / "speak.jsonl", speak_items())
    elif cmd == "teach":
        write(OUT / "teach.jsonl", teach_items())
    elif cmd == "build":
        items = []
        if (OUT / "heard.jsonl").exists():
            items += audio_dictation(jl(OUT / "speak.jsonl"), {h["id"]: h for h in jl(OUT / "heard.jsonl")})
        items += text_dictation() + program_edits()
        if (OUT / "teach_out.jsonl").exists():
            replies = {o["id"]: o["output"] for o in jl(OUT / "teach_out.jsonl")}
            kept = 0
            for it in jl(OUT / "teach.jsonl"):
                if (t := teacher_target(it, replies.get(it["id"], ""))):
                    items.append({k: v for k, v in it.items() if k != "lang"} | {"target": t})
                    kept += 1
            print(f"teacher: {kept}/{len(replies)} kept", file=sys.stderr)
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
            {"items": len(clean), "byCategory": dict(sorted(counts.items())), "contaminationRejected": rejected}, indent=2) + "\n")
    elif cmd == "split":
        rows = jl(OUT / "rendered.jsonl")
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
