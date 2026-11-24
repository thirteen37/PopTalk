# gemma-4-e2b-poptalk-v4

A LoRA adapter (rank 16, last 16 layers) for [`mlx-community/gemma-4-e2b-it-4bit`](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit), trained with `mlx_lm.lora` on about 8,450 synthetic PopTalk requests (v4: adds terminal and coding-agent dictations, identifiers, prose that must not become a list, kept sentence openers; 3,244 iterations) (dictation cleanup and voice edits). PopTalk fuses it into the base model in memory at load. To rebuild it, see `training/`.

**License:** this adapter is a derivative of Google's Gemma 4 E2B, which is released under the Apache License 2.0. The adapter is distributed under the same terms. Gemma is a trademark of Google LLC; this project is not affiliated with or endorsed by Google.
