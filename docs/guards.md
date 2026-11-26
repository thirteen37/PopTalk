# Dictation guards

A dictation goes through the cleanup model, and the model can get it wrong: it can answer instead of cleaning, keep only the last sentence, drop a quote, or copy the screen. The guards are the string code around the model that fixes or catches those replies. This page covers what each one does, the order they run in, and what they cost and buy on the default model. The rest of the pipeline is in [How PopTalk works](how-it-works.md).

The guards are in `Sources/PoptalkCore/Pipeline.swift` (#108).

## Architecture

Pipeline keeps three named, ordered lists. Each step has a name, so the bench and the replay can turn it off and report which one fired.

- **`Pipeline.prepass`** rewrites the transcript before the model sees it. Its output is also what a raw fallback inserts, so spoken formatting survives a rejected reply.
- **`Pipeline.repairs`** rewrite the model's reply. Every repair runs, in order, on every reply.
- **`Pipeline.rejects`** test the repaired reply. The first one that holds turns the dictation into a raw fallback: the pre-passed transcript is inserted instead (label "Dictated (raw)"), and `PipelineResult.rejectedBy` is that reject's name. The ones after it don't run.

`Pipeline.guardNames` is the three lists in order. `PipelineResult.repaired` names the repairs that changed a reply beyond surrounding whitespace (#117), for the replay's counts.

### Prepass

| Step | Catches | Does | From |
| --- | --- | --- | --- |
| `spokenFormatting` | "quote … unquote", "open paren … close paren", "new line", "new paragraph" | Writes “…”, (…), `\n` and `\n\n` in code. A lone "quote", "quote and unquote", or a "new line" that isn't its own punctuated unit ("draw a new line") stay words. | #48 |
| `spokenCancel` | "scratch that" / "delete that" as its own unit | Drops the sentence before it and the command. With no sentence before it in this dictation, it stays literal. If everything is cancelled, nothing is inserted. | #98 |
| `spokenNumbers` | Number words | Writes digits where they're unambiguous: "twenty five percent" → 25%, "three thirty pm" → 3:30 PM, "one hundred and five" → 105. Zero to nine stay words in prose. | #59 |

### Repairs

| Step | Catches | Does | From |
| --- | --- | --- | --- |
| `stripChatter` | `<think>…</think>` blocks and echoed `<transcript>` tags | Removes them and trims the reply. | chatter guard, 42dfd60 (no issue) |
| `restoreMarks` | Marks the prepass made that the model changed or added | Curly quotes the model straightened go back, with a `,` or `.` it moved inside put back outside. A line break the model flattened goes back between the same two words, if the reply has them next to each other. A list marker the model put on a lone item goes, unless the transcript is a list. | #75, #77 |
| `openingCue` | An opening "no", "sorry", "wait" or "actually" the model dropped (E2B v6 reads it as a self-correction with nothing before it) | Puts the cue back as "No, " and lowercases the next word, unless that word is "I", an acronym or a name. Not after a spoken cancel. | #105 |

### Rejects

| Step | Holds when | From |
| --- | --- | --- |
| `empty` | Nothing is left after the repairs. | the first pipeline, abf4563 (no issue) |
| `length` | The reply is longer than `maxCleanupLength`: 1.5 × the transcript's characters + 40. A reply that long is the model answering, not cleaning. | chatter guard, 42dfd60 (no issue); early stop #100 |
| `dropsContent` | The reply lost more than 3 content words and more than 40% of them: the model kept only part of the dictation. After a spoken cancel ("scratch that", "never mind", "forget that"), only the words after the last cue count. | #47, #102 |
| `dropsProtected` | A ( … ), “ … ” or " … " span from the transcript isn't in the reply in order, or the reply has fewer line breaks than the transcript. | #61 |
| `echoesContext` | At least 3 of the reply's words, and more than half of them, weren't said but are on the screen: the model copied `<screen>`. | #29 |

The order matters. `length` runs before `echoesContext`, so a long screen echo is counted as `length`. #116 is about those echoes and proposes swapping the two; what is inserted doesn't change either way, only the `rejectedBy` count.

### Other mechanisms

- **`ReplyCheck`.** What a reject sees besides the reply and the transcript: the `maxCleanupLength` limit, and the screen the model saw (window title and domain, then the trimmed screen text).
- **`maxCleanupLength` and `replyLimit` (#100).** During a dictation cleanup, `Pipeline.replyLimit` (a task-local) holds `maxCleanupLength`. The MLX and LM Studio providers check `pastReplyLimit` as the reply streams and stop generating once the reply is certainly past the limit, with a 20-character margin for what the repairs can still remove. That reply would be rejected by `length` anyway, so stopping early only saves time. An open `<think>` never stops, since it may still be stripped. Edits have no limit: they can legitimately grow. Nor does a cleanup with `length` off (#118), so a `-length` or model-only run scores the whole reply.
- **Skip gate (`skipsLLM`, #75, experimental, off).** A dictation with no filler or correction cue, no spoken command left after the prepass, Parakeet's sentence casing and closing punctuation, and no near-miss of a term goes in as heard, without the model (label "Dictated", `skippedLLM`). Setting: "Skip cleanup for clean dictations"; `POPTALK_SKIP_LLM=1` forces it on.
- **Timeout (#3).** The cleanup has 4 s plus 20 ms per word. A timeout, or any other provider error, inserts the pre-passed transcript as a raw fallback with no `rejectedBy`.
- **Model loading (#31, #39).** If the model isn't loaded yet, the provider throws `ModelLoading` and the pre-passed transcript goes in labelled "Dictated (raw) · model loading". The result is `degraded`, so the overlay offers **clean up now** once the model is ready, and live preview doesn't reuse it.
- **Before the prepass.** `stripHesitations` drops um, uh, er, erm and hmm on every path; an empty result inserts nothing. Then, for E2B fine-tunes with "Fix screen-term casing before cleanup" on, the casing fix (`recaseTerms`, #75, #71) gives words that match a saved, learned or screen term up to case its spelling, and the experimental sound-alike check (`soundAlikeTerms`, off) can write a term the model confirms. Both are in [Matching names and terms](how-it-works.md#matching-names-and-terms).

### Turning guards off

`DictationFeatures.guardsOff` is a set of step names that `Pipeline.run` skips. The app never sets it; only `PoptalkBench --guards` does:

```sh
.build/release/PoptalkBench --provider mlx --cleanup-model adapters/gemma-4-e2b-poptalk-v6 --filter 'd-*' --guards -length
```

`--guards` takes a comma-separated list of `-name`, where a name is any of `Pipeline.guardNames` or a whole list: `-prepass`, `-repairs`, `-rejects`. It works in bench mode and in `--replay` (`scripts/replay.zsh --guards`). Result files get a `-guards` suffix, or `-model` when every repair and reject is off. `training/bench.zsh` runs the model-only pass with `--guards -repairs,-rejects`; it keeps the prepass, which shapes what the model is asked.

Turning `length` off also turns off the `replyLimit` early stop (#118), so a `-length` or model-only run scores the whole reply. Before #118 it scored a reply cut at the limit; on the bench that changed nothing, since no reply there reaches the limit (`d`, `e`, `h`, `s`, guards on and model only: identical outputs before and after, [`bench/results/replylimit-118/`](../bench/results/replylimit-118/)).

### Edits

Edits (a selection, or tap-then-hold on the last insert) don't go through the repairs or the rejects. They have their own checks in `Pipeline.run`: "literally", a trailing spelling and "replace this with" are handled in code; the model's reply must parse as an edit; an insert the instruction didn't ask for becomes a replace; a blank replacement does nothing; and an insert that repeats the selection has it removed. A failed or timed-out edit leaves the selection unchanged and says so.

## Sequence

From the transcript Parakeet returns to the text that goes in, for a dictation (no selection):

```mermaid
flowchart TD
    T[Transcript] --> H[stripHesitations]
    H -->|empty| N1([Nothing])
    H --> S{Selection?}
    S -->|yes| E([Edit path: no repairs or rejects])
    S -->|no| R[Casing fix and sound-alike terms<br/>E2B fine-tunes, setting on]
    R --> P[Prepass: spokenFormatting, spokenCancel, spokenNumbers]
    P -->|all cancelled| N2([Nothing])
    P --> G{Skip gate on and skipsLLM?}
    G -->|yes| K([Insert as heard: skippedLLM])
    G -->|no| M[Cleanup model, replyLimit = maxCleanupLength<br/>timeout 4 s + 20 ms/word]
    M -->|ModelLoading| L([Raw: model loading, degraded])
    M -->|timeout or error| O([Raw, no rejectedBy])
    M -->|reply| F[Repairs: stripChatter, restoreMarks, openingCue]
    F --> J{First reject that holds:<br/>empty, length, dropsContent,<br/>dropsProtected, echoesContext}
    J -->|one holds| X([Raw: rejectedBy = its name])
    J -->|none| C([Insert the cleaned reply])
```

1. `stripHesitations`. If nothing is left: **nothing** is inserted.
2. With a selection, the edit path runs instead; the rest of this list is dictation only.
3. The casing fix and, if on, sound-alike terms.
4. The prepass, in order: `spokenFormatting`, `spokenCancel`, `spokenNumbers`. If everything was cancelled: **nothing**.
5. The skip gate, if on. If `skipsLLM` holds: the pre-passed transcript goes in, **skipped LLM**.
6. The cleanup model, with `replyLimit` set and the timeout. Model still loading: **raw, model loading** (degraded). Timeout or error: **raw on timeout**.
7. The repairs, in order: `stripChatter`, `restoreMarks`, `openingCue`.
8. The rejects, in order: `empty`, `length`, `dropsContent`, `dropsProtected`, `echoesContext`. The first that holds: **raw on reject**, with `rejectedBy`.
9. Otherwise: the **cleaned** reply goes in.

Every insert gets a leading space when the cursor follows a non-space that isn't an opening bracket or quote. A raw fallback always inserts the transcript after step 4, so spoken formatting, cancels and numbers survive it.

## Performance

Measured 2026-11-26 on main d545fb6 (with #117's counts-only `repaired` field, which doesn't change what is inserted), with the default model: the E2B v6 LoRA `adapters/gemma-4-e2b-poptalk-v6` on base Gemma 4 E2B, MLX, an M-series Mac (Mac17,9). The numbers go stale when the model, the prompts, the guards or the bench cases change. Results: [`bench/results/guards-117/`](../bench/results/guards-117/).

### What the guards buy on the bench

`training/bench.zsh` runs each set with the guards on (the ship gate) and again model only (`--guards -repairs,-rejects`). Runs passed, of 3 runs per case:

| Set | Guards on | Model only | Change |
| --- | --- | --- | --- |
| d-* dictation (74 cases) | 204/222 | 198/222 | +6 |
| h-* held-out (88 cases) | 258/264 | 255/264 | +3 |
| e-* edits (18 cases) | 51/54 | 51/54 | 0 (edits don't use the guards) |

The +9 come from 3 cases: `d-fmt-new-line`, `d-fmt-new-paragraph` (0/3 → 3/3) and `h-d-keep-1` (0/3 → 3/3). With the guards on, the only reject that fired was `dropsContent`: 9 d runs and 1 of 50 s-* speech runs.

Then each repair and each reject turned off on its own (`--guards -name`, d-* and h-* with 3 runs), against the guards-on runs above:

| Step off | d runs | h runs | Cases that change |
| --- | --- | --- | --- |
| `stripChatter` | 204 (0) | 258 (0) | none |
| `restoreMarks` | 198 (−6) | 258 (0) | `d-fmt-new-line`, `d-fmt-new-paragraph` 3/3 → 0/3: the model flattens the spoken line break, and without the repair `dropsProtected` rejects the reply |
| `openingCue` | 204 (0) | 255 (−3) | `h-d-keep-1` 3/3 → 0/3: the reply loses the opening "No" |
| `empty` | 204 (0) | 258 (0) | none |
| `length` | 204 (0) | 258 (0) | none |
| `dropsContent` | 204 (0) | 258 (0) | outputs change, pass counts don't: `d-xs-oh-sorry-day`, `d-xs-no-wait-number`, `d-cancel-never-mind` |
| `dropsProtected` | 204 (0) | 258 (0) | none |
| `echoesContext` | 204 (0) | 258 (0) | none |

On the bench, two repairs carry the whole gain. `dropsContent` catches a real failure in the three cases it changes (the cleanup drops a sentence, or keeps the cancelled part instead of what follows), but the raw transcript it falls back to fails those cases too, because it keeps the words the speaker corrected away. The other rejects never hold on the bench: v6 doesn't answer, think aloud or echo the screen on these cases. They guard against what the replay below sees.

### How often they fire on real use

`scripts/replay.zsh current current` on the same day: 492 history dictations, two passes back to back, identical outputs (`diff` 0). Counts only:

| Step | Fired | Of 492 |
| --- | --- | --- |
| `length` (reject) | 2 | 0.4% |
| `dropsContent` (reject) | 1 | 0.2% |
| `empty`, `dropsProtected`, `echoesContext` (rejects) | 0 | |
| `openingCue` (repair) | 4 | 0.8% |
| `stripChatter`, `restoreMarks` (repairs) | 0 | |
| Timeouts | 0 | |

A repair counts when it changed the reply beyond surrounding whitespace, whether or not the reply was then used (`PipelineResult.repaired`, the replay's `chatter`, `marks` and `cue` columns). So 3 of 492 real dictations went in raw, and the guards changed 4 more. #116 found that `length` hits are mostly screen echoes over long terminal screens, counted as `length` because it runs first.

### What they cost

The prepass, repairs and rejects are string code. Per call, median of 200, PoptalkCore built with `-O`, on invented text (a 38-word, 204-character dictation and a 190-word, 1,020-character one; a 64-term list; a 40-line, 4,000-character screen). `Tests/PoptalkCoreTests/GuardTimingTests.swift` has the code: `POPTALK_GUARD_TIMING=1 swift test --filter guardTiming` runs it in debug, and these numbers come from the same body compiled with `swiftc -O -swift-version 6 -module-name PoptalkCore Sources/PoptalkCore/*.swift`. The casing fix was re-measured with #121.

| Step | 38 words | 190 words |
| --- | --- | --- |
| `stripHesitations` | 0.01–0.03 ms | 0.03 ms |
| Casing fix (`recaseTerms`) | 0.47 ms (19.9 ms before #121) | 0.78 ms (20.1 ms) |
| `spokenFormatting` | 0.23 ms | 0.42 ms |
| `spokenCancel` | 0.10 ms | 0.14 ms |
| `spokenNumbers` | 0.17 ms | 0.77 ms |
| `stripChatter` | < 0.01 ms | < 0.01 ms |
| `restoreMarks` | 0.04 ms | 0.19 ms |
| `openingCue` | < 0.01 ms | < 0.01 ms |
| `empty`, `length` | < 0.01 ms | < 0.01 ms |
| `dropsContent` | 0.05 ms | 0.25 ms |
| `dropsProtected` | 0.07 ms | 0.23 ms |
| `echoesContext` | 0.17 ms | 0.25 ms |
| Skip gate (`skipsLLM`, off), on a clean dictation of the same length (median of 9) | 170 ms | 870 ms |

The prepass, repairs and rejects together take about 0.9 ms on the short dictation and 2.3 ms on the long one, against 0.31 s mean for the cleanup itself on the replay (p90 0.49 s). The casing fix runs by default with v6, once per dictation, so its cost isn't per word: it scales with the terms and the screen. It case-folds the transcript and the screen once (about 0.35 ms of it for this screen), then searches the transcript for each term, and the screen only for the terms the transcript has. Before #121 it compiled a regex per term and scanned the whole screen with each, about 20 ms whatever the length. The skip gate is off by default and would cost more than the cleanup it skips on long dictations (#120).

The `replyLimit` early stop: on the 2 history dictations `length` rejects, the cleanup takes 0.84 s and 0.56 s with it (median of 3) and 2.32 s and 2.01 s with it patched out, about 1.5 s saved per hit. Without it the replies run on to 384 and 574 characters instead of being cut at 146 and 114, and are rejected either way. The bench has no `length` hits, so it doesn't show this, and the timing log (`log stream`, category `timing`, "stopped at reply limit") isn't kept by default. Since #119 the provider waits for the stopped generation to finish its step before it returns (a replay whose last dictation stopped early used to crash at exit).

### Known issues

- #116: `length` runs before `echoesContext`, so screen echoes are counted as `length`.
- #120: the skip gate's term shortlist is slower than the cleanup it skips.
