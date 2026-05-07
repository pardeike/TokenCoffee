# Token Coffee Codex Usage Integration

## Summary

Token Coffee reads Codex quota status with a native Swift HTTPS client. It no longer embeds or launches the Codex CLI, a Codex app-server helper, Rust code, or a vendored executable.

The current integration is intentionally small:

- ChatGPT device-code sign-in.
- Keychain storage for Codex authentication tokens.
- Native URLSession requests for token refresh and usage reads.
- Existing Token Coffee quota mapping, forecasting, local history, and optional CloudKit sample sync.

This avoids App Store review risk from shipping a large third-party helper binary. The tradeoff is that the usage endpoint is an internal ChatGPT/Codex backend contract, so it may change and should stay covered by focused decoding tests.

## Backend Shape

The usage client keeps two base URLs separate:

- Auth issuer: `https://auth.openai.com`
- ChatGPT/Codex backend: `https://chatgpt.com/backend-api`

Usage is read from the backend usage endpoint:

- ChatGPT backend style: `/backend-api/wham/usage`
- Codex backend style: `/api/codex/usage`

The client sends the current access token as `Authorization: Bearer ...` and includes the selected account id with `ChatGPT-Account-ID` when available.

## App Behavior

On refresh:

- Load stored tokens from Keychain.
- Refresh the access token when it is close to expiry or the last refresh is stale.
- Decode the current account from JWT claims.
- Read Codex usage.
- Retry once after an unauthorized usage response by refreshing the token.
- Map weekly and short-window quota buckets into Token Coffee's existing `RateLimitSnapshot` model.
- Persist samples and sync them through CloudKit exactly as before.

On sign-in:

- Start device-code login.
- Show the user code and verification URL in the existing menu UI.
- Poll the device-code token endpoint until completion, cancellation, expiry, or timeout.
- Store the resulting tokens in Keychain and refresh quota immediately.

On sign-out:

- Cancel any active login poll.
- Delete stored Codex tokens from Keychain.
- Clear the current account and quota state.

## App Store Bundle Rules

The app bundle must not contain a Codex executable or helper. Release packaging runs `Scripts/audit-app-store-bundle.sh` before zipping the app.

The audit checks:

- No `Contents/MacOS/codex` helper.
- No `codex` or `codex-aarch64-apple-darwin` file in the app bundle.
- No direct linkage to helper-only system frameworks such as ScreenCaptureKit, AVFoundation, AudioUnit, MetalKit, OpenGL, and related media frameworks.
- No stale user-selected executable/read-write/bookmark or incoming-network entitlements.
- Optional private-symbol scan when `TOKENCOFFEE_PRIVATE_API_SYMBOLS_FILE` points at a newline-delimited symbol list.

## Verification

Run:

```sh
Scripts/test.sh
Scripts/package-release.sh
```

The release package script builds the app, signs it, audits the bundle, and writes `dist/TokenCoffee.zip`.
