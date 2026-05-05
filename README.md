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
- Codex CLI installed and signed in

Token Coffee reads Codex limits through:

```sh
codex app-server --listen stdio://
```

It looks for `codex` in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, and then `PATH`.

For local builds you also need:

- Xcode 17 or newer
- XcodeGen 2.42 or newer

With Homebrew:

```sh
brew install xcodegen
brew install --cask codex
```

## Use

Click the cup icon in the menu bar.

- `Off` releases Token Coffee power assertions and restores closed-lid sleep behavior.
- `Mac awake` keeps the Mac awake and allows the display to sleep.
- `Screen on` keeps both the Mac and display awake.

When either awake mode is active, closing the lid should not put the Mac to sleep.

The graph always shows the full 7-day weekly window. Yellow is the current forecast, red is the over-limit portion, and the red vertical bar is the renew deadline.

The footer shows whether quota history is local-only, syncing, synced through iCloud, or temporarily unavailable.

## Build

```sh
Scripts/build.sh
```

Unsigned local builds keep CloudKit disabled and use only the local JSONL history. To build with iCloud entitlements, provide a development team:

```sh
TOKENCOFFEE_DEVELOPMENT_TEAM=TEAMID Scripts/build.sh
```

Optional overrides:

```sh
TOKENCOFFEE_BUNDLE_ID=com.example.TokenCoffee TOKENCOFFEE_CLOUDKIT_ENVIRONMENT=Development Scripts/build.sh
```

## Test

```sh
Scripts/test.sh
```

## Package

```sh
Scripts/package-release.sh
```

The packaged app is written to `dist/TokenCoffee.zip`.

By default the release package is built unsigned and then ad-hoc signed, which keeps CloudKit disabled. For a CloudKit-capable release package, build with an Apple developer team so Xcode signs the app with the `iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)` container entitlement:

```sh
TOKENCOFFEE_DEVELOPMENT_TEAM=TEAMID Scripts/package-release.sh
```

## Runtime Files

Token Coffee stores quota samples in:

```text
~/Library/Application Support/TokenCoffee/quota-samples.jsonl
```

CloudKit-capable builds merge this file with private iCloud records of type `QuotaSample`.

Raw quota samples are retained for 14 days, with a hard cap of 25,000 samples after dedupe. CloudKit-capable builds apply the same retention policy remotely and delete stale `QuotaSample` records during sync.

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

Token Coffee does not send usage data to its own service. It runs the local Codex CLI to read your account limits, stores quota samples locally, optionally syncs those samples through your private CloudKit database when the app is signed with iCloud entitlements, and uses macOS power APIs for the awake modes.
