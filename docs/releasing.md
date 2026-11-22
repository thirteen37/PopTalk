# Releasing

Pushing a `v*` tag runs `.github/workflows/release.yml` (#90): it builds and signs `PopTalk.app` (`scripts/build-app.zsh`), packages it into a DMG and has Apple notarize it (`scripts/make-dmg.zsh`), then creates a GitHub release with the DMG attached and auto-generated notes.

## Cut a release

```sh
git tag v0.2.0 && git push --tags
```

The tag (without the `v`) becomes `CFBundleShortVersionString`; the commit count is `CFBundleVersion`. Running the workflow by hand on a tag releases that tag; on a branch it only uploads the DMG as a workflow artifact.

Locally, `scripts/build-app.zsh && scripts/make-dmg.zsh` makes `build/PopTalk-<version>.dmg`. It is notarized only if the `NOTARY_*` variables below are set.

## Repository secrets

Settings → Secrets and variables → Actions:

| Secret | What it is | How to produce it |
|---|---|---|
| `DEVELOPER_ID_P12_BASE64` | Developer ID Application certificate and its private key | Keychain Access → My Certificates → right-click "Developer ID Application: …" → Export → `.p12` with a password, then `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | The `.p12` export password | The password you chose above |
| `NOTARY_KEY_ID` | App Store Connect API key ID | App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → generate a key with the Developer role; the Key ID is in the list |
| `NOTARY_ISSUER_ID` | API issuer ID (a UUID) | Shown above the Team Keys list |
| `NOTARY_KEY` | The key's `.p8` file contents | Download `AuthKey_<id>.p8` (only possible once), then `pbcopy < AuthKey_<id>.p8` |

Use a Team key: notarytool needs the issuer ID, which individual keys don't have.
