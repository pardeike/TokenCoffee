# Retained prototype history

Historical record only. Do not execute these launch commands. Use the normal
signed app via Scripts/build.sh; keep the prototype until Andreas confirms it.

### Sandboxed account feasibility probe

Real dashboard integration against the already-linked sandbox accounts:

```sh
Scripts/build.sh --linked-dashboard
```

Uses shared app dashboard code and real account readers, with separate Claude
**5h**, **General** and **Fable** diagrams. The session chart has its own five-hour
history and hourly axis. Accounts manage linked data sources; Predictors is a
separate ordered list of charts. Add a predictor by choosing an account, a value,
a name and a colour. Predictors and Accounts share a fixed 760 × 500 management
window, independent of the dashboard. Select a row to edit its detail; drag rows
to reorder or use the move-up/down controls beneath the list. Unsaved edits are
protected when changing selection, switching sections or closing the window.
Committed additions/removals immediately reflow the dashboard, growing its chosen
arrangement when required by tile minimums and falling back only if the screen
cannot fit that arrangement. Opening settings does not resize the dashboard. Eight colour
choices apply to the title and actual usage line, not warning/forecast colours.
New accounts do not automatically add charts, and removing the last predictor
leaves the dashboard empty across restarts. Model names come from `limits[].scope.model.display_name`.
Scope identity prefers the provider model ID, with a name-based fallback when null.
A name change without an ID starts a separate history instead of guessing a merge.
`is_active: false` does not hide an allowance: the live response marks both weekly
limits false while the exhausted session is true. General includes Fable.

History is local and partitioned by account UUID and scope, never merged into the
installed app's legacy or CloudKit history. Window frame, layout and predictor list
persist. Up to six charts fit on one page; the five-chart overview uses one wide
chart above a 2×2 grid. Additional charts use explicit six-tile pages. Account names
can be edited inline with Save/Cancel, without changing identity, credentials or
history. Predictor names are independent of account names and may omit all suffixes.
Claude defaults to terracotta and Codex to mint. Existing visible charts can be
imported once; subsequent refreshes never add, remove or reorder predictors.
Unavailable values retain their configured tiles instead of shifting other charts.
Missing short-window values display `--`, not a claim that no limit exists. The signed
validation app uses the existing account sandbox identity; it does not move tokens.
Normal startup is unchanged. Power controls and production
CloudKit integration are not enabled in this mode. `--prototype` stays dummy-only.

