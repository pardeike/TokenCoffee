# Multi-account monitoring plan

Updated 2026-09-13 after source research. This combines the accepted layout
prototype with account registration and independent monitoring. It is a design
and implementation sequence, not a claim that live multi-account support exists.

## Product contract

Monitor accounts, not terminal sessions or computers. Someone using account A on
this Mac must be able to add account B used only on another computer, without
configuring B for coding here. Several sessions using one subscription share its
allowance and must not become several independent allowance tiles.

The default flow is Accounts -> Link Codex account or Link Claude account -> provider sign-in
-> confirm identity -> show tile. Existing local coding configurations are not a
prerequisite. No folder picker, token paste, shell setup, or account switching in
the ordinary flow. An external browser may handle authentication; TokenCoffee's
navigation stays in its single panel with a visible Back button.

### Account-management visual reference

Andreas selected the System Settings Users & Groups pattern on September 13.
Reference image: `/Users/ap/Library/Application Support/Drafty/ImportedAttachments/2026-09-13 21.22.47 8317CD Pasted Image.png`.

- A rounded grouped list, with subtle separators between account rows.
- Each row has a circular account/provider image, prominent account name,
  secondary provider/plan/connection status, and a trailing info button.
- Below the group, trailing text-only `Link Codex account…` and
  `Link Claude account…` buttons mirror the reference's two add actions.
- Info opens account details in the same panel, with a clickable Back button.
  Linking also uses that panel for progress, cancellation and return from browser
  authorization. Do not introduce a second app window or depend on keyboard navigation.
- This belongs in account management, not extra permanent controls on the quota
  dashboard. Preserve the uncluttered one-account experience.

The isolated `--account-probe --accounts` mode now implements this list and
single-window navigation, with display-name editing and persistent frame/metadata.
The existing private Claude profile passed native profile-identity and usage reads
through the new detail screen. Codex registration reuses the native device-code
flow with one prototype-only Keychain entry per local account UUID. Pending logins
are journaled, credentials are held in memory until identity validation, and
duplicate allowance identities are rejected before credentials are committed.
Identity checks also guard later reads and Codex refresh writes. Offline checks
cover duplicate identities/profiles, conflicting token identities, persistence,
pending-login metadata and corrupt-registry rejection.

This is not production integration. Additional Claude linking remains an explicit
unfinished page, not a simulated login. Relinking and removal are not connected.
Two distinct Codex accounts have now passed live verification, as recorded below.
Multiple Claude accounts, refresh-token rotation and login cancellation races
still need live verification. The existing native-HTTP diagnostic mode remains
available.
The final signed account build passed Claude identity and usage reads again after
restart. Its single window restored the exact tested 640×452 frame at screen
position 1020,330. The account list was visually checked at its 510×342 minimum
outer window size. These measurements belong to the isolated management probe,
not the dashboard's adaptive layout size classes.

On September 13 at 21:43–21:45 Stockholm time, Andreas completed the prototype's
Codex device-code sign-in. The registry contained one Claude and one Codex Pro
account with verified identities and no pending login. A fresh Developer ID-signed
build and process restart passed the offline checks and sandbox preflight. The
restarted app read Codex usage from its private Keychain entry (39% weekly used)
and Claude usage from its unchanged private profile (100% five-hour, 26% weekly).
Neither read needed another login. This proves mixed-provider coexistence and
credential persistence, not yet multiple subscriptions from a single provider.
The account probe's AppKit frame restoration was observed moving a saved left-
monitor window to the main monitor when the pointer was there at launch. A
controlled restart reproduced the one-display-width shift. The probe now follows
the dashboard's explicit-frame approach and restores before showing the window;
offline checks cover screen ordering, negative coordinates and disconnected
displays. Andreas clarified that persistence primarily concerns the main dashboard,
not this diagnostic window. No dashboard persistence code changed in this step;
further account-probe placement work is deprioritized.

### Live multi-Codex verification, September 13

At 21:59–22:01 Stockholm time, Andreas linked a second Codex account through the
prototype's device-code flow. The nonsecret registry contained three local UUIDs,
two distinct Codex provider account identities, one Claude account, and no pending
login. The second Codex account reports Free rather than Pro; this test does not
establish two paid subscriptions.

`Scripts/build.sh --account-probe --accounts` passed focused offline checks,
Developer ID signing, sandbox preflight and a fresh process launch. That restarted
process then returned all three readings without another sign-in:

