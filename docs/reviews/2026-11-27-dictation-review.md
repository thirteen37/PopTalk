# Dictation logic review, 2026-11-27

A read-only review of the dictation logic on main (dca03b1): the pipeline, prompts, vocabulary and screen-term handling, the prepass, speech, MLX, and the bench where it affects dictation quality. Nothing was built or run.

Two claims were checked with Python re-implementations of the Swift regexes and thresholds; they are marked "simulated". The rest come from reading the code. None duplicates an open or closed issue.

## Summary

| # | Finding | Size | Verification |
| --- | --- | --- | --- |
| 1 | `stripHesitations` deletes "ER", "err", "UM" and a final `%` or `#` | S | Tests; no retrain |
| 2 | The time rule turns "which one am I" into "1 AM I" | S | Bench case and re-run; no retrain |
| 3 | `dropsContent` thresholds are unfitted and blind on short dictations | S | `--fidelity-pairs` and replay |
| 4 | The casing fix capitalises ordinary phrases that match a Title Case UI label | S–M | Bench and replay; may need training rows |
| 5 | The screen part of the prompt is prefilled at release, not during the hold | M | Replay for latency and output diff |
| 6 | Inserts ignore where the cursor is, beyond one leading space | S or L | Owner decides which |
| 7 | Dictation bench cases pass on substrings, so rewording is invisible | S–M | No retrain |
| 8 | `TermExtractor`'s 60-term cap is applied before the common-word filter | S | s-* bench; attach to #132 |
| 9 | `echoesContext` counts the model's correct term fixes as an echo | S | Replay |
| 10 | `applyBoosts` writes a term onto the first occurrence of the span | M | Tests and s-* bench |
| 11 | Replies are never unescaped | S | No retrain |
| 12 | `isCommonWord` probably treats words the user taught macOS as dictionary words | S | Two-line test |
| 13 | Two small waits on the release path | S | Check the timing mark first |
| 14 | The cancel cue "forget the/it/that" is unanchored and switches two guards off | S | Tests and replay counts |
| 15 | Doc and code gaps, and duplication | S | None |

Findings 1 and 2 are the ones to do first: both are deterministic, corrupt ordinary sentences, and survive a raw fallback.

## Findings

### 1. `stripHesitations` deletes real words: "ER", "err", "UM", and a final `%` or `#`

- **Where:** `Sources/PoptalkCore/Pipeline.swift:318` (regex), `:380` (trim)
- **What is wrong:** The pattern `e+r+m*` is case-insensitive, so it matches "ER" and "err"; `u+m+` matches "UM". Simulated:
  - "We took him to the ER last night." → "We took him to the last night."
  - "I'd rather err on the side of caution." loses "err".
  - "She studied at UM for two years." loses "UM".
- It runs before the model on every non-Shift path, so the raw fallback loses the word too.
- The trim set at `:380` is all punctuation except `.!?"')`, which includes `%` and `#`. "up 25%" with no final period becomes "up 25".
- **Fix:** Skip all-caps matches of 2+ letters, require a single `r` in "er", and trim only `,;:` and dashes.
- **Size:** S
- **Verification:** No retrain. Add tests; a replay count of changed transcripts is optional.

### 2. The time rule turns "which one am I" into "1 AM I"

- **Where:** `Sources/PoptalkCore/SpokenNumbers.swift:184-190`, applied at `:21`
- **What is wrong:** The hour-plus-`am` pattern matches the verb "am". Simulated: "Which one am I supposed to use?" → "Which 1 AM I supposed to use?".
- It is a prepass step, so it survives a raw fallback, and the prompt tells the model to keep digits as given.
- `SpokenNumbersTests` has only positive am/pm cases.
- **Fix:** Add a `(?!\s+I\b)` lookahead on the bare `am` form (not `a.m.`, not with minutes).
- **Size:** S
- **Verification:** No retrain. Add a `d-num` bench case and re-run the bench, since the prepass shapes prompts.

