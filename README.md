# Token Coffee

Token Coffee is a compact macOS menu bar app for keeping a Mac awake and keeping Codex usage visible at a glance.

It covers one narrow workflow:

- `Off`, `Mac awake`, and `Screen on` power modes.
- Closed-lid sleep prevention whenever an awake mode is active.
- A compact menu panel with weekly Codex usage, renewal time, 5h usage, and a 7-day forecast graph.
- Local usage history sampled every 60 seconds so forecasts can account for bursty work patterns instead of only extending the latest short-term slope.
- Optional CloudKit sync for quota samples, so signed builds can merge usage history across Macs through the user's private iCloud database.

## Install

Download the latest zip from:

```text
https://github.com/pardeike/TokenCoffee/releases/latest/download/TokenCoffee.zip
```

Unzip it, move `Token Coffee.app` to `/Applications`, and open it.

The release build is ad-hoc signed but not notarized. If macOS blocks the first launch, either build it locally from source or use Finder's context menu and choose `Open`.

## Requirements

- Apple Silicon Mac
- macOS 15.0 or newer
- ChatGPT account with Codex access

Token Coffee signs in with ChatGPT device-code login and reads Codex usage with a native HTTPS client. It does not require the Codex CLI.

For local builds you also need:

- Xcode 17 or newer
- XcodeGen 2.42 or newer

With Homebrew:

```sh
brew install xcodegen
```

## Use

Click the cup icon in the menu bar.

- `Off` releases Token Coffee power assertions and restores closed-lid sleep behavior.
- `Mac awake` keeps the Mac awake and allows the display to sleep.
- `Screen on` keeps both the Mac and display awake. The popup menu can turn screen blackout off or apply it after 1, 2, 5, 10, or 60 idle minutes. Any keyboard or mouse input removes the blackout immediately.

When either awake mode is active, closing the lid should not put the Mac to sleep.

The graph shows complete fixed 24-hour bands anchored to the first local midnight before the seven-day quota window. The usable window starts with a light band and then alternates at each 24-hour boundary. Orange activity markers use equal OKLab distance from the light or dark band beneath them, keeping their perceived contrast balanced while preserving the day pattern. The portions before that window and after the renewal deadline are shaded near-black, and the red 100% guide is limited to the usable window. Yellow is the current forecast, red is the over-limit portion, and the red vertical bar is the renew deadline.

The footer shows whether quota history is local-only, syncing, synced through iCloud, paused by CloudKit rate limiting, or temporarily unavailable.

## Build

### Signed normal app

```sh
Scripts/build.sh          # signed build, signature/entitlement verification, real Keychain checks
Scripts/test.sh           # full signed tests and build verification
Scripts/build.sh --run    # tests, signed build, one-time data transfer, launch normal app
Scripts/package-release.sh # same signed workflow, local dist/TokenCoffee.zip
```

The canonical workflow always uses Xcode-managed signing and provisioning for
`com.pardeike.TokenCoffee`, with team `W65292CD8T` by default. There is no unsigned
or ad-hoc fallback. Every build verifies the signed application identifier and
sandbox, then runs disposable create/read/update/delete checks in the actual app's
Keychain. Full logs go to `.build/logs/`; only complete success prints `ok`.

The development build is `.build/Normal/Build/Products/Release/Token Coffee.app`.
It uses the real app identity and container. CloudKit defaults to Development,
with separate development/production change-token files. Production publishing is
not part of these commands. The installed App Store bundle is not overwritten.

### Accounts and predictors

Normal startup now uses the adaptive multi-account dashboard and the existing real
power and screen-blackout controls. The fixed-size Settings window contains
Accounts and Predictors. Add, rename, relink, refresh or remove accounts there.
Predictors select an account value, custom name and colour; drag the list to reorder.
Adding/removing predictors re-evaluates the dashboard layout without shrinking a
valid user-selected size. Window geometry persists across restarts.

Claude supplies independently selectable 5h, General and model-specific limits.
Model names come from the provider response. Known values persist independently
of fresh readings and configured predictors, so expired authentication does not
erase the choices. Missing short-window readings use `--`, not zero.

Claude uses its own browser authorization with a PKCE challenge and a secure
`code#state` field, following the [independent grant pattern](https://github.com/ipangdz/claudexbar/blob/main/docs/AUTH.md).
Only profile access is requested. Codex uses native device-code authorization.
Credentials stay in provider/account-specific Keychain entries. Only the app
renews its own grants. Relinking verifies identity before replacing credentials.
Failed cleanup stays queued without preventing unrelated account operations.

The first `--run` can transfer the retained prototype's account metadata,
predictors, known values, layout and scoped history. It never copies private CLI
directories or credentials and never modifies the prototype container. Imported
accounts require sign-in; the real app's former Codex login can be adopted when
its identity matches. Existing normal-app data is not replaced. Removing an account
keeps its predictors and history; removing a predictor never removes its account.

The original Codex account retains its legacy quota history and sync path. Other
account/value pairs have independent CloudKit zones keyed by provider identity and
scope. No credentials are stored in CloudKit.

### Retained prototype

Prototype source, artifacts and data are retained until the normal app is accepted.
**Do not launch the prototype.** Former prototype launch arguments are rejected.
Historical design and experiment notes are retained in
[Scripts/AccountProbe/README.md](Scripts/AccountProbe/README.md).
The old build workflow is archived there for recovery, not routine execution.

`CURRENT_PROJECT_VERSION` remains `0` locally; Xcode Cloud assigns release build
numbers. These local commands do not upload, publish or release the app.

## Runtime Files

Token Coffee stores quota samples in:

```text
~/Library/Application Support/TokenCoffee/quota-samples.jsonl
```

CloudKit-capable builds incrementally merge this file with private iCloud records of type `QuotaSample` in a per-user custom zone named `QuotaSamples`. Builds upgraded from earlier versions also scan the legacy default-zone `QuotaSample` records in small batches so existing synced history remains visible while stale legacy records are culled.

Raw quota samples are retained for 14 days, with a hard cap of 25,000 samples after dedupe. CloudKit-capable builds delete remote `QuotaSample` records only after incremental sync has caught up, and only when the samples are older than the seven-day graph window.

Closed-lid wake support installs this LaunchAgent fail-safe:

```text
~/Library/LaunchAgents/com.pardeike.TokenCoffee.clamshell-failsafe.plist
```

The fail-safe restores normal clamshell sleep behavior if Token Coffee exits unexpectedly while closed-lid wake is enabled.

## Uninstall

Quit Token Coffee, remove the app, then remove its runtime files:

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.pardeike.TokenCoffee.clamshell-failsafe.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.pardeike.TokenCoffee.clamshell-failsafe.plist"
rm -rf "$HOME/Library/Application Support/TokenCoffee"
```

## Privacy

Token Coffee does not send usage data to its own service. It signs in directly with ChatGPT/Codex to read your account limits, stores authentication tokens in Keychain, stores quota samples locally, optionally syncs those samples through your private CloudKit database when the app is signed with iCloud entitlements, and uses macOS power APIs for the awake modes.
