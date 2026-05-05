# Token Coffee Privacy Policy

Last updated: May 5, 2026

Token Coffee is a macOS menu-bar utility for viewing Codex quota status, forecasting usage, syncing short-lived quota samples through iCloud, and controlling Mac awake behavior.

Token Coffee does not operate its own server, does not include advertising, does not use analytics, and does not sell or share personal data.

## Data Stored Locally

Token Coffee stores quota samples on your Mac. These samples can include timestamps, usage percentages, reset times, and quota identifiers. They are used to show recent usage, build the forecast graph, and improve quota projections for bursty work patterns.

Local quota samples are stored in the user's Application Support folder. Token Coffee keeps only a short rolling history and automatically removes stale samples.

## iCloud Sync

If iCloud is available, Token Coffee can sync quota samples through the user's private iCloud database so usage history can be shared across that user's Macs.

The developer does not operate a separate sync service for this data.

## Codex Sign-In and Quota Status

Token Coffee uses a bundled Codex app-server helper to let the user sign in and read Codex quota information. Codex authentication and account handling are provided by the Codex/OpenAI service.

Token Coffee stores Codex authentication data inside its macOS app container. Token Coffee does not send Codex authentication data to a Token Coffee server.

## Awake Controls

Token Coffee uses macOS power-management APIs to keep the Mac awake or keep the screen on when the user selects those modes.

## Tracking, Advertising, and Analytics

Token Coffee does not track users across apps or websites.

Token Coffee does not use advertising SDKs, analytics SDKs, or third-party tracking SDKs.

## Contact

For privacy questions, bug reports, and support requests, use GitHub Issues:

https://github.com/pardeike/TokenCoffee/issues

Token Coffee is an independent utility and is not affiliated with OpenAI.
