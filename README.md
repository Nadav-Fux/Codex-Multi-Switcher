# Codex Multi Switcher

A macOS menu bar app and CLI for managing multiple Codex profiles. Switching profiles saves the outgoing auth state, activates the selected profile, and relaunches Codex Desktop.

## Compatibility fix

Current ChatGPT builds package Codex CLI under `Contents/Resources/codex-cli/` and describe the executable in `codex-package.json`. This project reads that entrypoint, validates that it stays inside the packaged CLI directory, and keeps support for the legacy `Contents/Resources/codex` layout. It does not patch or write into `ChatGPT.app`.

Run `codex-profile doctor` for a compatibility report covering the installed desktop version, package metadata and selected CLI path, CLI executability, app code-signature verification, and profile storage status. **Settings → General → Copy Debug Info** also includes the bundle version, package layout, and selected CLI path.

## Build and run

Requires macOS 14+ and a compatible Swift toolchain and macOS SDK. Full Xcode is recommended. On this machine, the Command Line Tools' macOS 27 SDK lacks the SwiftUI macro plugin, while selecting the installed macOS 26.5 SDK builds the app successfully.

For a double-clickable development preview with its own profile home:

```sh
CODEX_PROFILE_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  bash Scripts/package_preview.sh
open ".build/Codex Multi Switcher Preview.app"
```

Omit `CODEX_PROFILE_SDK` when the default SDK works. The preview shows the selected profile's reported quota windows in the menu bar, stores profiles under `~/Library/Application Support/Codex Multi Switcher Preview`, and opens Settings on launch. **General → Scan Original App** copies profile names only; select each profile and click **Set Up** for a separate sign-in, or use **+** to add a profile. It is locally signed for development, not a notarized release or a production migration. Launch at Login and desktop account switching are unavailable. The script refuses to overwrite an existing output; pass a different output path to create another build.

For personal use without an Apple Developer account, build a locally signed app:

```sh
CODEX_PROFILE_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  bash Scripts/package_local.sh "$HOME/Applications/Codex Multi Switcher Local.app"
open "$HOME/Applications/Codex Multi Switcher Local.app"
```

The local app uses profiles already set up in Preview, but points account switching at the running user's `~/.codex`. Its saved sign-ins remain in the Preview home's private file vault (directory mode 0700, files mode 0600). It is ad hoc signed for this Mac, not Developer ID signed or notarized. Switching asks for confirmation and may quit and relaunch Codex Desktop. Keep the original app available until a switch succeeds. Launch at Login is managed from Settings → General without an Apple Developer account. The menu bar initially shows remaining quota: green at 50% or more, yellow from 20% through 49%, and red below 20%; when both windows are reported, the top number is the five-hour window and the bottom number is the weekly window. Weekly-only plans show one number. The script refuses to overwrite an existing output.

When the Codex app-server supplies banked reset inventory, each profile card shows the available count and up to four supplied expirations with countdowns. The **Settings → Codex** tab shows every supplied expiry in the Mac's local time zone. Codex may report only the count or cap the detail list; the UI marks dates it could not obtain and never assumes a fixed number of resets. Banked resets are separate from automatic five-hour and weekly usage resets.

## Quota display and banked reset schedules

For plans that report both windows, the larger menu bar numbers are labelled **5h** and **w**. Small **5h: Left/Used** and **week: Left/Used** buttons in the menu independently choose remaining percentage or usage towards 100%. The same controls appear in the Codex quota cards. Each choice persists across launches; colors always describe how much quota remains. Interior colors use a subdued jade, amber, and rose palette.

Quota periods are identified by their reported duration, not their position in
the API response. Weekly-only plans show one weekly percentage with no five-hour row.
An optional days/hours countdown shows time until the reported weekly quota reset
(for example `95% w · 6d20h`); toggle it in **Settings → General**. This is a
quota reset time, not a subscription billing date. Missing windows never mean 100% available.
For the active desktop account, a matching, unexpired live sign-in can supply
current usage through an isolated read-only query. The query receives a dummy
refresh token and cannot update the live sign-in or saved credentials. A rejected
saved sign-in remains blocked for activation until re-authenticated.
Cached or failed-refresh observations are gray and explicitly labelled. Menu bar
colors use lighter rose, yellow and jade with an outline and shadow for contrast.

In **Settings → Codex**, each reset with a supplied ID shows its grant date, expiry, and remaining time. **Use now** confirms a manual redemption. **Schedule automatic reset** lets you explicitly enable a date/time or 1–720 hours before expiry. No schedules are created automatically. A schedule whose chosen trigger has already passed is labelled **Enable and run now**. Times use the Mac's local time zone.

Scheduling is local: this app must be running, the Mac awake, and the network available. The app checks every minute and after launch/wake; it does not wake a sleeping Mac or ask the server to schedule a future reset. A schedule is bound to one exact reset and account. The request ID is journaled before sending and reused when an uncertain request is retried. Cancelling stops future attempts and cannot undo a request already accepted by Codex. If a scheduled attempt reports nothing to reset, the credit remains and the schedule retries after 15 minutes; a manual no-op stops immediately.

