# TokenHelper

TokenHelper is a compact macOS menu bar app for keeping a Mac awake and keeping Codex usage visible at a glance.

It covers one narrow workflow:

- `Off`, `Mac awake`, and `Screen on` power modes.
- Closed-lid sleep prevention whenever an awake mode is active.
- A compact menu panel with weekly Codex usage, renewal time, 5h usage, and a 7-day forecast graph.
- Local usage history sampled every 60 seconds so forecasts can account for bursty work patterns instead of only extending the latest short-term slope.

## Install

Download the latest zip from:

```text
https://github.com/pardeike/TokenHelper/releases/latest/download/TokenHelper.zip
```

Unzip it, move `TokenHelper.app` to `/Applications`, and open it.

The release build is ad-hoc signed but not notarized. If macOS blocks the first launch, either build it locally from source or use Finder's context menu and choose `Open`.

## Requirements

- Apple Silicon Mac
- macOS 26.0 or newer
- Codex CLI installed and signed in

TokenHelper reads Codex limits through:

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

- `Off` releases TokenHelper power assertions and restores closed-lid sleep behavior.
- `Mac awake` keeps the Mac awake and allows the display to sleep.
- `Screen on` keeps both the Mac and display awake.

When either awake mode is active, closing the lid should not put the Mac to sleep.

The graph always shows the full 7-day weekly window. Yellow is the current forecast, red is the over-limit portion, and the red vertical bar is the renew deadline.

## Build

```sh
Scripts/build.sh
```

## Test

```sh
Scripts/test.sh
```

## Package

```sh
Scripts/package-release.sh
```

The packaged app is written to `dist/TokenHelper.zip`.

## Runtime Files

TokenHelper stores quota samples in:

```text
~/Library/Application Support/TokenHelper/quota-samples.jsonl
```

Closed-lid wake support installs this LaunchAgent fail-safe:

```text
~/Library/LaunchAgents/com.pardeike.TokenHelper.clamshell-failsafe.plist
```

The fail-safe restores normal clamshell sleep behavior if TokenHelper exits unexpectedly while closed-lid wake is enabled.

## Uninstall

Quit TokenHelper, remove the app, then remove its runtime files:

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.pardeike.TokenHelper.clamshell-failsafe.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.pardeike.TokenHelper.clamshell-failsafe.plist"
rm -rf "$HOME/Library/Application Support/TokenHelper"
```

## Privacy

TokenHelper does not send usage data to its own service. It runs the local Codex CLI to read your account limits, stores quota samples locally, and uses macOS power APIs for the awake modes.
