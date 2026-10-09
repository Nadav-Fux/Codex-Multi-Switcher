# Antigravity quota provider

The provider calls Google's read-only quota-summary API through the user's existing `antigravity-usage` statusline helper connection. It does not launch `agy`, read or write Keychain items, open a browser, or execute statusline hooks. The earlier temporary-HOME CLI reader was removed: an expired CLI token could make its credential-store subprocess look for a nonexistent default Keychain.

The reader requires the helper's active account to match the email in Antigravity's locally cached CLI ID token. It reads only the matching helper account's owner-owned, regular, private (`0600`) token file. Google userinfo must independently verify that the bearer belongs to the same subject and verified email. The active account, local CLI identity, and credential fingerprint are checked again before publishing any quota. Token contents and emails are not returned or logged.

An expired helper token is renewed only through the helper's explicit `accounts refresh <matching-account>` operation. This refresh does not log in or switch accounts; it updates that account's existing OAuth token and last-used metadata. Its process has null input/output, a minimal environment with the real home directory, and a five-second timeout with process-group cleanup. If the existing helper connection is absent or revoked, the provider reports unavailable data rather than opening a login flow.

HTTPS uses an ephemeral session, no cookies or redirects, bounded timeouts, and a one-MiB response limit. The quota endpoint is `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`, with an empty JSON request body and the helper bearer. The `antigravity` User-Agent is required by the currently observed service behavior. Both bare and `response`-wrapped quota summaries are supported.

The response has Gemini and other-model buckets (`gemini-5h`, `gemini-weekly`, `3p-5h`, `3p-weekly`). Remaining fractions and reset times come directly from those buckets; percentages are unit conversions. Unknown buckets are ignored, malformed known buckets reject the observation, and an empty result is unavailable. No model request is made, and absolute quota totals or missing reset dates are not inferred.

This integration depends on the existing helper installation and the observed Google quota API schema. The helper account must continue matching the CLI account, which can differ from the IDE account.

References:

- [CLI headless mode](https://www.antigravity.google/docs/cli/headless)
- [CLI model quotas (`/usage`)](https://www.antigravity.google/docs/cli/commands/usage)
- [Antigravity CLI changelog](https://www.antigravity.google/changelog?tab=cli)

The menu bar and provider header use the Antigravity app mark on a transparent background. The display asset was derived from the black-background logo in the installed Antigravity IDE bundle; only its background was removed. Google/Antigravity branding identifies the quota source and does not imply affiliation.

## Reset countdown colors

Across Codex, Claude Code, Antigravity, and GLM, fresh future refill times are jade in the last hour, amber from one to five hours, and muted rose from five to 24 hours. Longer windows, expired/unknown times, and stale observations are neutral. These colors describe proximity to the reported refill; they do not claim the quota has already reset. Banked reset card expiry dates keep their separate expiry semantics.
