# Token Coffee Privacy Policy

Last updated: September 16, 2026

Token Coffee is a macOS menu-bar utility for viewing Codex and Claude usage limits, forecasting usage, syncing short-lived quota samples through iCloud, and controlling Mac awake behavior.

Token Coffee does not operate its own server, does not include advertising, does not use analytics, and does not sell or share personal data.

## Data Stored Locally

Token Coffee stores quota samples on your Mac. These samples can include timestamps, usage percentages, reset times, and quota identifiers. They are used to show recent usage, build the forecast graph, and improve quota projections for bursty work patterns.

Local quota samples are stored in the user's Application Support folder. Token Coffee keeps only a short rolling history and automatically removes stale samples.

## iCloud Sync

If iCloud is available, Token Coffee can sync quota samples through the user's private iCloud database so usage history can be shared across that user's Macs.

The developer does not operate a separate sync service for this data.

## Account Sign-In and Usage Status

Token Coffee signs in directly with ChatGPT/Codex using OpenAI's device-code flow and reads Codex quota information from the ChatGPT/Codex service. Codex authentication and account handling are provided by the Codex/OpenAI service.

Claude accounts use a separate browser authorization with profile access. Token Coffee reads account identity and usage limits directly from Anthropic. It does not copy or renew credentials belonging to the Claude CLI.

Authentication tokens stay in the app's macOS Keychain, separately for each linked account. Account names, provider identities and selected usage limits are stored locally. Usage history is partitioned by account and limit; credentials never sync through iCloud. Token Coffee does not send authentication data to a Token Coffee server.

## Awake Controls

Token Coffee uses macOS power-management APIs to keep the Mac awake or keep the screen on when the user selects those modes.

## Tracking, Advertising, and Analytics

Token Coffee does not track users across apps or websites.

Token Coffee does not use advertising SDKs, analytics SDKs, or third-party tracking SDKs.

## Contact

For privacy questions, bug reports, and support requests, use GitHub Issues:

https://github.com/pardeike/TokenCoffee/issues

Token Coffee is an independent utility and is not affiliated with OpenAI or Anthropic.