Using a full reset restarts eligible five-hour and weekly usage windows and changes the weekly reset date. Codex supplies the inventory and may cap detail rows; the app does not invent missing resets or expirations. See the [official reset explanation](https://help.openai.com/en/articles/20001498-how-banked-codex-resets-work) and [app-server protocol](https://learn.chatgpt.com/docs/app-server).


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

## Claude Code accounts

**Settings → Claude Code** manages an independent group of Claude accounts. The
existing `~/.claude` directory appears automatically. Use **+**, rename the new
profile, and **Sign In…** to sign in through the official Claude CLI in a separate
configuration directory. **Choose Account** selects the account for new managed
sessions; **Open New Session** opens a new Terminal session with that profile.
Existing Claude sessions keep their original account. Codex switching and reset
schedules are independent of these actions.

After sign-in, **Install Bridge for This Account** connects the native Claude
status line to the switcher. It backs up settings, preserves the existing
statusline command's output and options, and can be removed using **Remove
Bridge**. Each account's bridge stores only quota observations and hashed identity
metadata in its own directory. It reads no tokens or transcripts and makes no
usage API requests. The existing `claude-2x-statusline` installation can remain in
place. New managed profiles get a simple quota status line without copying the
default profile's settings or credentials.

**Settings → General → Show in menu bar** chooses Codex only, Claude Code only,
or both. Both indicators are drawn in one menu bar item and stay adjacent.
Hold **Command (⌘)** and drag the item beside Wi-Fi or the battery to place it;
macOS manages its location. A high-contrast monochrome terminal symbol identifies Codex; an orange
asterisk identifies Claude beside their quota numbers. The Claude indicator shows five-hour and weekly quota for the
selected Claude account. Each period has independent **Left/Used** controls.
Missing individual windows show a dash; when no current Claude windows exist,
the indicator shows its symbol and `?`. Settings show cached observations with
their source and timestamp. A legacy statusline
cache cannot identify its account and is always labelled unverified. For the
default Claude account, the app can read current quota through Claude’s OAuth
profile and usage endpoints. It reads the existing credential without a Keychain
prompt, verifies the server account against the CLI identity, and never renews
or writes credentials. This path is unavailable when macOS denies the read.
Separate managed accounts use native `rate_limits` statusline data, normally
after a model response. **Refresh** checks saved observations, authentication
status, and eligible default-account usage. Project
settings that override `statusLine` must also use the bridge for that session.
No Claude banked-reset or automatic-reset action is implemented.

Profile metadata is private and stored beside the switcher's Codex metadata in
`claude/profiles.json`; managed config directories are under `claude/profiles/`.
Removing a profile removes its registry entry only and preserves its credentials,
history and files. On macOS, `CLAUDE_CONFIG_DIR` selects an independent Claude
Keychain entry. The managed launchers scrub API credential and provider overrides
before running the CLI. See the official [statusline data contract](https://code.claude.com/docs/en/statusline)
and [credential management](https://code.claude.com/docs/en/authentication#credential-management).

## Storage and network use

Profile configuration and the development auth vault live under `~/.codex-multi-switcher/` (or under the selected `CODEX_PROFILE_HOME`). The active Codex credential remains at `~/.codex/auth.json` while a switch is in progress. Signed app releases use the Data Protection Keychain for saved profiles.

To bring over profiles from the original app, open **Settings → General → Profile Import → Scan Original App**. The importer reads `~/.codex-switcher`, previews the profiles, keeps that source untouched, and saves a private undo record under `~/.codex-multi-switcher/backups/`. Existing credentials are never overwritten. Credentials available only to the original signing team's Data Protection Keychain cannot be transferred and will need a new sign-in.

Credential renewal sends the stored refresh token to `https://auth.openai.com/oauth/token`, the endpoint Codex itself uses. The source project does not include telemetry or cloud sync.

## Tests

```sh
make test
make check
```

The integration suite uses isolated homes and fake Codex executables. `Tests/run-banked-reset-tests.sh` exercises the real RPC client against a fake server, including exact-credit retries, account checks, and rotated-token handling. `Tests/run-feature-tests.sh` runs scheduler and credential persistence unit checks independently of XCTest. `Tests/run-app-feature-tests.sh` checks the actual app scheduler against a fake server, including journal-before-send behavior and relaunch after an uncertain response. `Tests/run-claude-tests.sh` uses private temporary directories and a fake Claude CLI to check registry isolation, default Keychain selection, native usage identity, statusline backup/restore, and managed launchers. `python3 Tests/ClaudeStatuslineBridgeTests.py` checks the token-free Python bridge and previous-command preservation. `Tests/run-usage-normalization-tests.sh` checks weekly-only and swapped-window responses. `Tests/run-active-usage-tests.sh` checks matching live account reads, discarded child credential writes, retained saved login rejection, and account changes during a fetch. Set `CODEX_PROFILE_SDK` if needed.

When no current Claude windows have been observed, its badge shows its glyph and `?`
instead of ambiguous percentage rows. The tooltip explains how to obtain usage.

The desktop-layout regression fixture covers the package metadata layout as well as legacy executable discovery.

## Signing and releases

Unsigned development builds use the file-backed vault. A signed release needs your own Apple Developer Team ID, signing identity, provisioning profile, notarization credentials, and Sparkle signing keys. The repository's manual GitHub Actions workflow uses protected repository secrets; never commit certificates, profiles, or signing keys. See [release instructions](docs/RELEASING.md).

## License

MIT. The upstream copyright notice remains in [LICENSE](LICENSE), as required by the license. Third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