### 3. `dropsContent` thresholds were never fitted, and the floor blinds it on short dictations

- **Where:** `Sources/PoptalkCore/Pipeline.swift:425-434`
- **What is wrong:** It needs more than 3 lost content words and more than 40%. In the invented fidelity pairs, 13 of 27 "drop" rows lose 3 or fewer, so half a two-sentence dictation can vanish unnoticed.
- Simulated on `training/fidelity_pairs.jsonl` and `fidelity_pairs_heldout.jsonl` together:

| Rule | Drops caught | Answers caught | False rejects (61 acceptable rows) |
| --- | --- | --- | --- |
| Current (>3 lost, >40%) | 10/27 | 11/28 | 0 |
| ≥3 lost, >40% | 12/27 | 16/28 | 0 |
| ≥3 lost, >34% | 16/27 | 17/28 | 0 |
| ≥2 lost, >40% | 15/27 | 17/28 | 0 |

- The simulation fits and scores on the same rows, and the pairs' transcripts are unpunctuated, so treat the numbers as a direction, not a result.
- **Fix:** Move the two constants, then confirm with `PoptalkBench --fidelity-pairs` and a replay. The replay matters most: real self-corrections lose 1–3 words, and that is where false rejects would show.
- **Size:** S
- **Verification:** No retrain; needs bench and replay.

### 4. The casing fix capitalises ordinary phrases that match a Title Case UI label

- **Where:** `Sources/PoptalkCore/TermRecase.swift:23-24` and `:51`; `Sources/PoptalkCore/TermExtractor.swift:61-66`
- **What is wrong:** A phrase made only of dictionary words is recased from the screen. Mail's compose window is titled "New Message", so "send a new message to Dana" becomes "send a New Message to Dana". "Pull Requests", "Recent Files" and "Sent Items" behave the same.
- This is on by default for v7. It is the code doing what #134 reports the model doing, and the phrase analogue of #130.
- The ponytail comment at `:23` admits the ceiling.
- `PoptalkDatagen render` never recases, so the model has only seen un-recased transcripts and keeps the capitals it is given.
- **Fix:** Recase all-dictionary phrases only from saved vocabulary, not from the screen or learned terms, and stop learning them.
- **Size:** S–M
- **Verification:** Bench and replay. `d-meal-prep` may regress and then need training rows.

### 5. Latency: the screen part of the prompt is prefilled at release, not during the hold

- **Where:** `Sources/PoptalkMLX/MLXProvider.swift:315-326`; `Sources/Poptalk/AppDelegate.swift:251-261`
- **What is wrong:** A screen snapshot is stored only once a second prompt repeats it, and speculative runs never store one. The field text comes before the nearby text and changes with every insert, and OCR text comes before both.
- So most presses prefill 1–2k screen tokens after key-up. The #116 table in guards.md puts that at roughly 60–100 ms at p50, more on long screens.
- **Fix:** When capture finishes during the hold, prefill up to `<transcript>` and store that snapshot (the shared token prefix of two prompts that differ only in transcript). A dictation of 5 words or fewer gets a different prompt, so its prefill is wasted; accept that or skip it.
- **Check first:** History already records `promptTokens` and `sharedPrefix` per request, so the owner can count how often only the system prompt is reused.
- **Size:** M
- **Verification:** No retrain. Needs a replay for latency and an output diff, since guards.md notes the cache shifts outputs slightly.

### 6. Inserts ignore where the cursor is, beyond one leading space

- **Where:** `Sources/PoptalkCore/Pipeline.swift:532-542`; `Sources/PoptalkCore/Prompts.swift:81-83`
- **What is wrong:** The prompt has no cursor marker, and 0 of 10,751 v7 dictation targets start lowercase. Continuing "I talked to " with a new hold gives "I talked to The team said yes."
- There is also no trailing space when text follows the cursor: "Hello there.Existing text".
- **Fix, two options:**
  - A small insert-layer rule beside `leadingSpace`: lowercase the first word after a letter or comma, reusing the "I"/acronym/name check from `restoreOpeningCue`, and add a trailing space before a letter.
  - Add a cursor marker to the prompt and retrain.
