# TokenHelper

TokenHelper is a macOS menu bar app for keeping a Mac awake and keeping Codex usage visible at a glance.

It covers the narrow workflow this app was built for:

- `Off`, `Mac awake`, and `Screen on` power modes.
- Closed-lid sleep prevention whenever an awake mode is active.
- A compact menu panel with weekly Codex usage, renewal time, 5h usage, and a 7-day forecast graph.
- Local usage history sampled every 60 seconds so forecasts can account for bursty work patterns instead of only extending the latest short-term slope.

## Requirements

- Apple Silicon Mac
- macOS 26.0 or newer
- Xcode 17 or newer
- XcodeGen 2.42 or newer

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

## Runtime Notes

TokenHelper stores quota samples in:

```text
~/Library/Application Support/TokenHelper/quota-samples.jsonl
```

Closed-lid wake support installs a LaunchAgent fail-safe so clamshell sleep behavior is restored if the app exits unexpectedly.