Accounts now provides **+**, **−**, **Sign In Again**, and **Refresh Usage**. Codex
uses its device-code browser flow. Claude uses an independent browser authorization
with a PKCE challenge, then a secure field for the browser's complete `code#state`.
Only profile access is requested. This follows the app-owned grant pattern documented
in [ClaudexBar authentication](https://github.com/ipangdz/claudexbar/blob/main/docs/AUTH.md)
and the profile-only flow in local BrrainzTools. The provider endpoints are not a
public third-party API contract or evidence of App Store acceptance.

Credentials live in separate provider-scoped Keychain entries. Claude renews only
its own grant, before expiry or once after HTTP 401, persisting the rotated refresh
token before another request. It never rotates the CLI experiment's credential.
Use Sign In Again on that old Claude account to give TokenCoffee its own grant.
Relinking verifies the original provider identity and preserves account UUID, custom
name, predictors, and history. Duplicate accounts are rejected. Pending authorization
stays in memory; staged and retired Keychain entries have a cleanup journal for crash
recovery. Removing an account unlinks it and cleans up its app-owned credential;
the confirmation explicitly preserves predictors and history for reassignment or
separate removal. The older CLI experiment's private credentials are left untouched.

Discovered value names persist on the account, independently of predictors and fresh
readings. Existing account-partitioned history can recover those names after upgrading.
An expired login therefore does not erase the picker choices or invent zero usage.
Offline tests cover grant rotation, HTTP 401/429, identity mismatches, duplicates,
cancellation, credential-write failure, cleanup recovery, and value-name recovery.
Real Claude browser login and long-running renewal through this new app-owned flow
still require user testing; no provider authorization is implied by `ok`.

Run the independent Claude renewal experiment alongside it:

```sh
Scripts/build.sh --account-probe --watch
Scripts/build.sh --account-probe --watch-status
Scripts/build.sh --account-probe --watch-stop
```

The watcher polls every five minutes and delegates near-expiry renewal to the
unchanged official CLI using `/status`. Success requires a changed credential,
advanced expiry, and successful native usage after the original expiry. It stops
polling on success, an attention condition, or its deadline (normally original
expiry plus 30 minutes, at most 24 hours). HTTP 429 backs off 15 minutes. The local
diagnostic terminal entitlement is not evidence of App Store eligibility. Do not
run another CLI against this private profile while the watcher owns renewal.
Reports exclude credentials. This is not installed as a login item/restart service.

Account-management prototype, after linking the private Claude profile once:

```sh
Scripts/build.sh --account-probe --accounts
```

Opens the System Settings-style account list in the same helper-free, Developer ID
signed sandbox app. Details and linking use one window with a clickable Back
button. Account metadata and the window frame persist. Codex linking uses the
existing native device-code flow with a separate prototype Keychain service and
one entry per account. Duplicate allowance identities are rejected. An unfinished
login is cleaned up on cancellation or next startup. The existing private Claude
profile supports native identity and usage reads without credential refresh.
Additional Claude login, relinking, removal, and production dashboard rollout remain
unfinished. `ok` verifies offline checks, signing and sandbox preflight, not a
completed provider sign-in. Usage readings are manual and are not persisted or synced.
Live verification on September 13 passed with two distinct Codex accounts, Pro and
Free, plus the private Claude account. All three returned fresh usage after a signed
rebuild and restart without another login. Multi-Claude and token-refresh rotation
remain unverified; see `MULTI_ACCOUNT_PLAN.md` for the evidence and remaining work.

Native usage, after linking the private Claude profile once:

```sh
Scripts/build.sh --account-probe --native-http
```

Runs focused offline checks, then builds and opens a separate helper-free app
with only App Sandbox and outgoing-network entitlements. Click **Read via HTTP**
to read the exact private-profile Keychain item and request Claude's usage JSON.
It does not launch Claude, use a terminal exception, or copy/refresh credentials.
`ok` confirms the checks, signed build and sandbox preflight; the usage outcome
appears in the window and private `report.json`. Native usage has passed live.

The original official-client login and terminal comparison remain available:

```sh
Scripts/build.sh --account-probe --bundled-client --allow-callback
```

Builds a separate Developer ID signed app with App Sandbox enabled. It copies the
already installed Claude executable into an ignored local probe bundle, verifies
that the copy is byte-identical and retains its original signature, and enables
outgoing networking plus the incoming-network entitlement needed for the login
callback. Nothing is downloaded, installed into Applications, or published.
Production and dummy-layout entitlements are unchanged.

The probe checks private storage, denial of an outside-container control file,
client startup, terminal access and a signed-out private profile. Use **Link Claude
account** in its window, then complete the official browser sign-in. It checks
authentication again in a new child process. Credentials stay with the official
client; probe reports contain no tokens. No normal coding profile is imported.

After a successful login, verify a full app restart and read usage with:

```sh
Scripts/build.sh --account-probe --bundled-client --allow-callback --resume
```

Use **Read usage** in the reopened window. Setup prompts remain interactive;
the probe does not automatically accept trust or consent. It disables built-in
tools, hooks, external MCP configuration and Remote Control auto-start, uses
default permissions, and sends only the `/usage` command.
The private configuration and temporary directory live in the probe's own
container, `com.pardeike.TokenCoffee.AccountProbe`.

For the already-authorized private folder, append `--trusted-probe-defaults` to
the resume command to set theme/onboarding and that exact folder's trust flag.
This is a local diagnostic for Andreas's approved profile, not blanket approval
for future accounts. `--theme-defaults` and `--onboarding-defaults` isolate the
earlier setup steps. The original private configuration is backed up in the
container; no normal coding configuration is edited.

To isolate the terminal-control sandbox denial, use:

```sh
Scripts/build.sh --account-probe --bundled-client --allow-callback --resume --trusted-probe-defaults --terminal-exception
```

This final flag selects a separate diagnostic entitlement file allowing only
`file-ioctl` on `/dev/ttys[0-9]+`. App Sandbox stays enabled and the outside-file
denial check must still pass. Omit the flag to restore the baseline entitlements.
It is not an App Store solution. Apple's [direct-distribution guidance](https://developer.apple.com/forums/thread/776609)
distinguishes temporary exceptions from Mac App Store capabilities.

Omit `--allow-callback` to reproduce the outgoing-only login test. Omit both
options to test direct execution of the installed external Claude client.
Build, signing and preflight logs go to `.build/logs/`. `ok` establishes the
preflight or restart check only. Login and usage outcomes appear in the probe
window and its container's `TokenCoffeeAccountProbe/report.json` file.

This prototype does not establish permission to redistribute Claude, Mac App
Store acceptance, credential renewal, or independent monitoring of two accounts.
The native transport also does not establish provider approval for third-party
authentication; the new-account login flow remains a separate decision.
Current runtime evidence: real Claude login and full app restart passed. Baseline
sandbox entitlements deny raw terminal input. With the diagnostic terminal
exception and explicit Remote Control opt-out, the official client's `/usage`
returned live session and weekly quotas. The extra
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` flag caused the tested usage path to
fail and is not set. Preflight `ok` alone still does not verify a usage reading.

### Multi-account layout prototype

```sh
Scripts/build.sh --prototype
```

Builds, runs the focused prototype checks, signs with the local Developer ID,
and opens the prototype. Full output is saved under `.build/logs/`; success prints
only `ok`. Failures report the step and log path. Set `TOKENCOFFEE_SIGNING_IDENTITY`
to override the signing identity. The local prototype is sandboxed without network
or CloudKit entitlements.
The optimized local app is in `.build/Prototype/Build/Products/Release/`.
Rerunning the command closes only the previous app at that exact prototype path;
the installed application is left running. Launch this build through the command,
which supplies `--prototype` (a normal launch still starts the real application).

The `--prototype` app argument enters an isolated, in-memory UI with four dummy
Codex/Claude accounts and simulated power controls. Its menu changes account count,
activity scenarios, and layout. Drag an edge or corner to see the monochrome layout
preview; release to settle. Click an account for detail and use Back to return.
Window placement is saved under prototype-only preferences. Live authentication,
quota files, CloudKit, and power services are not started in this mode.

The supported layouts are Pocket, Strip, Gallery, Lanes, Overview, and Tall overview.
Gallery and Lanes follow simulated activity and tour secondary accounts when the
pointer is outside the panel. All other layouts keep accounts equally prominent.
The normal launch and `--demo` screenshot mode retain their existing behavior.

Starting sizes in points: Pocket 280×144, Strip 880×144, Gallery 480×272,
Lanes 320×560, Overview 640×480, Tall overview 320×820. These are menu presets,
not resize targets. Usable dragged sizes are preserved, including larger grids
and strips. The preview changes arrangements in real time when tiles become too
small, too tall, or too flat. Full graph tiles require width/height ratios from
1.05 to 5, previews from 1 to 6, and compact readouts from 1 to 12. Pocket tiles
are capped at 110 points tall so growing Pocket can reveal a richer arrangement.
Graph tiles need at least 220×120, previews 120×80, and readouts 120×44 points.
The current arrangement is retained within a small boundary margin. When no
arrangement fits exactly, the nearest valid size within the screen is used.
Text and control sizes stay fixed while graph areas grow.
Each tile type owns its minimum dimensions and aspect range together. Emphasis
selects a tile type; resizing does not silently promote it to a different type
with different constraints. Account order is independent of layout selection.
Overlapping valid ranges prefer the current arrangement, then the closest
starting composition, with a deterministic order for ties.

Rounded corners have explicit 14-point hit targets using AppKit pan gestures;
straight edges retain native resizing. The backing is 1% opaque to receive
input in the visually transparent corner pixels. No private resize APIs are used.
Apple documented a related resize-pointer/corner-shape fix in the
[macOS 26.4 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-26_4-release-notes).
The gesture-based implementation follows the input guidance in
[Modernize your AppKit app, WWDC26](https://developer.apple.com/videos/play/wwdc2026/289/).
Opening detail never resizes the panel; a deliberate resize in detail is retained
when returning. Primary emphasis changes no more often than every 30 seconds;
secondary emphasis tours every 15 seconds. Hover, menus, detail, resizing, and
hidden windows pause those clocks; Reduce Motion disables layout animation.

`Scripts/test.sh` runs the full test suite through the same quiet workflow.

### Local build

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

`CURRENT_PROJECT_VERSION` intentionally stays at `0` in the checked-in project. App Store builds are produced by Xcode Cloud, which assigns and bumps the build number during the cloud archive flow.
