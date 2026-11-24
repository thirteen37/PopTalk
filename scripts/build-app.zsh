#!/usr/bin/env zsh
# Build PopTalk, bundle it into build/PopTalk.app and sign it with your Apple Developer certificate.
# Version (PoptalkVersion, shown in the app): POPTALK_VERSION, else the v* tag on HEAD (v0.2.0 -> 0.2.0), else the
# latest reachable v* tag plus -dev (0.2.0-dev), else 0.0.0-dev. CFBundleShortVersionString drops the -dev suffix.
set -euo pipefail
cd "${0:A:h}/.."

identity=${POPTALK_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
  ids=$(security find-identity -v -p codesigning)
  identity=$(print -r -- $ids | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
  [[ -z $identity ]] && identity=$(print -r -- $ids | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)
fi
if [[ -z $identity ]]; then
  cat >&2 <<'MSG'
No code-signing certificate found. One-time setup (no Xcode needed):
  1. Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority
     → "Saved to disk".
  2. developer.apple.com → Certificates → + → "Apple Development" (or "Developer ID Application")
     → upload the CSR → download the .cer.
  3. Double-click the .cer to install it, then rerun this script.
Or set POPTALK_SIGN_IDENTITY to an identity name (use "-" for ad-hoc; permissions then reset on every build).
MSG
  exit 1
fi

swift build -c release
app=build/PopTalk.app
rm -rf -- $app
mkdir -p $app/Contents/MacOS
cp .build/release/Poptalk $app/Contents/MacOS/
# No SwiftPM resource bundles: Bundle.module would look at the app root (which codesign rejects), and the
# others built (FluidAudio's LuxTtsG2pResources for TTS, swift-transformers' Hub fallback tokenizer configs for
# gpt2/t5, swift-crypto's privacy manifest) are unused.
# Except MLX's Metal shaders: mlx-swift searches every loaded bundle's resources, so Contents/Resources works.
mkdir -p $app/Contents/Resources
cp -R .build/release/mlx-swift_Cmlx.bundle $app/Contents/Resources/
# Icons are pre-rendered and committed (regenerate: assets/icon/render.py). Assets.car holds the Liquid Glass
# icon (CFBundleIconName, macOS 26+); AppIcon.icns is the CFBundleIconFile fallback.
cp assets/icon/AppIcon.icns assets/icon/Assets.car assets/icon/MenuBar*.png $app/Contents/Resources/
version=${POPTALK_VERSION:-}
if [[ -z $version ]]; then
  if tag=$(git describe --tags --match 'v*' --exact-match 2>/dev/null); then version=${tag#v}
  elif tag=$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null); then version=${tag#v}-dev
  else version=0.0.0-dev
  fi
fi
# Build number: commit count (monotonic, as macOS expects); commit: short hash, -dirty with uncommitted changes.
build=$(git rev-list --count HEAD)
commit=$(git rev-parse --short HEAD)
[[ -n $(git status --porcelain) ]] && commit+=-dirty
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.lyx.poptalk</string>
    <key>CFBundleName</key><string>PopTalk</string>
    <key>CFBundleDisplayName</key><string>PopTalk</string>
    <key>CFBundleExecutable</key><string>Poptalk</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${version%%-*}</string>
    <key>PoptalkVersion</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>PoptalkCommit</key><string>$commit</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>PopTalk listens while you hold the hotkey to transcribe your speech.</string>
</dict>
</plist>
PLIST

# Notarization needs a secure timestamp; skip it otherwise (it needs the network and slows local builds).
timestamp=()
[[ $identity == "Developer ID Application:"* ]] && timestamp=(--timestamp)
codesign --force --sign "$identity" --options runtime $timestamp --entitlements scripts/Poptalk.entitlements $app
print "Signed $app ($version, build $build) with: $identity"
