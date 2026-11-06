# Changelog

## Unreleased

- Heal Codex profiles whose saved sign-in went stale after Codex refreshed the same login. On a 401 / `token_expired` / `refresh_token_reused` (and before a banked reset when the profile's own token has expired), the app adopts a newer, still-valid copy of the same account from `~/.codex/auth.json` or another profile (same `account_id` and same user), backs up the replaced copy under `backups/auth-heal/`, and retries once. Tokens the switcher rotates are written back to `~/.codex/auth.json` when it still holds the consumed chain. When no valid copy exists, a plain "re-login needed" message replaces the raw backend error.
- Prefer fresh Claude Code bridge observations, persist account-bound polling waits across relaunches, and back off repeated quota API rate limits. Clearly mark historical menu-bar values with `~` and show the next refresh time.
- Read Antigravity's full Gemini and partner-model quota groups from the running IDE's local quota service; label missing Gemini data in the CLI-helper fallback.
- Add visible Remove Profile actions to Codex settings and preserve the selected profile through confirmation dismissal. Active profiles remain protected.
- Keep the native Claude credential read-only. Delegate expired sign-in renewal to Claude Code so the usage helper cannot replace its Keychain partition list and cause recurring password prompts.
- Added Codex CLI entrypoint discovery from `codex-package.json` for current ChatGPT app bundles.
- Retained legacy Codex Desktop CLI path support.
- Isolated this project's configuration and development auth storage under `~/.codex-multi-switcher/`.
