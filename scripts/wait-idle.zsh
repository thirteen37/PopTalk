#!/usr/bin/env zsh
# Waits while PopTalk records or processes (its busy marker holds the pid of a live PopTalk); exits 1 after a
# timeout. A marker whose pid isn't a running PopTalk is stale (a crash) and ignored.
# Usage: wait-idle.zsh [marker] [process name] [timeout s]  (defaults: the app's marker, Poptalk, 120)
set -uo pipefail
marker=${1:-$HOME/Library/Caches/io.lyx.poptalk/busy} name=${2:-Poptalk} timeout=${3:-120}

busy() {
  local pid
  pid=$(<$marker) 2>/dev/null || return 1
  [[ $pid == <-> && $(ps -p $pid -o comm= 2>/dev/null) == (*/|)$name ]]
}

integer i
while busy; do
  (( i++ == 0 )) && print "Waiting for PopTalk to finish…"
  if (( i > timeout * 2 )); then
    print -u2 "PopTalk still busy after ${timeout}s; not quitting it. Rerun when it's idle."
    exit 1
  fi
  sleep 0.5
done
