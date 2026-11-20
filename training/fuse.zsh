#!/usr/bin/env zsh
# Fuses the LoRA adapter into the 4-bit base, giving a local MLX dir that MLXProvider loads (#21).
#   training/fuse.zsh [adapters dir] [output dir]
set -euo pipefail
adapters=${1:-training/out/adapters}
dest=${2:-training/out/fused}
uv run --project training mlx_lm.fuse --model mlx-community/gemma-4-e2b-it-4bit --adapter-path $adapters --save-path $dest
du -sh $dest
