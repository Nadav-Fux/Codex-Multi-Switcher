# Repository Guidelines

## Project structure

- `Sources/CodexProfileCore/`: profile, auth, Codex CLI discovery, and shared services.
- `Sources/CodexMultiSwitcherApp/`: macOS menu bar application.
- `Sources/CodexProfileCLI/`: command line helper.
- `Tests/`: Swift unit tests and isolated integration tests.
- `Scripts/`: build, packaging, and release tools.

## Development

```sh
make test
make check
```

Use `CODEX_PROFILE_HOME` or `CODEX_PROFILE_TEST_HOME` for isolated runs. Tests must use fake executables and file-backed vaults; never point tests at a user's real Keychain or Codex home.

## Safety and compatibility

- Preserve user data under `~/.codex/` and `~/.codex-multi-switcher/`.
- Resolve Codex Desktop's CLI from `Contents/Resources/codex-cli/codex-package.json`; keep the legacy `Contents/Resources/codex` fallback.
- Do not modify files inside `ChatGPT.app` or `Codex.app`.
- Keep the app bundle identifier `com.codexmultiswitcher.app` and the Keychain access-group suffix `com.codexmultiswitcher.app.auth-v2` in sync with the packaging scripts.
- Keep upstream MIT and third-party notices intact.
- Never commit credentials, auth files, logs, provisioning profiles, or signing keys.

## Versioning

Keep the marketing version synchronized in `version.env`, `Sources/CodexMultiSwitcherApp/AppInfo.swift`, and `Sources/CodexProfileCLI/CodexProfileCLI.swift`.