| Account | Reported allowance |
| --- | --- |
| First Codex account, Pro | 39% used, 7-day window |
| Second Codex account, Free | 0% used, 30-day window |
| Existing Claude account | 100% five-hour and 26% weekly used |

The Codex usage readers used separate account-scoped Keychain entries and checked
each credential's provider identity. No default coding credential fallback was
used. The Claude reader continued using the existing private profile without
refreshing or copying its credential. This establishes live same-provider account
coexistence, distinct allowance readings and credential persistence across restart.
It does not yet validate token rotation or production dashboard integration.

The main dashboard integration must use each account's actual allowance duration;
the Pro account's seven-day window cannot be assumed for the Free account's graph.
Andreas has no second Claude account available, so its live multi-account test
remains explicitly unverified rather than inferred from Codex's result.

## Reference implementation and evidence

Use [CodexBar](https://github.com/steipete/CodexBar) as the main reference. It is a
native Swift app with about 21,300 GitHub stars at inspection, an active release
history, and source tests covering account identity, reauthentication, process
isolation, and usage parsing. The latest observed release was
[0.60.1, published September 13](https://github.com/steipete/CodexBar/releases/tag/v0.60.1).
Popularity is not proof of correctness; the relevant implementation was inspected.

Source revision inspected: `caad1ca38c237fc77426ad06cf56a2daa1dbbcb9` on main.
This is newer than the observed release; do not assume every inspected behavior
is in that release. Source and tests were read, not executed in this research pass.

| Evidence | What it establishes | How TokenCoffee should use it |
| --- | --- | --- |
| [ManagedCodexAccountService](https://github.com/steipete/CodexBar/blob/caad1ca38c237fc77426ad06cf56a2daa1dbbcb9/Sources/CodexBar/ManagedCodexAccountService.swift#L238) | New login uses a fresh app-managed home. Account metadata is saved before an old home is removed. Identity reconciliation distinguishes provider/workspace identity. | Adapt the staged registration transaction and identity tests, not the entire service. |
| [ClaudeLoginRunner](https://github.com/steipete/CodexBar/blob/caad1ca38c237fc77426ad06cf56a2daa1dbbcb9/Sources/CodexBar/ClaudeLoginRunner.swift#L5) | Runs the official `claude auth login --claudeai` command, tracks browser waiting and actual completion. | Reuse the command/runner pattern with an account-private environment and in-panel progress. |
| [ClaudeStatusProbe](https://github.com/steipete/CodexBar/blob/caad1ca38c237fc77426ad06cf56a2daa1dbbcb9/Sources/CodexBarCore/Providers/Claude/ClaudeStatusProbe.swift#L130) | Runs `/usage`, validates its output, and optionally reads `/status` for identity. This is not the activity-dependent status-line hook. | Adapt the parser, reset handling and failure fixtures. No model prompt is part of this command sequence. Verify current CLI behavior live before promising that property. |
| [ClaudeCLISession](https://github.com/steipete/CodexBar/blob/caad1ca38c237fc77426ad06cf56a2daa1dbbcb9/Sources/CodexBarCore/Providers/Claude/ClaudeCLISession.swift#L318) | Session reuse compares executable, environment and account scope. Uses a private probe directory, bounded capture and process cleanup. | Start with short-lived, serialized probes. Never reuse a process across account identities. |
| [ClaudeCLISessionTests](https://github.com/steipete/CodexBar/blob/caad1ca38c237fc77426ad06cf56a2daa1dbbcb9/Tests/CodexBarTests/ClaudeCLISessionTests.swift) and [ManagedCodexAccountServiceTests](https://github.com/steipete/CodexBar/blob/caad1ca38c237fc77426ad06cf56a2daa1dbbcb9/Tests/CodexBarTests/ManagedCodexAccountServiceTests.swift) | Regression scenarios for changing identities, distinct roots, cancellation, failed persistence and same-email workspaces. | Port the applicable cases alongside the adapted code. Tests use synthetic fixtures; their presence is not live-provider proof. |

CodexBar's [MIT license](https://github.com/steipete/CodexBar/blob/caad1ca38c237fc77426ad06cf56a2daa1dbbcb9/LICENSE)
permits code reuse with its copyright and permission notice retained. Add that
notice and the upstream revision to any copied substantial code and third-party
notices when implementation starts. This research document does not vendor code.
Audit any dependencies pulled in by an adaptation separately.

### What not to copy

CodexBar also uses direct OAuth usage calls, browser cookies and token imports.
Its durable Claude multi-account display currently integrates with `claude-swap`;
it is not itself the exact private-profile registration system proposed here.
See its [account design](https://github.com/steipete/CodexBar/blob/caad1ca38c237fc77426ad06cf56a2daa1dbbcb9/docs/claude-multi-account-and-status-items.md).

The supporting project [claude-swap](https://github.com/realiti4/claude-swap),
inspected at `7187ce83b444c6af7b61ec8ee092623566a2d8fa`, captures saved logins,
can change the active coding account, and directly reads the OAuth usage endpoint
in [oauth.py](https://github.com/realiti4/claude-swap/blob/7187ce83b444c6af7b61ec8ee092623566a2d8fa/src/claude_swap/oauth.py#L399).
Its credential-copy and refresh-ownership complexity is a reason not to import
that subsystem into a monitoring-only app. Its presence is not evidence of a
provider-approved third-party OAuth API. The initial plan therefore used the
official client throughout. Andreas subsequently authorized a direct usage-HTTP
experiment after the terminal sandbox blocker; its successful result is recorded
below. The provider's [credential guidance](https://code.claude.com/docs/en/legal-and-compliance)
remains a separate product-integration constraint, not resolved by HTTP success.

Do not copy automatic account switching, browser database scanning, secret
export/import, automatic acceptance of telemetry/security prompts, or fallback
chains that can silently change which account supplies a tile.

## Combined architecture

### Private monitoring state for each account

Each record has a local UUID, provider, verified provider account identity and
workspace/organization identity where applicable, optional user label, and a
reference to its private connection. Email and local directory names are labels,
not sufficient identity keys. If identity cannot be established, do not merge
histories or publish the reading under an existing account.

Keep secrets out of the registry, logs and usage sync. Scope credential refresh,
quota history, forecasts, in-flight work and errors to one connection/account.
Do not copy the user's coding credentials: create an independent provider login
so TokenCoffee and a coding tool do not race over a copied rotating refresh token.

Private configuration directories are connection state, not extra subscriptions.
There is no need for a full provider executable per account. A helper, if required,
can serve separate profiles, subject to the distribution gate below.

### Codex: preserve the existing native implementation

TokenCoffee already owns its device-code sign-in, Keychain credentials and native
HTTPS usage reader. Extend it with distinct Keychain slots and account-scoped
sessions. Adopt CodexBar's staged add/reauthenticate pattern without introducing
its CLI dependency merely to make the providers look identical internally.

This deliberately refines the earlier suggestion to use CLI linking for both
providers. Their UI can match while credential ownership differs.

Preserve the existing default Keychain slot and original history during adoption.
Legacy history has no account identity; retain it for the existing connection and
never broadcast it into newly added accounts. Do not silently assign old cloud
history to a new identity. Existing CloudKit sync has a single quota zone/state;
introduce account-scoped records and cursors before syncing additional accounts.

The existing native endpoint remains an internal backend contract, as documented
in [INTEGRATION1.md](INTEGRATION1.md). It is not made public or stable by CodexBar
using it too. Preserve focused mapping and authentication tests.

### Claude: private login and native usage, subject to integration approval

Create a fresh private profile for the pending account. Run the official client
login against that profile, then check actual authentication and identity. Never
change the user's default profile. Sanitize inherited provider credentials,
configuration overrides and routing variables so they cannot defeat isolation.

The preferred technical usage path is now a native HTTPS request using that
profile's exact Keychain credential. This passed with normal sandbox entitlements.
Keep the `/usage` terminal adapter as a diagnostic reference only: it requires
a temporary sandbox exception unsuitable for the proposed App Store route.
Prefer structured auth-status identity where available; establish
the complete account/organization mapping during the focused probe. A label alone
does not authorize attaching data to an existing account.

Only allow fixed monitoring/authentication operations. Do not load user projects,
hooks, plugins or MCP servers; do not send natural-language prompts. Unknown
onboarding, permission or consent prompts pause the operation instead of being
accepted automatically. Bound output and runtime, redact errors, and stop child
processes on cancellation, shutdown or account removal.

Use a modest serialized polling cadence with failure backoff initially, then
measure request behavior before choosing a release default. Missing or unparseable windows stay unavailable,
not zero usage or 100% remaining. Preserve the last successful reading with its
measurement time; reading a cache again must not make it fresh.

This private multi-profile composition is our adaptation of demonstrated pieces,
not an already verified end-to-end CodexBar feature.

### Registration and removal

1. Start login in a pending private connection; keep all current accounts usable.
2. On completion, verify provider identity and reconcile duplicates.
3. Commit the registry only after the connection and identity are valid. A usage
   outage can produce a registered account with unavailable usage, not fake data.
4. Reauthentication preserves the existing connection until replacement succeeds.
   Signing into a different account must not overwrite the old account's history.
5. Cancellation or failure removes only pending app-owned state. Account removal
   stops scoped work and disconnects only TokenCoffee; do not call global logout
   or delete the user's normal configurations. Keep local history unless removal
   explicitly includes it. Validate exact owned paths and symlinks before cleanup.

### Cross-device usage and history

Provider readings describe account-wide allowance, not usage attributed to this
computer. Account B can therefore be monitored here while it is used elsewhere,
provided the monitoring connection can independently refresh its limits. Verify
this with the real second-computer scenario, not just two local fixtures.

CloudKit can synchronize observations and labels under verified account identity;
it does not sum per-computer percentages or transfer credentials. An offline Mac
shows last measured usage with its age. Synced history does not prove a local
connection is signed in. If independent Claude polling cannot be delivered, a
remote collector is a different architecture requiring an explicit decision,
not an invisible fallback.

## Preserve the accepted interface

- One panel for overview, account detail, account management and About; visible Back.
- Single-account users get their chart directly, without a persistent account sidebar.
- Retain Pocket, Strip, Gallery, Lanes, Overview and Tall Overview arrangements,
  large-plus-thumbnail cycling and interaction pauses.
- Retain size/aspect-aware live layout selection and the abstract gray resize
  preview; correct invalid geometry after release, without shrinking valid sizes.
- Keep all registered accounts visible in supported arrangements. The prototype
  is verified for one to four; define the supported live count explicitly before
  allowing a fifth, rather than dropping accounts from the display.
- Account identity, not array position, owns selection, graph state and history.
- Persist actual position, dimensions and layout independently of account state.
  Menu-bar reopen and relaunch must not re-anchor or reset a valid saved frame.
  Clamp only when screens or minimum geometry make restoration invalid.

## First implementation gate: packaged Claude feasibility

TokenCoffee is sandboxed and [INTEGRATION1.md](INTEGRATION1.md) explicitly excludes
a Codex helper from its App Store bundle. CodexBar's
[packaging script](https://github.com/steipete/CodexBar/blob/caad1ca38c237fc77426ad06cf56a2daa1dbbcb9/Scripts/package_app.sh#L267)
does not enable the sandbox for its main app; its widget is sandboxed. Its CLI
automation cannot be assumed to work unchanged inside TokenCoffee.

Before full UI integration, prove in the real signed/sandboxed development app:

1. A supported way to locate, launch and authenticate the unmodified Claude
   executable with private configuration and credential storage. Do not quietly
   disable the sandbox, auto-install binaries, re-sign third-party software or
   change distribution channels. A Mac without Claude installed must have an
   explicit dependency/setup outcome; bundling permission is not established.
2. Private login -> identity -> fresh native usage -> restart -> fresh native usage, without
   a model request, and including a refresh/expired-credential recovery case.
3. Two separately authenticated accounts retain independent readings and errors;
   one may be used only on another computer. Existing default CLI state is unchanged.
4. Missing helper, blocked launch, consent, malformed output, cancellation, logout
   and network failure do not hang the panel or display another account's data.

A successful un-sandboxed terminal probe is preliminary evidence only. If this
gate fails, report the exact boundary and reopen the Claude integration decision;
do not substitute a new third-party login flow or remote collection without approval.
The direct usage-only experiment was explicitly authorized on September 13;
it does not implement a new OAuth flow or change credential-refresh ownership.

### Runtime evidence from the isolated probe, September 13

Tested on macOS 27.0 build 26A428 with Claude Code 2.1.270. The probe has its own
bundle identifier and container, `com.pardeike.TokenCoffee.AccountProbe`, and uses
the local Developer ID identity. Production and layout-prototype startup remain
unchanged. Canonical command and controls are documented in README.

| Check | Observed result |
| --- | --- |
| Parent sandbox enforcement | Private file write/read passed; opening the repository's public control file was denied with EPERM. |
| External installed Claude executable | Both Homebrew symlink and resolved executable failed to launch; the resolved path's executable-access check returned EPERM. |
| Unchanged client copied into the local probe bundle | Signature and byte-for-byte copy checks passed. `--version` and terminal allocation succeeded. This is not redistribution approval. |
| Fresh private profile | `auth status --json`, captured with a pipe rather than terminal rendering, reported signed out. |
| Outgoing-network-only login | Failed during OAuth callback-server setup before browser authorization. |
| Login with additional incoming-network entitlement | Official client opened Safari; Andreas authorized the login. A new client process reported logged in. |
| Full probe-app restart | The same private profile remained logged in. No `.credentials.json` plaintext fallback file was present in that profile. |
| Initial interactive usage startup | Failed opening `/tmp/claude-501`. Setting the documented `CLAUDE_CODE_TMPDIR` to private container storage removed that error and reached first-run terminal setup. |
| Interactive setup continuation | Enter and one spaced Escape were written but did not advance setup. The earlier claim that raw mode was enabled was incorrect: its return value had been ignored. Instrumentation now shows `tcgetattr` succeeds but the parent's `tcsetattr` fails with EPERM before the child launches. Input remains canonical with echo enabled. |
| Private first-run preconfiguration | Theme alone did not skip onboarding. Theme plus `hasCompletedOnboarding` reached folder trust. After Andreas explicitly approved this exact private folder, its `hasTrustDialogAccepted` flag skipped that prompt and reached the main screen. These are version-sensitive client configuration fields, not an established public API. Usage still stalled without working raw input. |
| Narrow terminal exception | Adding only `file-ioctl` for `/dev/ttys[0-9]+` through the diagnostic SBPL entitlement made `tcsetattr` succeed. Canonical input and echo were both off. The outside-file control still returned EPERM, and the unchanged Claude child opened `/usage`. |
| Usage with nonessential traffic disabled | With working terminal input and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, the client reached its Usage screen but displayed `Failed to load usage data`. Its log recorded a fetch attempt but no HTTP outcome, even after allowing diagnostic flush time. |
| Live usage with explicit Remote Control opt-out | Removing the extra nonessential-traffic flag, while setting `remoteControlAtStartup=false` in both private configuration and invocation settings, produced HTTP 200 and readings of 34% current-session usage and 18% current-week usage. Run `DFCDE20D-A8C9-4EB7-9F70-8BF81DFFA7CD`. The adapter stopped the child after reading the quotas. |
| Repeat after full app restart | Run `F36E41C9-AB40-4D66-8A85-CF4DCC61F9D8` reused the saved login without browser interaction and again read live quotas: 38% session and 19% week. Private-storage and outside-file denial controls still passed. |

The baseline comparison used the same private profile and usage-only policy in
both runs. Baseline run `CA7BF041-DD45-4C65-992C-0A970768BD01` timed out with
raw-mode EPERM. Exception run `A400CA04-3DA4-4D80-A62D-4523E013F5F3` enabled raw
mode and reached the usage fetch error. The installed macOS sandbox profile
allows pseudo-terminal creation and read/write, but omits `file-ioctl` on its
slave device; its public serial-device entitlement excludes these pseudo-terminals.

This exception is **diagnostic, not the proposed App Store implementation**.
Apple DTS's [direct-distribution guidance](https://developer.apple.com/forums/thread/776609)
explicitly distinguishes temporary exceptions from Mac App Store capabilities.
Do not use a successful Developer ID test to claim an App Store-compatible route.
Production entitlements and bundle audit rules remain unchanged.

Usage probes disable Remote Control auto-start explicitly, tools, hooks and
external MCP configuration, and select default permissions. Do not set
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` in this tested usage path: the comparison
above only obtained data without it. This does not establish its behavior across
other client versions or explain the internal failure mechanism.
An earlier run displayed automatic Remote Control startup; the child was stopped.
Subsequent baseline and exception screens no longer displayed that activity.
These controls follow Anthropic's [Remote Control documentation](https://code.claude.com/docs/en/remote-control).

The client also receives a private `HOME` and `CLAUDE_CONFIG_DIR` through an
environment allowlist. Its normal coding configuration is not imported. The
temporary-directory override is documented in Anthropic's
[environment-variable reference](https://code.claude.com/docs/en/env-vars).

### Native HTTPS follow-up, September 13

Research refreshed CodexBar to `ea4d37a4e740b57107847612b71bf7f7e1c7af2c`.
Its [usage fetcher](https://github.com/steipete/CodexBar/blob/ea4d37a4e740b57107847612b71bf7f7e1c7af2c/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift#L61)
uses `GET https://api.anthropic.com/api/oauth/usage`, an `Authorization: Bearer`
header and `anthropic-beta: oauth-2025-04-20`. JSON contains quota-window objects
such as `five_hour` and `seven_day`, with `utilization` and `resets_at`.
[claude-profile](https://github.com/diranged/claude-profile/blob/189c4e11c00e66c4c752762eb2f1180c76bdba6d/internal/profile/profile.go)
documents and implements the private service name `Claude Code-credentials-`
plus the first eight hex characters of SHA-256 of `CLAUDE_CONFIG_DIR`.
Existing BrrainzTools code independently uses the same endpoint and beta header.

`Scripts/build.sh --account-probe --native-http` builds a separate helper-free
bundle with only `app-sandbox` and `network.client` entitlements. It reuses the
probe's existing signed identity and container. No Claude executable is required,
copied, or launched. The native probe queries only the exact private-profile
Keychain service, rejects ambiguous entries, and does not assume the Keychain
account attribute equals the macOS username. A host-side metadata-only lookup
confirmed that assumption was false for this profile; no secret was exported.

Run `65BBA1F8-D936-428F-BC90-3B7AF13C49EA` read the credential without prompting,
received HTTP 200, and decoded 100% five-hour usage resetting at
`2026-09-13T23:00:00Z` and 26% weekly usage resetting at `2026-09-19T22:00:00Z`.
The outside-file access control still failed with EPERM as required. Credentials
stay in memory for the request; no copies, refreshes, browser cookies, raw
response bodies, or tokens go into reports. Redirects are rejected, response
size and duration are bounded, and failures never trigger automatic retries.
Full restart run `C50A659D-5D35-42FD-A964-372A7FE5677A` repeated the same native
reading without reauthentication. Signature inspection confirmed Developer ID
Application Andreas Pardeike, team `W65292CD8T`, with the stable designated
requirement for `com.pardeike.TokenCoffee.AccountProbe`. Keep that identity and
the `.build/AccountProbeHTTP` location stable for subsequent native tests.

Focused offline checks cover profile-service derivation, distinct paths,
0/100 boundaries, null/unknown windows, malformed values and dates, expired
credentials, missing profile scope, and rejecting MCP-only credential payloads.
These checks run as part of the native probe build.

Do not yet mark the full gate complete. Native usage works for the existing
private login, but a distributable login flow, provider authorization for this
integration, stable account/organization identity, second-account isolation and
credential renewal remain separate checks. The native test establishes a
sandbox-compatible transport, not App Store or provider approval.

## Implementation and verification sequence

### September 13: real-data dashboard integration and renewal soak

The app now has an explicit `--linked-accounts` validation entry point, built with
`Scripts/build.sh --linked-dashboard`. It uses the existing isolated account bundle
identity, not the installed app's credential/history store. Shared app layout and
tile components display two distinct Codex accounts plus Claude General and Fable.
Native live reads matched the CLI: General 26%, Fable 41%, session 100%. Fable's
dynamic scope has a null model ID and `is_active: false`; display-name fallback is
required, and that flag cannot be used as an availability filter.

Independent visibility checkboxes support General only, Fable only, or both without
creating duplicate logins. Local histories are partitioned by account UUID and
scope. Names are not filesystem paths. Codex Free's single 30-day primary allowance
is normalized by duration; it is not mislabeled as a five-hour limit. CloudKit and
power remain outside this validation mode, and the dummy mode stays isolated.

The signed Claude watcher polls the same private profile every five minutes and
delegates renewal to the official CLI near expiry. Its initial expiry is September
14, 03:58 Stockholm time. It requires an actual credential change, advanced expiry,
and successful native usage after the old expiry before declaring renewal verified.
The result is pending. No provider or App Store approval is implied. See README
for the start/status/stop commands. Production onboarding, renewal ownership and
per-account CloudKit integration remain required before switching normal startup.

After the gate: add the account registry and staged registration; namespace the
existing Codex client; adapt the bounded Claude login/probe pieces with notices
and tests; separate history/CloudKit by identity; connect the accepted UI to live
account snapshots; implement normal-panel geometry persistence.

Use the existing quiet workflows in [AGENTS.md](AGENTS.md), extending them only
for the focused sandboxed probe if needed. Run focused account/parser/isolation
tests first, then `Scripts/test.sh`, and the existing bundle audit when preparing
delivery. Keep `--prototype` strictly dummy-only. Do not install or publish as a
side effect of research or local verification.

Acceptance must distinguish fixture/parser tests, signed sandbox runtime proof,
actual provider login, token renewal, remote-account readings and UI persistence.
This research completed source/license inspection and plan synthesis only.
