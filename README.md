# PopTalk

Dictation for macOS that uses what's on your screen, and what it has learned from past dictations, to get names and terms right. It runs entirely on your Mac.

<!-- Demo GIF: dictate a sentence with a name that's visible on screen, then select a misheard word and fix it by spelling it aloud. -->

Hold right ⌥, talk, let go. PopTalk types what you said at the cursor, with fillers and false starts removed. If text is selected, what you say is treated as an instruction about the selection instead.

## Why PopTalk

- Context changes what the speech recogniser hears. While you hold the key, PopTalk collects terms from the focused field, the text near it, the window title and the web domain, with OCR as a fallback when an app hides its text. Those terms and your vocabulary are used to boost recognition (CTC vocabulary boosting on Parakeet) and to fix the casing of matching words. A local language model (a PopTalk fine-tune of Gemma 4 E2B) then cleans up the text with the same context. Cloud dictation services can steer recognition like this on their servers. Other local apps tend to give screen context only to a cleanup model after recognition, or use it to set the tone per app.
- You can fix a mistake by speaking or typing. Select a misheard word and say *"it's Todoist, capital T-O-D-O-I-S-T"*. If you correct it by typing instead, PopTalk offers to add the term to your vocabulary. There's also an opt-in setting to remember screen terms that fixed a dictation, so later dictations get them right when they're no longer on screen.
- It edits selected text by voice: "make this more formal", "turn this into bullet points", "translate to Japanese". One model decides whether you're correcting a word, replacing the selection, editing it, or inserting text before or after it.
- A double tap of right ⌥ undoes any result, terminals included (there it deletes the dictated text with backspaces).
- It's free and MIT licensed, with no account. Audio, text and screen content stay on your Mac.

## Accuracy

PopTalk's speech benchmark, with Parakeet TDT v2 and the default model (PopTalk's Gemma 4 E2B v6 fine-tune):

| Stage | Word error rate, real voice | Word error rate, synthetic | Terms right, real voice | Terms right, synthetic |
| --- | --- | --- | --- | --- |
| Parakeet alone | 15.1% | 14.5% | 58% | 73% |
| With context boosting | 11.5% | 7.4% | 71% | 94% |
| After cleanup with context | 12.8% | 9.5% | 86% | 98% |
| Dictations fully right | 34 of 50 | 46 of 50 | | |

These are 50 invented dictations, most of them using screen context or vocabulary terms. They cover names, spoken formatting, numbers, self-corrections and a few long dictations. "Real voice" is one person reading them naturally, not word for word. "Synthetic" is macOS text-to-speech voices, averaged over 3 runs. Terms right counts screen and vocabulary terms with any casing. Cleanup can raise word error rate over boosting alone: it removes fillers, resolves self-corrections and rewords, and the reference text doesn't always match those choices. Treat the numbers as an indication: one speaker, 50 cases. Synthetic results: [`bench/results/parakeet-114/v2-mlx/`](bench/results/parakeet-114/v2-mlx/). The real-voice recordings and results stay local (see [real-voice bench](docs/real-voice-bench.md)).

## Install

