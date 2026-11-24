# gemma-4-e2b-poptalk-v6

A LoRA adapter (rank 16, last 16 layers) for [`mlx-community/gemma-4-e2b-it-4bit`](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit), trained with `mlx_lm.lora` on about 14,000 synthetic PopTalk requests (dictation cleanup and voice edits; v6: v4's families plus self-corrections, a pool matched to real use, varied inserts and screen-name fixes, 5,388 iterations). PopTalk applies it as LoRA layers on the base model at load, unfused: fusing it into the 4-bit weights rounds most of it away. To rebuild it, see `training/` (`make_data_v6.zsh`, `lora-v6.yaml`).

**License:** this adapter is a derivative of Google's Gemma 4 E2B, which is released under the Apache License 2.0. The adapter is distributed under the same terms. Gemma is a trademark of Google LLC; this project is not affiliated with or endorsed by Google.
