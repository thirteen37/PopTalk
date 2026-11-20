#!/usr/bin/env zsh
# Build Poptalk, bundle it, sign it with your Apple Developer certificate, install to /Applications.
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
app=build/Poptalk.app
rm -rf -- $app
mkdir -p $app/Contents/MacOS
cp .build/release/Poptalk $app/Contents/MacOS/
# No SwiftPM resource bundles: Bundle.module would look at the app root (which codesign rejects), and the
# others built (FluidAudio's LuxTtsG2pResources for TTS, swift-transformers' Hub fallback tokenizer configs for
# gpt2/t5, swift-crypto's privacy manifest) are unused.
# Except MLX's Metal shaders: mlx-swift searches every loaded bundle's resources, so Contents/Resources works.
mkdir -p $app/Contents/Resources
cp -R .build/release/mlx-swift_Cmlx.bundle $app/Contents/Resources/
# Icons are pre-rendered and committed (regenerate: assets/icon/render.py build).
cp assets/icon/AppIcon.icns assets/icon/MenuBar*.png $app/Contents/Resources/
# LoRA adapters, fused into their base model at load (#36); relative model ids resolve here.
cp -R adapters $app/Contents/Resources/
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
    <key>CFBundleName</key><string>Poptalk</string>
    <key>CFBundleExecutable</key><string>Poptalk</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>PoptalkCommit</key><string>$commit</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Poptalk listens while you hold the hotkey to transcribe your speech.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$identity" --options runtime --entitlements scripts/Poptalk.entitlements $app
print "Signed with: $identity"

pkill -x Poptalk || true
rm -rf -- /Applications/Poptalk.app
cp -R $app /Applications/
open /Applications/Poptalk.app
print "Installed /Applications/Poptalk.app. On first run grant Microphone, Accessibility and Screen Recording (menu bar ⟶ speech-bubble icon shows status)."
