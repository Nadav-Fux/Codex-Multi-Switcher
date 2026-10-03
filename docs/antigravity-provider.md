# Antigravity quota provider

The provider runs the installed Antigravity CLI's read-only `-p /usage --output-format json` command to fetch current quotas. The current local CLI is v1.2.12. The official changelog documents `/usage` in print mode as a read-only command that returns without starting an agent turn or spending quota. The reader requires CLI v1.2.11 or newer before invoking `/usage`, uses a bounded process timeout and stdout limit, and discards stderr. It accepts data only when the JSON result reports success, `command.name=usage`, and zero turns.

The structured response groups models that share quota, then reports each bucket's ID, title, window, remaining fraction, and reset time. The provider preserves those values and labels as returned. Gemini groups are separated from other named model groups. It does not infer percentages, absolute quota totals, reset dates, or per-model quotas that Antigravity did not provide.

The CLI response does not include an account identifier. To bind an observation to the active sign-in, the reader reads only the known local Antigravity CLI OAuth file's ID token, derives a pseudonymous SHA-256 key from its issuer and subject claims, and checks that key again after the command. Token contents, email, and other claims are not returned or logged. If the identity is unavailable or changes during refresh, the provider returns an error instead of quota data.

References:

- [CLI headless mode](https://www.antigravity.google/docs/cli/headless)
- [CLI model quotas (`/usage`)](https://www.antigravity.google/docs/cli/commands/usage)
- [Antigravity CLI changelog](https://www.antigravity.google/changelog?tab=cli)

The menu bar and provider header use the Antigravity app mark on a transparent background. The display asset was derived from the black-background logo in the installed Antigravity IDE bundle; only its background was removed. Google/Antigravity branding identifies the quota source and does not imply affiliation.

## Reset countdown colors

Across Codex, Claude Code, Antigravity, and GLM, fresh future refill times are jade in the last hour, amber from one to five hours, and muted rose from five to 24 hours. Longer windows, expired/unknown times, and stale observations are neutral. These colors describe proximity to the reported refill; they do not claim the quota has already reset. Banked reset card expiry dates keep their separate expiry semantics.
