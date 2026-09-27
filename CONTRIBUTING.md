# Contributing

1. Build and run the relevant tests with `make test`.
2. Use an isolated `CODEX_PROFILE_HOME` for local app runs.
3. Keep changes focused and update user documentation when behavior changes.
4. Do not include auth data, local logs, signing material, or machine-specific paths.
5. Preserve the MIT license and third-party notices.

Changes to profile switching or Codex Desktop discovery should include an isolated regression fixture. Do not test against a real account or the user's installed app bundle.
