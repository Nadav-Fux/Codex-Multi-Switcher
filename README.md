# Codex Multi Switcher

A macOS menu bar app and CLI for managing multiple Codex profiles. Switching profiles saves the outgoing auth state, activates the selected profile, and relaunches Codex Desktop.

## Compatibility fix

Current ChatGPT builds package Codex CLI under `Contents/Resources/codex-cli/` and describe the executable in `codex-package.json`. This project reads that entrypoint, validates that it stays inside the packaged CLI directory, and keeps support for the legacy `Contents/Resources/codex` layout. It does not patch or write into `ChatGPT.app`.

## Build and run

Requires macOS 14+ and the full Xcode app. Command Line Tools alone do not include the SwiftUI macro plugins needed by the app target.

```sh
make test
./build.sh "$TMPDIR/codex-multi-switcher-dev"
CODEX_PROFILE_HOME="$HOME/.codex-multi-switcher-dev" \
  "$TMPDIR/codex-multi-switcher-dev"
```

The isolated home keeps development profiles and configuration separate from an installed release. Build output uses a file-backed development vault. Do not point a development build at production profile data.

To build the Swift package without installing it:

```sh
swift build -c release
```

To run the command line helper in a development build, use the built `codex-profile` executable with the same `CODEX_PROFILE_HOME` value.

## Storage and network use

Profile configuration and the development auth vault live under `~/.codex-multi-switcher/` (or under the selected `CODEX_PROFILE_HOME`). The active Codex credential remains at `~/.codex/auth.json` while a switch is in progress. Signed app releases use the Data Protection Keychain for saved profiles.

Credential renewal sends the stored refresh token to `https://auth.openai.com/oauth/token`, the endpoint Codex itself uses. The source project does not include telemetry or cloud sync.

## Tests

```sh
make test
make check
```

The integration suite uses isolated homes and fake Codex executables. The desktop-layout regression fixture covers the package metadata layout as well as legacy executable discovery.

## Signing and releases

Unsigned development builds use the file-backed vault. A signed release needs your own Apple Developer Team ID, signing identity, provisioning profile, and Sparkle signing keys. Configure `CODEX_PROFILE_TEAM_ID` and `APP_IDENTITY` locally; never commit certificates, profiles, or signing keys. See [release instructions](docs/RELEASING.md).

## License

MIT. The upstream copyright notice remains in [LICENSE](LICENSE), as required by the license. Third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
