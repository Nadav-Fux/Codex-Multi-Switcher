# Releasing

A release requires an Apple Developer signing identity and provisioning profile for `com.codexmultiswitcher.app`, plus Sparkle EdDSA signing keys. This repository does not contain release credentials.

Set these values in the local shell or a protected CI secret store:

- `CODEX_PROFILE_TEAM_ID`: your 10-character Apple Team ID.
- `APP_IDENTITY`: your Developer ID Application identity.
- `CODEX_PROFILE_APP_PROVISIONING_PROFILE`: app provisioning profile path when required.
- `SPARKLE_ED_PUBLIC_KEY` and the private signing key expected by the release script.

Then follow the checks in `Scripts/release_app.sh`. Verify the app and helper signatures, entitlements, update feed, and release assets before publishing. Do not reuse another developer's signing identity, team ID, update feed, or release artifacts.
