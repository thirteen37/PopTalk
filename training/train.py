#!/usr/bin/env -S uv run --project training
"""LoRA fine-tune of Gemma 4 E2B (4-bit) on out/data with mlx-tune, loss on the assistant turn only (#21).
  uv run --project training training/train.py [--iters N] [--out training/out/adapters]
Fuse afterwards with fuse.zsh."""
import argparse
import json
import time
from pathlib import Path

from mlx_tune import FastLanguageModel, SFTConfig, SFTTrainer, train_on_responses_only

p = argparse.ArgumentParser()
p.add_argument("--model", default="mlx-community/gemma-4-e2b-it-4bit")
p.add_argument("--data", default="training/out/data")
p.add_argument("--out", default="training/out/adapters")
p.add_argument("--iters", type=int, default=1500)
p.add_argument("--batch", type=int, default=4)
p.add_argument("--lr", type=float, default=1e-4)
p.add_argument("--rank", type=int, default=16)
p.add_argument("--max-seq", type=int, default=3072)
a = p.parse_args()

load = lambda f: [json.loads(l) for l in Path(a.data, f).read_text().splitlines() if l.strip()]
model, tok = FastLanguageModel.from_pretrained(a.model, max_seq_length=a.max_seq)
model = FastLanguageModel.get_peft_model(model, r=a.rank, lora_alpha=2 * a.rank, target_modules=[
    "q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"])
trainer = SFTTrainer(model=model, tokenizer=tok, train_dataset=load("train.jsonl"), eval_dataset=load("valid.jsonl"),
                     args=SFTConfig(output_dir=a.out, per_device_train_batch_size=a.batch, gradient_accumulation_steps=1,
                                    learning_rate=a.lr, lr_scheduler_type="cosine", warmup_steps=50, max_steps=a.iters,
                                    logging_steps=25, save_steps=250, steps_per_eval=250, val_batches=25,
                                    max_seq_length=a.max_seq, grad_checkpoint=True))
trainer = train_on_responses_only(trainer)
start = time.time()
print(trainer.train())
print(f"train seconds: {time.time() - start:.0f}")
