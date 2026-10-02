# Releasing

The repository includes a manually dispatched signed-release workflow at `.github/workflows/release.yml`. It builds and signs the app, notarizes the DMG, creates the Sparkle feed, and publishes the DMG, checksum, Homebrew cask, and `appcast.xml` to a GitHub Release. It does not contain release credentials and cannot publish until the repository owner configures them.

Configure these GitHub Actions secrets using credentials owned by the maintainer of this repository:

- `CODEX_PROFILE_TEAM_ID`: the 10-character Apple Developer Team ID.
- `APP_IDENTITY`: the exact Developer ID Application identity shown by `security find-identity -p codesigning -v`.
- `APPLE_DEVELOPER_ID_P12_BASE64` and `APPLE_DEVELOPER_ID_P12_PASSWORD`: the base64-encoded Developer ID certificate export and its export password.
- `CODEX_PROFILE_APP_PROVISIONING_PROFILE_BASE64`: the base64-encoded profile authorizing `com.codexmultiswitcher.app` and its Keychain group.
- `APPLE_ID`, `APPLE_TEAM_ID`, and `APP_SPECIFIC_PASSWORD`: credentials for Apple notarization. `APPLE_TEAM_ID` should match `CODEX_PROFILE_TEAM_ID`.
- `SPARKLE_ED_PUBLIC_KEY` and `SPARKLE_ED_PRIVATE_KEY`: the matching Sparkle EdDSA pair. Keep the private key in GitHub Secrets only. Do not rotate a key after users have installed a build that trusts its public half.

To publish, push a version tag that matches `MARKETING_VERSION` in `version.env`, then run **Actions → Signed Release → Run workflow** for that tag. The workflow validates its inputs, refuses an existing release, imports signing material into a temporary macOS keychain, and removes that keychain at the end. Review the resulting release assets and notarization status before announcing the release.

The release feed is served as the `appcast.xml` asset of the latest GitHub Release. The workflow carries forward the prior feed so installed copies can find successive updates. Sparkle's EdDSA private key is passed to `generate_appcast` through standard input in CI, following [Sparkle's guidance for CI signing](https://github.com/sparkle-project/Sparkle/discussions/2308).

For a local release, `Scripts/release_app.sh` still supports an existing macOS Keychain Sparkle key. Keep signing profiles, certificates, notarization passwords, and private update keys out of commits, logs, and issue reports.
