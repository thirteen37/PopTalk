#!/usr/bin/env zsh
# Package build/PopTalk.app (from scripts/build-app.zsh) into build/PopTalk-<version>.dmg, signed with the app's
# identity. With NOTARY_KEY_ID, NOTARY_ISSUER_ID and NOTARY_KEY (an App Store Connect API key's .p8 contents)
# set, also notarize and staple it (#90).
set -euo pipefail
cd "${0:A:h}/.."

app=build/PopTalk.app
[[ -d $app ]] || { print -u2 "No $app: run scripts/build-app.zsh first."; exit 1 }
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $app/Contents/Info.plist)
dmg=build/PopTalk-$version.dmg
# Sign the DMG with whatever signed the app; an ad-hoc app has no Authority, so its DMG stays unsigned.
identity=$(codesign -dvv $app 2>&1 | sed -n 's/^Authority=//p' | head -1)

stage=$(mktemp -d)
chmod 755 $stage  # mktemp makes it 700, which becomes the volume root
trap 'rm -rf -- $stage' EXIT
cp -R $app $stage/
ln -s /Applications $stage/Applications
rm -f -- $dmg
hdiutil create -volname PopTalk -srcfolder $stage -fs APFS -format UDZO -ov $dmg
[[ -n $identity ]] && codesign --force --sign "$identity" --timestamp $dmg

if [[ -n ${NOTARY_KEY_ID:-} && -n ${NOTARY_ISSUER_ID:-} && -n ${NOTARY_KEY:-} ]]; then
  # Notarizing the DMG covers the app inside (the notary service checks nested code and issues tickets for both),
  # so one submission; the ticket is stapled to the DMG. A copied-out app looks its ticket up online at first launch.
  # ponytail: app itself unstapled; notarize+staple the app before packaging too if offline first launch matters.
  key=$stage/AuthKey_$NOTARY_KEY_ID.p8
  (umask 077; print -r -- $NOTARY_KEY > $key)
  auth=(--key $key --key-id $NOTARY_KEY_ID --issuer $NOTARY_ISSUER_ID)
  result=$(xcrun notarytool submit $dmg $auth --wait --output-format json)
  print -r -- $result
  if [[ $(print -r -- $result | jq -r .status) != Accepted ]]; then
    xcrun notarytool log $(print -r -- $result | jq -r .id) $auth
    exit 1
  fi
  xcrun stapler staple $dmg
  xcrun stapler validate $dmg
  spctl --assess --type open --context context:primary-signature -v $dmg
else
  print "No NOTARY_KEY_ID/NOTARY_ISSUER_ID/NOTARY_KEY: skipped notarization."
fi
print "Made $dmg"
