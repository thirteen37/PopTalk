#!/usr/bin/env zsh
# Summarizes a training/bench42.zsh run: median/p90 over all runs and over each case's first run only (runs 2–3
# repeat the prompt, so the cache reuses nearly all of it), and run-by-run output identity, cache off vs on.
#   zsh training/stats42.zsh [dir]   (default training/out/42/run)
D=${1:-training/out/42/run}
q='def pct(p): sort | .[((p * length) | ceil) - 1];
   def med: sort | if length % 2 == 1 then .[length/2|floor] else (.[length/2 - 1] + .[length/2]) / 2 end;
   def r: . * 100 | round / 100;
   [.cases[].runs[].seconds] as $a | [.cases[].runs[0].seconds] as $f
   | "all med \($a|med|r) p90 \($a|pct(0.9)|r) | run1 med \($f|med|r) p90 \($f|pct(0.9)|r) | footprint \(.provider.footprintMBAfterRun) MB"'
for d in $D/*-cache0; do
  b=${d%-cache0}
  a0=$(ls $d/*.json) a1=$(ls $b-cache1/*.json 2>/dev/null) || continue
  print "${b:t}  off: $(jq -r $q $a0)"
  print "${b:t}  on:  $(jq -r $q $a1)"
  print "  $(.build/release/PoptalkBench --compare $a0 $a1 | rg outputs)"
done
