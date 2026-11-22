#!/usr/bin/env zsh
# Build and sign PopTalk (scripts/build-app.zsh), install to /Applications, relaunch.
set -euo pipefail
cd "${0:A:h}/.."

zsh scripts/build-app.zsh
app=build/PopTalk.app

# Never quit it mid-dictation; the last check is right before the quit, leaving only a sub-ms window.
zsh scripts/wait-idle.zsh || exit 1
pkill -x Poptalk || true
# The bundle was Poptalk.app before #65.
rm -rf -- /Applications/Poptalk.app /Applications/PopTalk.app
cp -R $app /Applications/
open /Applications/PopTalk.app
print "Installed /Applications/PopTalk.app. On first run grant Microphone, Accessibility and Screen Recording (menu bar ⟶ PopTalk icon shows status)."
