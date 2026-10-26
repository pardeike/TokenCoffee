# Token Coffee

Token Coffee is a compact macOS menu bar app for keeping a Mac awake and keeping Codex and Claude usage visible at a glance.

It covers one narrow workflow:

- `Off`, `Mac awake`, and `Screen on` power modes.
- Optional native sleep support for enhanced display controls and closed-lid operation.
- A compact menu panel with weekly Codex usage, renewal time, 5h usage, and a 7-day forecast graph.
- Local usage history sampled every 60 seconds so forecasts can account for bursty work patterns instead of only extending the latest short-term slope.
- Optional CloudKit sync for quota samples, so signed builds can merge usage history across Macs through the user's private iCloud database.

## Install

Get [Token Coffee on the Mac App Store](https://apps.apple.com/app/id6766599809).

Local development and ZIP packaging use the signed workflow below.
For enhanced display and lid controls, install the optional [Sleep Support component](#sleep-support).

## Requirements

- Apple Silicon Mac
- macOS 15.0 or newer
- A ChatGPT account with Codex access or a supported Claude account for usage monitoring

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
- `Mac awake` keeps the Mac awake. With Sleep Support installed, its Display sleep delay turns displays off independently of the macOS timeout.
- `Screen on` prevents idle display sleep. Its optional black cover hides idle screens. Sleep Support also dims supported backlights.

Enhanced closed-lid operation on laptops requires Sleep Support and the limited administrator setup described below.

The graph shows complete fixed 24-hour bands anchored to the first local midnight before the seven-day quota window. The usable window starts with a light band and then alternates at each 24-hour boundary. Orange activity markers use equal OKLab distance from the light or dark band beneath them, keeping their perceived contrast balanced while preserving the day pattern. The portions before that window and after the renewal deadline are shaded near-black, and the red 100% guide is limited to the usable window. Yellow is the current forecast, red is the over-limit portion, and the red vertical bar is the renew deadline.

The Accounts editor and chart tooltip show history sync status. Chart colours and footers remain reserved for allowance, pace and stale-reading warnings.

## Build

### Signed normal app

```sh
Scripts/build.sh          # signed build, signature/entitlement verification, real Keychain checks
Scripts/test.sh           # full signed tests and build verification
Scripts/build.sh --run    # tests, signed build, one-time data transfer, launch normal app
Scripts/package-release.sh # same signed workflow, local dist/TokenCoffee.zip
Scripts/package-release.sh --sleep-support # signed tests and Developer ID-signed support disk image
Scripts/package-release.sh --sleep-support --notarize # also notarize, staple and verify Gatekeeper
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
valid user-selected size. Window geometry persists across restarts, independently for each monitor. Clicking a monitor's menu icon brings the dashboard there; new monitors start at the top right.

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
Pending authorization pauses only the account being reconnected, and expires after
30 minutes. Other accounts continue polling. Saved readings and chart history appear
immediately after restart, marked stale until refreshed. Unexpected quota resets
require repeated confirmation before changing the displayed value or synced history.

The first `--run` can transfer the retained prototype's account metadata,
predictors, known values, layout and scoped history. It never copies private CLI
directories or credentials and never modifies the prototype container. Imported
accounts require sign-in; the real app's former Codex login can be adopted when
its identity matches. Existing normal-app data is not replaced. Removing an account
keeps its predictors and history; removing a predictor never removes its account.

Every account/value pair has an independent CloudKit zone keyed by provider identity
and scope, including the original Codex account. The same login uses the same zone
on different Macs. Unpartitioned legacy history cannot be attributed reliably and
is preserved rather than silently assigned to an account. The original Codex account
still mirrors its scoped history to the local legacy file for existing consumers,
archiving that file once before replacement. No credentials are stored in CloudKit.

Read-only consumers such as BrrainzTools use `UsageHistoryContract.swift` for
five-second reset matching and Claude organization/account UUID normalization.
BrrainzTools vendors that file and its tests, so it builds independently; its
`TOKENCOFFEE_SOURCE_DIRECTORY=/path/to/TokenCoffee Scripts/verify.sh` workflow
checks parity when updating both projects. A matching account and limit are required
before matching reset timestamps. The history JSONL schema is unchanged.

### Retained prototype

Prototype source, artifacts and data are retained until the normal app is accepted.
**Do not launch the prototype.** Former prototype launch arguments are rejected.
Historical design and experiment notes are retained in
[Scripts/AccountProbe/README.md](Scripts/AccountProbe/README.md).
The old build workflow is archived there for recovery, not routine execution.

`CURRENT_PROJECT_VERSION` remains `0` locally; Xcode Cloud assigns release build
numbers. These local commands do not upload, publish or release the app.

## Runtime Files

The signed app stores account-partitioned quota samples under:

```text
~/Library/Containers/com.pardeike.TokenCoffee/Data/Library/Application Support/TokenCoffee/multi-account/diagram-history/<account UUID>/<scope hash>.jsonl
```

CloudKit-capable builds incrementally merge each account/scope history with private
iCloud records of type `QuotaSample` in its own `Account_<identity-and-scope hash>`
zone. The normal dashboard no longer reads or cleans up the unowned `QuotaSamples`
or default zones. Their records and old checkpoint files remain untouched.

When CloudKit reports more changes, the app fetches consecutive pages sequentially, including empty and deletion-only pages. Each catch-up burst starts at most 100 requests and stops starting new requests after 20 seconds; an in-flight request can take longer. Unfinished catch-up continues on the next quota refresh, normally about a minute later, while caught-up clients retain the normal 15-minute sync interval (or the existing two-minute cleanup interval). CloudKit retry-after delays take precedence over both schedules. A non-advancing cursor produces a sync failure and a five-minute backoff instead of an endless request loop.

Each `multi-account/cloud-state/<environment>/<identity-and-scope hash>.json` stores
the change cursor and a recoverable history cache together in an atomic checkpoint
before uploads or cleanup. A subsequent upload failure or interrupted JSONL write
cannot lose the downloaded history. If a page within a burst fails, that burst
resumes from the previous checkpoint after any required backoff.

The original Codex account's local compatibility mirror remains at
`TokenCoffee/quota-samples.jsonl` inside the same sandbox Application Support folder.
Its previous contents are preserved in `multi-account/legacy-unattributed-history.jsonl`.

Raw quota samples are retained for 14 days, with a hard cap of 25,000 samples after dedupe. CloudKit-capable builds delete remote `QuotaSample` records only after incremental sync has caught up, and only when the samples are older than the seven-day graph window.

## Sleep support

Sleep Support is an optional signed native component. The App Store app keeps
basic awake controls, black covers and account monitoring available without it.
Independent display-sleep timing and backlight dimming require this component.

1. Install Token Coffee from the App Store and open it once.
2. Keep the laptop lid open. Choose Quit Token Coffee from the app's menu.
3. Download and open [TokenCoffeeSleepSupport.dmg](https://github.com/pardeike/TokenCoffee/releases/latest/download/TokenCoffeeSleepSupport.dmg).
4. Run this command in Terminal:

```sh
/bin/bash "/Volumes/Token Coffee Sleep Support/Scripts/install-sleep-support.sh"
```

The installer runs as your Mac user. It installs the signed agent, checks that
foreign applications cannot use it, and registers it with macOS. It requires
neither Xcode nor Python. Open Token Coffee again after installation.

On laptops, enhanced support also needs permission for the two fixed power
commands below. If your Mac does not already allow them, an administrator can
open a dedicated sudoers file:

```sh
sudo visudo -f /private/etc/sudoers.d/tokencoffee
```

Add this line, replacing `YOUR_SHORT_USERNAME` with the output of `id -un`:

```text
YOUR_SHORT_USERNAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

The installer never adds or changes administrator permissions. Desktop Macs do
not need this permission. The app's Sleep support menu opens these instructions.

With support installed, Mac awake keeps the Mac working and turns displays off after TokenCoffee's
Display sleep delay. Closing the lid turns the built-in display off immediately.
This works independently of the macOS display-sleep timeout.

Screen on keeps the desktop active. Closing the lid dims the built-in backlight
without covering the desktop. The optional Screen blackout delay dims supported
displays and places a black cover over idle screens. The next input uncovers them
and restores their previous brightness and app focus. Set Screen blackout to Off
when a whole-display capture must remain unobstructed.

Display sleep and Screen blackout have separate delays. Both default to one minute.
Off releases the awake overrides and restores brightness changes that TokenCoffee
still owns. It preserves brightness changes made by the user or another app.
The display controller uses one-shot idle deadlines and system notifications.
It stops scheduling checks while the display sleeps or a cover is visible.

Closed-lid wake support on Apple silicon uses a signed native user agent. On laptops, it applies
`pmset -a disablesleep 1` while an awake mode is active. It restores normal sleep
when the mode ends or Token Coffee exits. The agent waits for these events without
a polling timer. If another app already disabled sleep, Token Coffee preserves
that setting.

The app connects through a private socket inside its sandbox container. Both
ends verify the other's signing identity. The agent accepts one active session.
It does not use the macOS script runner or show a ScriptMonitor gear.

Quit Token Coffee, then install the support files from outside the app sandbox:

```sh
Scripts/install-sleep-support.sh
```

On laptops, the agent needs existing permission to run exactly
`sudo -n /usr/bin/pmset -a disablesleep 0` and `sudo -n /usr/bin/pmset -a disablesleep 1`.
The installer does not change administrator permissions. If setup or permission
is missing, Token Coffee reports that closed-lid protection is unavailable.
Ordinary awake mode continues to work.
Desktop Macs use ordinary power assertions and need no privileged sleep setting.

Deploy and verify the signed app and support files on the MacBook Air:

```sh
Scripts/build.sh --deploy mba.home.arpa
```

The installation registers the agent with macOS:

```text
~/Library/LaunchAgents/com.pardeike.TokenCoffee.sleep-agent.plist
```

The agent restores owned changes when the app disconnects or exits. macOS
restarts the agent after a crash. Before accepting another session, the agent
clears an interrupted sleep override and restores owned brightness.
The installer replaces the former login recovery task and keeps its helper for rollback.

## Uninstall

Quit Token Coffee, remove the app, then remove its runtime files:

```sh
launchctl bootout "gui/$(id -u)/com.pardeike.TokenCoffee.sleep-agent" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.pardeike.TokenCoffee.sleep-agent.plist"
rm -f "$HOME/Library/Containers/com.pardeike.TokenCoffee/Data/.sleep-agent.sock"
rm -rf "$HOME/Library/Application Support/TokenCoffee/Sleep Protection"
```

## Privacy

Token Coffee does not send usage data to its own service. It signs in directly with ChatGPT/Codex or Claude to read your account limits, stores authentication tokens in Keychain, stores quota samples locally, optionally syncs those samples through your private CloudKit database when the app is signed with iCloud entitlements, and uses macOS power APIs for the awake modes.
