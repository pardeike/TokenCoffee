# Local workflows

- Use `Scripts/build.sh` for every normal build. It always builds the real
  `com.pardeike.TokenCoffee` target with Xcode-managed signing and provisioning,
  verifies the signed identifier and sandbox, and runs real app-owned Keychain
  create/read/update/delete checks. No unsigned or ad-hoc fallback.
- `Scripts/test.sh` runs the full signed test suite and the signed build checks.
- `Scripts/build.sh --run` runs those checks, stops previous Token Coffee processes,
  transfers prototype metadata/settings/history once if the normal account registry
  does not exist, then launches only the normal app from `.build/Normal`.
- `Scripts/build.sh --verify` verifies without launching the normal dashboard.
  `Scripts/package-release.sh` delegates to the same signed workflow with
  `--package`. It creates a local ZIP only; no upload, publication, or release.
- Default development team is W65292CD8T and default CloudKit environment is
  Development. Development/Production change tokens are kept separately. Bundle
  identity remains com.pardeike.TokenCoffee. Keep cloud production publishing out
  of local verification unless explicitly requested.
- Preserve the prototype source, binaries, and container until Andreas confirms
  the normal app. Never start any prototype or account probe. The standard script
  rejects their former launch modes. Historical instructions are archived under
  Scripts/AccountProbe; they are not current execution instructions.
- Full output goes to ignored `.build/logs/`. Print exactly `ok` only after all
  requested checks pass; on failure show the failed step, concise diagnostics,
  log path and nonzero exit code. Stop dependent steps and propagate cancellation.

# Normal application

- The multi-account dashboard is normal startup, with the existing real power
  controller, screen-blackout behavior, menu-bar lifecycle, account manager and
  predictor editor. Dummy UI is retained only for offline tests.
- Accounts own authentication, discovered values and usage history. Predictors
  own account/scope references, names, colours and order. Linking/refreshing must
  not silently add predictors. An adopted legacy single Codex account may seed
  its original chart once; intentionally empty predictor lists remain empty.
- Preserve the fixed-size account/predictor management window and the adaptive
  dashboard's position, size and arrangement. Committed predictor count changes
  grow the selected arrangement before falling back to another layout.
- Claude uses an independent PKCE browser grant, profile-only scope, secure
  code#state entry, and app-owned renewal. Never rotate or copy CLI credentials.
  Codex uses native device-code login. Relinking verifies the original provider
  identity and preserves account UUID, names, predictors, and history.
- Normal credentials use the normal application's data-protection Keychain,
  separate per provider and credential ID. Stage new credentials before metadata
  commit. Cleanup may remain queued but must not block unrelated logins/reads.
  Diagnostics must retain the operation and OSStatus without exposing secrets.
- The one-time transfer copies only metadata, known values, predictors, layout,
  and account-partitioned history. It leaves all prototype data untouched and
  requires explicit reauthorization rather than copying prototype credentials.
  The normal app may adopt its own previous default Codex login by verified
  provider identity, with only one running owner of token renewal.
- Every account/scope uses a CloudKit zone keyed by provider identity and scope,
  independent of which Mac adopted it. Never sync through the unowned legacy zone.
  Preserve unpartitioned history as an archive; do not silently assign it to an
  account. The former Codex account mirrors verified scoped history to the local
  legacy consumer file, preserving that file once before replacement. Secrets never sync.
- Restore saved account diagrams before network reads and mark them cached/stale.
  Maintain continuity confirmation per account and scope before publishing new
  readings. Pending browser authorization must not stop unrelated account reads.
- Account removal is confirmed and keeps predictors/history for reassignment.
  Predictor removal must never remove accounts or history.
- Use a single dashboard for overview, chart detail and About, with clickable
  Back. Editors use the separate management window. During resize retain the
  normal material with grey schematic tiles; choose layout in real time and
  correct dimensions only on release. Preserve rounded-corner hit targets.
