# GLM / Z.ai provider

The GLM section presents two separate read-only sources. It does not claim that the two sources belong to the same account.

## API-key quota and monitor

Open **Settings → GLM / Z.ai**, enter a personal Z.ai Coding Plan API key, and choose **Save Key & Refresh**. The key is stored in this app's dedicated Keychain item. The key provides the subscription quota view and the monitor's 24-hour token, model-call, and tool-call counts. The monitor labels its request window in UTC. Its `nextRenewTime` value is shown as a raw **Next plan date**; the app does not interpret it as an expiry or a guarantee of automatic renewal.

The API key is sent over HTTPS only to Z.ai's read-only quota and monitor endpoints. The provider disables cookies and the HTTP cache, bounds response sizes, rejects redirects, and does not retain raw response bodies after parsing. Missing fields stay unavailable. A missing usage value is never shown as zero or as 100% available. Changing or removing the saved key clears the prior snapshot and prevents an in-flight response from being applied to the new key.

## Current local ZCode account benefits

**Settings → GLM / Z.ai → Read reset cards and Start Plan / Flash balances from local ZCode sign-in** controls this optional read. Benefits refresh about once a minute; model/tool monitor enrichment refreshes about every two minutes.

The benefits section reads reset-card status and Start Plan balance data from the current local ZCode sign-in. It reads `~/.zcode/v2/credentials.json` only when that file is a regular file owned by the current user and has no group or other permissions. Selection metadata in `setting.json` must be owner-owned and not writable by others; its normal read permissions are allowed. The app accepts the published `enc:v1` credential format and decrypts its AES-256-GCM values in process, in memory, for the read. It does not send opaque encrypted strings. Decrypted credentials are used only in the authorization headers required by ZCode's reset-status and Start Plan balance GET endpoints; they are not stored in this app's Keychain, logged, or included in usage snapshots.

This is a read-only local credential use. The app does not sign in, refresh tokens, write or mutate ZCode credentials, mark reset history read, request new reset cards, or redeem a reset card. The reset view lists each issued five-hour and weekly card's individual expiry, separately from quota refill times. Start Plan balances retain each bucket's model/name, reported remaining units, separately available units, total units when supplied, reserved units when supplied, and bucket expiry. A bucket percentage is shown only when its reported remaining and total units form a valid ratio. Unknown totals remain unavailable.

The API-key monitor and local ZCode benefits may represent different accounts. The UI names their sources separately and does not join them by assumption. Campaign data is shown only when the source supplies its published campaign fields. No official usage-coefficient or boost-window endpoint was found in the reviewed ZCode source, so campaign discounts or rewards are not multiplied into quota and no purchased boost window is promised. Windows support for reading the local ZCode credential is deferred.

## Authorized API-key import

A trusted retrieval tool can pipe a key to the installed app executable using `--import-glm-key-from-stdin`. The key is read from standard input, never from a command-line argument, and saved directly to the same app-specific Keychain item used by Settings. The importer prints only a fixed success or failure message, accepts at most 8 KB, and does not save an intermediate file. Restart the app or refresh GLM after importing.

Use the executable from the installed app bundle so its Keychain service matches that app. Do not paste the key into a shell command, a chat message, or the repository. The app does not retain Cloudflare access credentials or continuously connect to KV.

## Official sources

- [ZCode credential cipher implementation (`enc:v1`, AES-256-GCM)](https://github.com/zai-org/ZCode/blob/main/packages/services/src/credential/providers/credentialCipherProvider.ts)
- [ZCode CLI credential cipher implementation](https://github.com/zai-org/ZCode/blob/main/apps/zcode-cli/packages/adapters/src/auth/credential-cipher.ts)
- [ZCode reset-status schema and read-only endpoint](https://github.com/zai-org/ZCode/blob/main/packages/services/src/usage-stats/providers/bigmodelUsageQuotaProvider.ts)
- [ZCode shared reset-card types](https://github.com/zai-org/ZCode/blob/main/packages/shared/src/coding-plan-reset.ts)
- [ZCode Start Plan balance response schema](https://github.com/zai-org/ZCode/blob/main/packages/services/src/model-provider/zaiStartPlanBilling.ts)
- [ZCode campaign discount and reward fields](https://github.com/zai-org/ZCode/blob/main/packages/shared/src/coding-plan-subscription.ts)
- [ZCode Usage Stats documentation](https://zcode.z.ai/en/docs/usage-stats)
- [ZCode Connect Models & Plans](https://zcode.z.ai/en/docs/configuration)
- [ZCode FAQ: credential storage and account authorization](https://zcode.z.ai/en/docs/qa)
- [Z.ai Usage Query Plugin](https://docs.z.ai/devpack/extension/usage-query-plugin)
- [Official quota query script](https://github.com/zai-org/zai-coding-plugins/blob/main/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs)

The UI links separately to the [published GLM-5.3-Flash campaign](https://docs.z.ai/devpack/notice/event-glm-5.3-flash). Its announced dates and client rules are explanatory, not authenticated personal entitlements; the app does not apply a multiplier to displayed quotas.

If ZCode rejects the Start Plan balance request, the section shows the rejection and leaves the personal balance unavailable. It does not substitute an old on-screen balance or interpret the error as zero tokens. Other successful account reads, including reset-card inventory, remain visible.

The legacy monitor can return aggregate and per-model totals that disagree. The UI keeps the reported figures separate and labels a mismatch; it does not rewrite either value to make the counts agree.