- The first sits at the insert layer like `leadingSpace`, but the owner should decide whether it counts as a formatting rule.
- **Size:** S for the rule, L for the retrain
- **Verification:** Tests for the rule; retrain and bench for the marker.

### 7. Bench blind spot: dictation cases pass on substrings, so rewording is invisible

- **Where:** `Sources/PoptalkCore/Bench.swift:107-108`; `training/bench.zsh`
- **What is missing:** No dictation case in `bench/cases.jsonl` or `training/heldout.jsonl` uses `expectExact`. A grammar "fix" passes if the `mustContain` words survive.
- `training/word_changes.py` (#126) measures exactly this, but only `scripts/replay.zsh --words` calls it.
- No case sets `app` or `window`, so every bench prompt has `<screen app="" window="">`, which real use never has.
- Only two cases put a distractor name on screen (`d-no-invented-name`, `d-long-name-before-cursor`); that is the #134 gap.
- **Fix:** Run `word_changes.py` over the d/h/l outputs in `bench.zsh` and report the "other" rates beside pass counts; add app and window to cases; add distractor cases.
- **Size:** S–M
- **Verification:** No retrain.

### 8. `TermExtractor`'s 60-term cap is applied before the common-word filter

- **Where:** `Sources/PoptalkCore/Pipeline.swift:280-281`; `Sources/PoptalkCore/TermExtractor.swift:83-84`
- **What is wrong:** Every line-start word and Title Case label counts as a term ("Send", "Cancel", "Reply", "Thanks"). They are ranked, cut to 60, and only then dropped as dictionary words.
- In a label-heavy window, a real name 2,000 characters up the thread falls off the list, so it is neither recased nor boosted.
- **Fix:** Filter single dictionary words before `prefix(limit)`.
- **Size:** S
- **Verification:** s-* bench and replay counts. Worth attaching to #132, since it decides what boosting sees.

### 9. `echoesContext` counts the model's correct term fixes as an echo

- **Where:** `Sources/PoptalkCore/Pipeline.swift:402-407`, called at `:173-174`
- **What is wrong:** A word counts as echoed if it wasn't said verbatim and is on screen. Heard "add core vanta, grav links and toy vonen" with those names on screen → "Add Korvanta, Gravlynx and Toivonen." is 3 of 5 words echoed, so it is rejected and goes in raw.
- For dictations of 5 words or fewer it still checks the whole screen, though the model never saw it, so there it can only over-fire. The comment at `:334` says "the screen the model saw".
- **Fix:** Don't count a word that is at least 0.7 `similarity` to a 1–3-word run of the transcript, and pass only title and domain for short dictations.
- **Size:** S
- **Verification:** Replay (guard change).

### 10. `applyBoosts` writes a term onto the first occurrence of the span, not the one the rescorer scored

- **Where:** `Sources/PoptalkCore/SpokenAlias.swift:56-57`; `Sources/PoptalkSpeech/Transcriber.swift:96-99`
- **What is wrong:** FluidAudio's `RescoringResult` carries no position, and `text.range(of:)` takes the first match. If "data" is said twice and only the second is the saved name "Datta", the first is replaced.
- `BoostTests` has no repeated-span case.
- **Fix:** Pick the occurrence by aligning with `output.text`, which has the term in place.
- **Size:** M
- **Verification:** Tests plus the s-* bench. Related to #132 but a separate bug.

### 11. Replies are never unescaped

- **Where:** `Sources/PoptalkCore/Prompts.swift:114`; `Sources/PoptalkCore/Pipeline.swift:526`
- **What is wrong:** Screen, vocabulary and transcript go in XML-escaped. In v7's training data, 2,266 dictation prompts contain entities and no target does, and only 20 targets contain a bare `&`, `<` or `>`.
- A screen or vocabulary term such as "R&D" is shown to the model as `R&amp;D`, and nothing turns an echoed `&amp;` back. Not confirmed on the model (the GPU was busy).
- **Fix:** Unescape `&amp;`, `&lt;`, `&gt;`, `&quot;` in `stripChatter`, and in the edit path's text.
- **Size:** S
- **Verification:** No retrain; a test.

### 12. `isCommonWord` probably treats words the user taught macOS as dictionary words

- **Where:** `Sources/PoptalkCore/TermRecase.swift:113`
- **What is wrong:** `checkSpelling` with document tag 0 should honour the user's learned spellings. If so, a product name added via "Learn Spelling" is never recased or boosted from the screen, and results differ between Macs.
- I couldn't run it; a two-line test settles it.
- **Fix:** Treat a word as not common when `NSSpellChecker.shared.hasLearnedWord` is true.
- **Size:** S
- **Verification:** The test above.

### 13. Release-path latency: two small waits

- **Where:** `Sources/PoptalkCore/LivePreview.swift:48`; `Sources/Poptalk/AppDelegate.swift:325`
- **What is wrong:**
  - A speculative result that a guard rejected is thrown away and re-run. At temperature 0 it rejects again, and `length` rejects are the slowest calls.
  - Release awaits an in-flight preview tick, which is a whole-buffer ASR pass plus rescore, before the final transcription.
- **Fix:** Reuse a speculative result when `rejectedBy != nil`. For the second, the "release: preview drained" timing mark already measures it; check it on long dictations before changing anything.
- **Size:** S
- **Verification:** No retrain.

### 14. The cancel cue "forget the/it/that" is unanchored and switches two guards off

- **Where:** `Sources/PoptalkCore/Pipeline.swift:417-418`, used at `:428` and `:500`
- **What is wrong:** "I always forget the door code" matches. `dropsContent` then counts only the words after it, and `restoreOpeningCue` is skipped for the whole dictation.
- **Fix:** Require the cue to be its own punctuated unit, as `spokenCancel` does.
- **Size:** S
- **Verification:** Tests plus replay counts.

### 15. Doc and code gaps, and duplication

- how-it-works.md says single dictionary words "still feed the casing fix"; `recaseCandidates` drops them (`TermRecase.swift:51`).
- The guards.md performance section and known issues still describe v6. `TermRecase.swift:4` says "the default v6". `termScoreThreshold` (`SkipGate.swift:141`) is fitted for v6.
- `PipelineResult.rejectedBy`'s comment omits "fidelityProbe" (`Pipeline.swift:41`).
- `boostTerms`, a full `TermExtractor` scan, runs in `Pipeline.run`, at release and in `liveInput`: two or three times a press. Pass the list in.
- `VocabTerm.weight` is computed by `TermExtractor` but the rescorer ignores it.
- `Prompts.isS1Mini` and its prompt remain after the #67 evaluation.
- **Size:** S

## Considered and rejected

- **Substring matching in `dropsContent`** ("cat" kept by "communication"): simulated a word-boundary version on the fidelity pairs and it changed 0 of 27 drop rows.
- **`leadingSpace` on a surrogate half:** a lone surrogate bridges to U+FFFD, one Character, so no crash.
- **`restoreMarks` list-marker `^`** only matching at the string start: benign, a marker on a later line just stays.
- **"two PM candidates" → "2 PM candidates":** real but rare, and not separable without context.
- **Skip gate and sound-alike paths:** off, and their stale v6 threshold is already documented.
- **Prompt-format changes** (entity escaping inflating tokens on terminal screens, OCR-first ordering defeating the prefix cache, a cursor marker): each needs a retrain. Only the cursor marker is listed, as the alternative in finding 6.
- **A lone "new line" dictation:** it costs a model call and inserts " \n", but the result is safe.
- **`training/fuse.zsh`:** it fuses, but carries the #103 warning.
- **A new `VocabularyBoostingSession` per preview tick:** already covered by the rescore timing log, and small with saved vocabulary only.
