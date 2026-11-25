# Real-voice speech bench

The speech bench (`s-*` cases in `bench/cases.jsonl`) normally hears macOS text-to-speech voices. You can record your own voice for the same cases (#99). Recordings and their results stay on your Mac: `bench/audio-real/` and `bench/results-real/` are gitignored.

## Record

Run this from the repo root in your own terminal (Terminal, iTerm, Ghostty, …), not from inside an agent sandbox:

```sh
swift build -c release && .build/release/PoptalkBench --record
```

For each case it shows the screen context or vocabulary the case has, then the line to say. Press Enter to start, read the line, and press Enter to stop. Then press Enter to keep the take, `r` to retake, `s` to skip or `q` to quit. Read naturally: hesitations and small rewordings are fine, and they are what the bench is for.

- It records the system default input (System Settings → Sound → Input), not the microphone chosen in PopTalk's settings.
- The first run asks for microphone access for your terminal app. If you denied it before, turn it on in System Settings → Privacy & Security → Microphone and restart the terminal. A take that hears no speech says so.
- The 50 cases take about 20 minutes. Each kept take is written as `bench/audio-real/<case id>.wav` (16 kHz mono) right away, so you can stop at any point and rerun the same command to carry on. Cases already recorded are skipped. `--redo` records them again, and `--filter 's-fix-*'` limits the run to some cases.

## Bench

```sh
.build/release/PoptalkBench --provider mlx --cleanup-model adapters/gemma-4-e2b-poptalk-v6 --runs 1 --filter 's-*' --audio-dir bench/audio-real
```

Recognition uses the app's default speech model, Parakeet TDT v2; add `--speech-model v3` (or another id from Settings → Models) to compare. Cases with a recording use it and the rest use the synthesized voice. The result JSON records the speech model in `provider.speechModel`, each case's `audio` source (`real`, `file` or `speak`) and the count in `provider.realAudio`, and the speech table prints real and synthetic rows separately. Results go to `bench/results-real/`. `training/bench.zsh <model> --audio-dir bench/audio-real` passes the flag to every set; only the speech set uses it.

Real-voice results and `PoptalkBench --compare` output contain what you said, ad-libs included. Commit or post only counts (WER, term recall, pass counts), never the result files or transcripts.
