#!/usr/bin/env zsh
# Build and sign PopTalk (scripts/build-app.zsh), install to /Applications, relaunch.
set -euo pipefail
cd "${0:A:h}/.."

zsh scripts/build-app.zsh
app=build/PopTalk.app

# Never quit it mid-dictation; the last check is right before the quit, leaving only a sub-ms window.
zsh scripts/wait-idle.zsh || exit 1
pkill -x Poptalk || true
# pkill returns at once; open while the old process still exits sends it a reopen and fails with -600 (#107).
gone() { repeat $1 { pgrep -xq Poptalk || return 0; sleep 0.1 }; return 1 }
gone 100 || { pkill -9 -x Poptalk || true; gone 20 } || { print -u2 "Poptalk did not quit"; exit 1 }
# The bundle was Poptalk.app before #65.
rm -rf -- /Applications/Poptalk.app /Applications/PopTalk.app
cp -R $app /Applications/
# -n: LaunchServices can keep the dead app registered after its pid is gone, and a plain open then sends it a
# reopen that fails with -600 (#107). A new instance skips the lookup; the wait above makes it the only one.
open -n /Applications/PopTalk.app
print "Installed /Applications/PopTalk.app. On first run grant Microphone, Accessibility and Screen Recording (menu bar ⟶ PopTalk icon shows status)."
