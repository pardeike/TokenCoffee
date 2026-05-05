# Token Coffee App Store Codex Integration Plan

## Summary

Use `https://github.com/pardeike/CodexAppServerKit.git` to replace the current sandbox-hostile "launch user-installed Codex and read `~/.codex`" path with an App Store-shaped path:

- Token Coffee bundles a pinned, re-signed `codex app-server` helper.
- The helper inherits Token Coffee's sandbox.
- Codex auth is stored in Token Coffee's app-container-local `CODEX_HOME`, not `~/.codex`.
- Users sign in through Codex's ChatGPT device-code flow.
- Token Coffee reads quota through Codex App Server's documented `account/rateLimits/read`.

This does not use the public OpenAI REST API. It uses the documented local Codex App Server JSON-RPC protocol. OpenAI documents `codex app-server` as the integration surface for authentication and rich clients, with stdio JSONL transport and an open-source implementation:

- https://developers.openai.com/codex/app-server
- https://developers.openai.com/codex/open-source
- https://openai.com/index/unlocking-the-codex-harness/

The OpenAI App Server architecture post supports this shape: local clients typically bundle or fetch a platform-specific App Server binary, launch it as a long-running child process, communicate over bidirectional stdio JSONL, and pin the shipped artifact to tested bits.

## Key Changes

- Add `CodexAppServerKit` as a SwiftPM dependency in `project.yml` from `https://github.com/pardeike/CodexAppServerKit.git`, using `branch: main` for now because the remote currently has no tags.
- Set the Token Coffee app to Apple Silicon only for the first TestFlight path by adding `ARCHS: arm64`.
- Vendor the current arm64 Codex helper binary from `/opt/homebrew/Caskroom/codex/0.128.0/codex-aarch64-apple-darwin` under `Vendor/Codex/0.128.0/codex-aarch64-apple-darwin`.
- Track the vendored Codex binary with Git LFS via `.gitattributes`, because the current helper is about 190 MB.
- Treat `CodexAppServerKit` and the vendored Codex helper as a tested pair. For every helper bump, refresh schema/fixture coverage from `codex app-server generate-json-schema` or recorded RPC fixtures from that exact helper version.
- Add a `CodexHelper.inherit.entitlements` file containing only:
  - `com.apple.security.app-sandbox`
  - `com.apple.security.inherit`
- Copy the vendored helper into `Token Coffee.app/Contents/MacOS/codex` from a post-build script.
- Add a helper build script that:
  - ensures the helper is executable,
  - signs it with the active build identity,
  - applies `CodexHelper.inherit.entitlements`,
  - fails the build if signing or entitlement verification fails.
- Keep `ENABLE_USER_SCRIPT_SANDBOXING = YES` as the project default, but disable it for the app target because the helper-signing script calls `codesign`; with script sandboxing enabled, Xcode fails inside the Code Signing subsystem while replacing the helper signature.
- Keep the host app sandboxed with CloudKit and outgoing network access.
- Remove the previous user-selected executable/home-folder workaround:
  - remove `CodexAccessDefaults`,
  - remove `CodexAccessGrantController`,
  - remove the dashboard `grant` action,
  - remove `com.apple.security.files.user-selected.executable`,
  - remove `com.apple.security.files.user-selected.read-write`,
  - remove `com.apple.security.files.bookmarks.app-scope` unless another feature still needs it.

## App Behavior

- Replace `CodexRateLimitClient`'s hand-rolled one-shot `Process` JSON parsing with a provider backed by `CodexAppServerKit`.
- Keep the App Server as a long-running child process while Token Coffee is active, rather than spawning a short-lived process for every refresh.
- Configure Codex App Server with:
  - bundled helper executable `Bundle.main.url(forAuxiliaryExecutable: "codex")`,
  - client info `{ name: "token_coffee", title: "Token Coffee", version: app version }`,
  - app-container-local `CODEX_HOME` from `CodexAppServerConfiguration.defaultCodexHomeDirectory()`.
- Let `CodexAppServerKit` perform the required `initialize` request followed by the `initialized` notification before any account/rate-limit methods.
- On refresh:
  - start/connect to the bundled app-server,
  - call `account/read`,
  - if auth is missing, set app state to "needs sign-in" instead of "offline",
  - if signed in, call `account/rateLimits/read`,
  - map the Codex bucket into Token Coffee's existing `RateLimitSnapshot`,
  - persist samples and sync them through CloudKit exactly as today.
- Listen to `account/updated`, `account/login/completed`, and `account/rateLimits/updated` notifications so the UI can update without waiting for the next polling interval.
- Add a compact sign-in UI to the existing dashboard:
  - show `sign in` when Codex requires ChatGPT auth,
  - start `chatgptDeviceCode` login,
  - display/copy the user code,
  - open the verification URL in the browser,
  - refresh quota after `account/login/completed`.
- Do not enable the browser OAuth callback flow for v1, because device-code login avoids needing `com.apple.security.network.server`.

## Test Plan

- Run `swift test` in `CodexAppServerKit` before integration to confirm the package still builds.
- Run a pinned-helper contract test that starts the vendored helper with a temporary app-container-style `CODEX_HOME`, performs `initialize` + `initialized`, verifies `account/read`, verifies device-code login can start, and decodes an `account/rateLimits/read` fixture matching the pinned helper version.
- Run `xcodegen generate` in Token Coffee and confirm the generated project contains:
  - the remote `CodexAppServerKit` package,
  - the helper copy/sign script with declared inputs/outputs,
  - `ARCHS = arm64`.
- Run `Scripts/test.sh`.
- Build Debug with Xcode/xcodebuild and verify:
  - `Token Coffee.app/Contents/MacOS/codex` exists,
  - `file .../codex` reports arm64 Mach-O,
  - `codesign -d --entitlements :- .../codex` shows only sandbox + inherit,
  - the main app entitlements no longer contain user-selected executable/read-write/bookmark access,
  - `codesign --verify --deep --strict` passes for the app.
- Run the sandboxed app from Xcode:
  - first launch shows sign-in instead of `grant`,
  - device-code flow produces a code and opens the browser,
  - after sign-in, quota reads successfully,
  - samples persist,
  - graph/prediction behavior is unchanged,
  - CloudKit sync still works.
- Run the release packaging script and repeat entitlement/signature inspection on the Release app.
- After local success, try Xcode Cloud/TestFlight with this branch and inspect build logs for:
  - SwiftPM dependency resolution,
  - Git LFS helper presence,
  - helper signing,
  - app archive validation.

## Assumptions

- First TestFlight attempt is Apple Silicon only.
- Users are willing to sign into Codex separately inside Token Coffee's sandboxed app container.
- We accept the app size increase from bundling the current Codex arm64 helper.
- `CodexAppServerKit` stays as a reusable remote package; Token Coffee owns the pinned Codex executable and signing.
- App Store risk is reduced but not eliminated. The stronger review story is: "Token Coffee embeds a signed sandbox-inheriting Codex App Server helper, uses app-container-local Codex auth, and reads rate limits through OpenAI's documented Codex App Server protocol."
