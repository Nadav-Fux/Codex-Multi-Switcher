# GLM Coding Plan quota provider

## Connect a key

Open **Settings → GLM / Z.ai**, enter your **personal Z.ai Coding Plan API key** in the SecureField, then choose **Save Key & Refresh**. You must enter the key yourself; the app does not obtain or add it for you. The key is stored in this app's dedicated Keychain item. Use **Remove Saved Key** to delete it.

The app does not read ZCode's account credential or OAuth token. ZCode documents `~/.zcode/v2/credentials.json` as encrypted per device, and documents account authorization and API-key mode as separate connection methods. A one-time read-only request using a locally stored ZCode value was rejected; that response does not establish that the credential expired or that the stored value was a usable API key. The app does not infer expiry or try undocumented authentication routes.

The saved key is sent only to Z.ai's read-only Coding Plan quota endpoint over HTTPS. The provider does not cache the key or the raw response.

The quota response may include a 5-hour token pool, weekly pool, and monthly MCP/tool pool. Each bucket is shown only when the response reports it with a recognized type and valid percentage; a weekly bucket appears only when returned. Reset times are shown only when the response includes a parseable reset time. Missing quota fields remain unknown.

ZCode's Usage Stats documentation describes quota reset cards for the 5-hour and weekly pools. This provider only reads the quota endpoint: it does not query, redeem, or display reset-card availability. Use ZCode to inspect or redeem reset cards.

ZCode sign-in alone does not enable this provider. Save a personal Coding Plan API key in Settings to read quota.

References:

- [ZCode Usage Stats](https://zcode.z.ai/en/docs/usage-stats)
- [ZCode Connect Models & Plans](https://zcode.z.ai/en/docs/configuration)
- [ZCode FAQ: credential storage and account authorization](https://zcode.z.ai/en/docs/qa)
- [Z.ai Usage Query Plugin](https://docs.z.ai/devpack/extension/usage-query-plugin)
- [Official quota query script](https://github.com/zai-org/zai-coding-plugins/blob/main/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs)
