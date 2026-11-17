# Changelog

## Unreleased

- Show Claude limit resets (full, weekly, 5-hour and Fable) in Claude settings, read from the same usage block Claude Code's `/limit-reset` uses. Display only: the app never spends a reset.
- Redesign Claude settings to match the other providers: one status banner (Connected / one-time approval / sign in) with the single action it needs, usage, then new-session controls; directory, reconnect and the statusline recorder move under Advanced. Separate Claude accounts get their usage recorder installed automatically after sign-in unless it was removed on purpose.
- Note: the stable signature keeps the Claude grant across app rebuilds while the usage helper is unchanged. A change to `CodexProfileCore` or the helper produces a new helper binary, which macOS asks to approve once.
- Sign the installed Local build with a stable identity (`Codex Multi Switcher Local Signing`, or `APP_IDENTITY`) so Keychain "Always Allow" grants survive rebuilds; packaging fails with setup instructions instead of silently falling back to ad-hoc. `APP_IDENTITY=-` opts into ad-hoc explicitly.
- Store the Z.ai Coding Plan key in a mode-600 file under the switcher home instead of the Keychain; a key saved by an older build migrates once when its Keychain item is readable. A failing legacy Keychain read is logged once, not every 30 seconds.
- Notify once when macOS blocks silent Claude usage access instead of leaving the menu bar on "?", and remove block flags left by earlier helper builds.
- Read Antigravity quotas from the standalone Antigravity app's language server (`/Applications/Antigravity.app/Contents/Resources/bin/language_server`) as well as the older IDE bundle, so Gemini quota is shown instead of the CLI-helper fallback.
- Heal Codex profiles whose saved sign-in went stale after Codex refreshed the same login. On a 401 / `token_expired` / `refresh_token_reused` (and before a banked reset when the profile's own token has expired), the app adopts a newer, still-valid copy of the same account from `~/.codex/auth.json` or another profile (same `account_id` and same user), backs up the replaced copy under `backups/auth-heal/`, and retries once. Tokens the switcher rotates are written back to `~/.codex/auth.json` when it still holds the consumed chain. When no valid copy exists, a plain "re-login needed" message replaces the raw backend error.
- Prefer fresh Claude Code bridge observations, persist account-bound polling waits across relaunches, and back off repeated quota API rate limits. Clearly mark historical menu-bar values with `~` and show the next refresh time.
- Read Antigravity's full Gemini and partner-model quota groups from the running IDE's local quota service; label missing Gemini data in the CLI-helper fallback.
- Add visible Remove Profile actions to Codex settings and preserve the selected profile through confirmation dismissal. Active profiles remain protected.
- Keep the native Claude credential read-only. Delegate expired sign-in renewal to Claude Code so the usage helper cannot replace its Keychain partition list and cause recurring password prompts.
- Added Codex CLI entrypoint discovery from `codex-package.json` for current ChatGPT app bundles.
- Retained legacy Codex Desktop CLI path support.
- Isolated this project's configuration and development auth storage under `~/.codex-multi-switcher/`.
