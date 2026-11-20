# PopTalk

Local voice dictation and voice editing for macOS. Hold **Right ⌥**, talk, let go.

- **Nothing selected:** PopTalk transcribes what you said, cleans it up (fillers, false starts, "Tuesday, no, Wednesday"), and types it at the cursor.
- **Text selected:** what you say is an instruction about the selection: "make this more formal", "turn this into bullet points", "translate to Japanese", or the case PopTalk was built for, fixing a misheard word: select "todo list" and say *"it's Todoist, capital T-O-D-O-I-S-T"*.

A small language model decides whether you're correcting, replacing, editing or inserting. Every result shows in a small overlay with **Esc to undo**.

Everything runs on your Mac. No audio, text or screen content leaves it.

## How it works

1. **Speech:** [Parakeet TDT v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) via [FluidAudio](https://github.com/FluidInference/FluidAudio), with CTC vocabulary boosting from your saved terms and from names visible on screen.
2. **Screen context:** the focused field, nearby text (Accessibility), the window title and the web domain, plus OCR around the field when an app hides its text. Password fields are never read. Each source can be turned off in Settings → Context.
3. **Language model:** Gemma 4 E2B running in-process with [MLX](https://github.com/ml-explore/mlx-swift-lm), plus a LoRA fine-tune trained for PopTalk's two jobs (`adapters/`). LM Studio and Apple's on-device model can be used instead.

On an M-series Mac, the time from releasing the key to inserted text is usually under a second. The memory footprint is about 2.8 GB.

## Requirements

- An Apple Silicon Mac running macOS 14 or later. The Apple Intelligence provider needs macOS 26 or later.
- A Swift 6 toolchain (Xcode or the command line tools) and Xcode's Metal toolchain for MLX: `xcodebuild -downloadComponent MetalToolchain`.
- A code-signing certificate, so macOS keeps the app's permissions between builds. A free Apple Development certificate works; `scripts/install.zsh` explains the one-time setup.

## Install

```sh
git clone https://github.com/thirteen37/Poptalk.git
cd Poptalk
scripts/install.zsh        # builds, signs, installs to /Applications and launches
```

On first launch, grant **Microphone**, **Accessibility** (to read and insert text) and **Screen Recording** (only for the OCR fallback). The menu-bar icon shows what's missing. Models download on first use (the language model is about 2.8 GB).

## Settings

- **General:** input device, launch at login, version.
- **Context:** which context sources are read, plus opt-in local usage history (for training better models; off by default, wiped with one button).
- **Models:** provider (MLX, LM Studio, Apple), the model for each role, and load status.
- **Permissions:** live status of each permission.
- **Vocabulary:** saved terms. PopTalk offers to remember a correction; it never saves one silently. Imports from FluidVoice.

## Development

```sh
swift build
swift test                                   # PoptalkCore unit tests (Swift Testing)
zsh training/bench.zsh mlx-community/gemma-4-e2b-it-4bit   # benchmark: dictation, edits, speech, held-out set
```

- `Sources/PoptalkCore`: prompts, pipeline, policies (pure, tested).
- `Sources/PoptalkSpeech`: ASR and boosting.
- `Sources/PoptalkMLX`: in-process models.
- `Sources/Poptalk`: the menu-bar app.
- `bench/`: benchmark cases and committed results.
- `training/`: synthetic data generation and LoRA training (`mlx_lm.lora`, run with `uv`); see `training/make_data.zsh` and `training/lora.yaml`.

## License

MIT, see [LICENSE](LICENSE). The bundled fine-tune adapter is a Gemma 4 derivative under Apache 2.0, see [adapters/gemma-4-e2b-poptalk-v3](adapters/gemma-4-e2b-poptalk-v3/README.md). Speech models are downloaded at runtime under their own licenses.
