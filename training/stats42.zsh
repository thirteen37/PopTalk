#!/usr/bin/env zsh
# Summarizes a training/bench42.zsh run: median/p90 over all runs and over each case's first run only (runs 2–3
# repeat the prompt, so the cache reuses nearly all of it), footprint, mlx-swift-lm's prompt/generation time totals
# from the timing log, and run-by-run output identity, cache off vs on.
#   zsh training/stats42.zsh [dir]   (default training/out/42/run)
# "prefill" is what the library times as prompt processing; with the cache, a suffix of 512 tokens or fewer is
# evaluated in the first generation step, so it lands in "gen" instead.
D=${1:-training/out/42/run}
q='def pct(p): sort | .[((p * length) | ceil) - 1];
   def med: sort | if length % 2 == 1 then .[length/2|floor] else (.[length/2 - 1] + .[length/2]) / 2 end;
   def r: . * 100 | round / 100;
   [.cases[].runs[].seconds] as $a | [.cases[].runs[0].seconds] as $f
   | "all med \($a|med|r) p90 \($a|pct(0.9)|r) | run1 med \($f|med|r) p90 \($f|pct(0.9)|r) | footprint \(.provider.footprintMBAfterRun) MB"'
timing() {
  [[ -f $1 ]] || return
  awk '/ prompt [0-9]+ tok / { for (i = 1; i <= NF; i++) { if ($i == "prompt") { p += $(i + 3) } if ($i == "gen") { n += $(i + 1); g += $(i + 3) } } }
       END { if (n) printf " | prefill %.1fs gen %.1fs %.1f ms/tok", p, g, 1000 * g / n }' $1
}
for d in $D/*-cache0; do
  b=${d%-cache0}
  a0=$(ls $d/*.json) a1=$(ls $b-cache1/*.json 2>/dev/null) || continue
  print "${b:t}  off: $(jq -r $q $a0)$(timing $d/timing.log)"
  print "${b:t}  on:  $(jq -r $q $a1)$(timing $b-cache1/timing.log)"
  print "  $(.build/release/PoptalkBench --compare $a0 $a1 | rg outputs)"
done