1. Download the DMG from [GitHub Releases](https://github.com/thirteen37/Poptalk/releases). It's notarized by Apple.
2. Open it and drag PopTalk to Applications, then launch it from there.
3. Grant Microphone, Accessibility (to read and insert text) and Screen Recording (only used for the OCR fallback). The menu-bar icon shows what's missing.

Models download on first use. The default language model's base, Gemma 4 E2B, is about 3.3 GB; PopTalk strips it to a 2.5 GB text-only copy in `~/Library/Application Support/Poptalk/models` and deletes the download. A model already in your Hugging Face cache is copied from there instead.

### Build from source

You need a Swift 6 toolchain (Xcode or the command line tools), Xcode's Metal toolchain for MLX (`xcodebuild -downloadComponent MetalToolchain`), and a code-signing certificate so macOS keeps the app's permissions between builds. A free Apple Development certificate works; `scripts/install.zsh` explains the one-time setup.

```sh
git clone https://github.com/thirteen37/Poptalk.git
cd Poptalk
scripts/install.zsh        # builds, signs, installs to /Applications and launches
```

## Using it

| Right ⌥ | Does |
| --- | --- |
| Hold | Dictate, or edit the selection |
| Tap | Accept the showing offer, or cancel a recording |
| Double tap | Undo |
| Tap, then hold | Edit the last insert |

- To dictate, hold right ⌥, talk and release. A tap shorter than 300 ms, or pressing another key while ⌥ is down, cancels. The tap length and the double-tap speed (0.4 s) are under advanced options in Settings → General. While you hold the key, the overlay shows the live transcript and, at each pause, the cleaned-up text.
- To edit, select text, hold right ⌥ and say what to do with it.
- To edit what PopTalk just inserted, tap right ⌥, then press it again and hold: say the replacement, or what to change ("make that shorter"). It works while the text is as PopTalk left it (in a terminal: nothing typed since); otherwise the overlay says "Nothing to edit".
- Double-tap right ⌥ while the overlay is showing (5 s by default) to undo. When it offers something (a word for your vocabulary, a cleanup), a single tap accepts it, once the 0.4 s a second tap could take has passed. PopTalk doesn't catch Esc or Return, so they always reach the app. In terminals (Terminal, iTerm2, Ghostty and apps built on it such as Herdr, and others) this works only if you haven't typed since and the dictation has no line break.
- You can also correct the inserted text by typing. About 2 s after you stop, if you replaced a misheard name or term, the overlay offers to add it to your vocabulary; tap right ⌥ to accept.
- Settings → Vocabulary lists your terms, each with optional "heard as" forms. PopTalk never adds one without asking.
- "New line", "new paragraph", "quote … unquote" and "open paren … close paren" are applied as formatting, and spoken numbers become digits where that's unambiguous.

The full details, including the overlay, the safety net when cleanup drops content, and every setting, are in [How PopTalk works](docs/how-it-works.md).

## Limits

- Needs an Apple Silicon Mac with macOS 14 or later. It's macOS only.
- English first. The default speech model, Parakeet TDT v2, is English only. Parakeet TDT v3 and Parakeet Ultra (in Settings → Models) recognise 25 European languages, but the cleanup prompts and the benchmarks are English.
- Uses about 1.6 GB of memory with the default models (about 3 GB with Gemma 4 E4B). On a Mac with 8 GB or less, choose Apple's on-device model in Settings → Models (macOS 26 with Apple Intelligence): macOS runs it outside PopTalk.
- Context comes from what apps expose through Accessibility, plus OCR. Fixing by typing only works in apps whose text fields PopTalk can read, and not in terminals.

## Privacy

PopTalk reads the focused field, nearby text, the window title, the web domain and, when an app hides its text, an OCR crop around the field. It never reads password fields, password managers or private browser windows, and each source can be turned off in Settings → Context, or for one app or website in Settings → Apps (also from the menu bar: "Don't Read the Screen in ‹app›"). A source turned off is never read. Remembered screen terms are opt-in and stay on this Mac. Usage history is off by default; if you turn it on, it's stored locally (audio optional), can be wiped with one button, and can optionally sync between your Macs through iCloud Drive, without audio. Apart from that sync and model downloads, nothing leaves the Mac.

## Development

```sh
swift build
swift test                                   # PoptalkCore and PoptalkMLX tests (Swift Testing)
swift build -c release && zsh training/bench.zsh mlx-community/gemma-4-e4b-it-4bit   # benchmark: dictation, edits, speech, held-out set; then model only, guards off
```

The targets are `PoptalkCore` (prompts, pipeline, policies; pure and tested), `PoptalkSpeech` (speech recognition and boosting), `PoptalkMLX` (in-process models), `Poptalk` (the menu-bar app), and `PoptalkBench` and `PoptalkDatagen` (benchmark and training-data tools). `bench/` holds the benchmark cases and committed results; compare runs with `PoptalkBench --compare a.json b.json`. `training/` has the synthetic data generation and LoRA training (`mlx_lm.lora`, run with `uv`; see `training/make_data.zsh` and `training/lora.yaml`), and `training/gepa_prompts.py` tunes prompts for models without a fine-tune. The pipeline, diagrams and A/B environment variables are in [How PopTalk works](docs/how-it-works.md).

## License

MIT, see [LICENSE](LICENSE). Language and speech models are downloaded at runtime under their own licenses.
