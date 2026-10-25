# Changelog

## Unreleased

- Keep the native Claude credential read-only. Delegate expired sign-in renewal to Claude Code so the usage helper cannot replace its Keychain partition list and cause recurring password prompts.
- Added Codex CLI entrypoint discovery from `codex-package.json` for current ChatGPT app bundles.
- Retained legacy Codex Desktop CLI path support.
- Isolated this project's configuration and development auth storage under `~/.codex-multi-switcher/`.
