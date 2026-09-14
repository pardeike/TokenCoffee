#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/logs
LOG="$PWD/.build/logs/build-$(date +%Y%m%d-%H%M%S).log"
STEP=setup
CHILD=""
cancel() {
    trap - INT TERM
    if [[ -n "$CHILD" ]]; then
        pkill -TERM -P "$CHILD" 2>/dev/null || true
        kill -TERM "$CHILD" 2>/dev/null || true
        wait "$CHILD" 2>/dev/null || true
    fi
    printf 'failed: %s (cancelled)\nlog: %s\n' "$STEP" "$LOG" >&2
    exit 130
}
trap cancel INT TERM
run() {
    STEP="$1"
    shift
    "$@" >>"$LOG" 2>&1 &
    CHILD=$!
    local result=0
    wait "$CHILD" || result=$?
    CHILD=""
    if (( result != 0 )); then
        printf 'failed: %s\n' "$STEP" >&2
        if [[ "$STEP" == sandbox-preflight ]]; then
            tail -n 1 "$LOG" >&2
        else
            tail -n 15 "$LOG" >&2
        fi
        printf 'log: %s\n' "$LOG" >&2
        exit "$result"
    fi
}
MODE="${1:-build}"
if [[ "$MODE" != build && "$MODE" != --prototype && "$MODE" != --linked-dashboard && "$MODE" != --test && "$MODE" != --account-probe ]]; then
    printf 'usage: Scripts/build.sh [--prototype|--test|--account-probe]\n' >&2
    exit 2
fi
if [[ "$MODE" == --account-probe ]]; then
    WATCH_APP="$PWD/.build/AccountProbeWatch/Token Coffee Account Probe.app"
    WATCH_REPORT="$HOME/Library/Containers/com.pardeike.TokenCoffee.AccountProbe/Data/Library/Application Support/TokenCoffeeAccountProbe/claude-watch.json"
    if [[ "${2:-}" == --watch-status && $# == 2 ]]; then
        jq '{status, startedAt, checkedAt, initialExpiry, currentExpiry, deadline, credentialChanged, lastSuccess, diagrams, refreshAttempts, failure, nextAttemptAt}' "$WATCH_REPORT"
        exit 0
    fi
    if [[ "${2:-}" == --watch-stop && $# == 2 ]]; then
        run stop-claude-watch brrainztools quit --app "$WATCH_APP" --wait --timeout 20
        printf 'ok\n'
        exit 0
    fi
    NATIVE_HTTP=false
    WATCH=false
    if [[ ( "${2:-}" == --native-http || "${2:-}" == --accounts || "${2:-}" == --watch ) && $# == 2 ]]; then
        NATIVE_HTTP=true
        NATIVE_MODE="$2"
        if [[ "$NATIVE_MODE" == --watch ]]; then WATCH=true; fi
        set -- --account-probe --bundled-client --allow-callback --resume "$NATIVE_MODE"
    fi
    if [[ -n "${2:-}" && "${2:-}" != --bundled-client ]]; then
        printf 'usage: Scripts/build.sh --account-probe [--bundled-client]\n' >&2
        exit 2
    fi
    if [[ -n "${3:-}" && "${3:-}" != --allow-callback ]]; then
        printf 'usage: Scripts/build.sh --account-probe --bundled-client [--allow-callback]\n' >&2
        exit 2
    fi
    if [[ -n "${4:-}" && "${4:-}" != --resume ]]; then
        printf 'usage: Scripts/build.sh --account-probe --bundled-client --allow-callback [--resume]\n' >&2
        exit 2
    fi
    if [[ -n "${5:-}" && "${5:-}" != --theme-defaults && "${5:-}" != --onboarding-defaults && "${5:-}" != --trusted-probe-defaults && "$NATIVE_HTTP" != true ]]; then
        printf 'usage: Scripts/build.sh --account-probe --bundled-client --allow-callback --resume [--theme-defaults|--onboarding-defaults|--trusted-probe-defaults]\n' >&2
        exit 2
    fi
    if (( $# > 6 )) || [[ -n "${6:-}" && "${6:-}" != --terminal-exception ]]; then
        printf 'optional final probe argument: --terminal-exception (local diagnostic only)\n' >&2
        exit 2
    fi
    APP="$PWD/.build/AccountProbe/Token Coffee Account Probe.app"
    if [[ "${2:-}" == --bundled-client ]]; then
        APP="$PWD/.build/AccountProbeBundled/Token Coffee Account Probe.app"
    fi
    CLAUDE_EXECUTABLE="unused-native-http"
    if [[ "$NATIVE_HTTP" == true && "$WATCH" != true ]]; then
        APP="$PWD/.build/AccountProbeHTTP/Token Coffee Account Probe.app"
    else
        CLAUDE_EXECUTABLE="$(command -v claude || true)"
        if [[ -z "$CLAUDE_EXECUTABLE" || ! -x "$CLAUDE_EXECUTABLE" ]]; then
            printf 'failed: Claude executable not installed; nothing downloaded\n' >&2
            exit 1
        fi
        CLAUDE_EXECUTABLE="$(realpath "$CLAUDE_EXECUTABLE")"
    fi
    if [[ "$WATCH" == true ]]; then APP="$PWD/.build/AccountProbeWatch/Token Coffee Account Probe.app"; fi
    PROBE_RUN_ID="$(uuidgen)"
    stop_account_probe() {
        local instances
        instances=$(brrainztools apps "$APP" | jq -r --arg app "$APP" '.data.matches[] | select(.bundlePath == $app) | .processID')
        for instance in $instances; do
            brrainztools quit --pid "$instance" --wait --timeout 20
        done
    }
    run stop-previous-account-probe stop_account_probe
    CODEX_SOURCES=(Sources/TokenCoffeeCore/CodexRateLimitClient.swift
        Sources/TokenCoffeeCore/CodexNativeAuthService.swift Sources/TokenCoffeeCore/CodexNativeUsageService.swift
        Sources/TokenCoffeeCore/CodexNativeSupport.swift Sources/TokenCoffeeCore/CodexKeychainTokenStore.swift
        Sources/TokenCoffeeCore/CodexRateLimits.swift Sources/TokenCoffeeCore/ClaudeUsageWindows.swift
        Sources/TokenCoffeeCore/LinkedAccountAuthentication.swift)
    if [[ "$NATIVE_HTTP" == true ]]; then
        run native-usage-check-build xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
            -framework Security -framework LocalAuthentication Sources/TokenCoffeeCore/ClaudeNativeUsage.swift \
            Sources/TokenCoffeeCore/LinkedAccountRegistry.swift Scripts/AccountProbe/AccountWindowFrame.swift "${CODEX_SOURCES[@]}" \
            Scripts/AccountProbe/NativeUsageChecks.swift -o .build/NativeUsageChecks
        run native-usage-checks .build/NativeUsageChecks
    fi
    run create-probe-bundle mkdir -p "$APP/Contents/MacOS"
    if [[ "${2:-}" == --bundled-client && ( "$NATIVE_HTTP" != true || "$WATCH" == true ) ]]; then
        run create-probe-helpers mkdir -p "$APP/Contents/Helpers"
        run copy-unmodified-client cp "$CLAUDE_EXECUTABLE" "$APP/Contents/Helpers/claude"
        run verify-client-copy cmp "$CLAUDE_EXECUTABLE" "$APP/Contents/Helpers/claude"
        run verify-client-signature codesign --verify --strict "$APP/Contents/Helpers/claude"
        CLAUDE_EXECUTABLE="$APP/Contents/Helpers/claude"
    fi
    run probe-metadata cp Scripts/AccountProbe/Info.plist "$APP/Contents/Info.plist"
    run probe-build xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
        -O -target arm64-apple-macos15.0 -framework AppKit -framework Security -framework LocalAuthentication \
        Scripts/AccountProbe/Probe.swift Sources/TokenCoffeeCore/ClaudeNativeUsage.swift Scripts/AccountProbe/ClaudeWatch.swift \
        Sources/TokenCoffeeCore/LinkedAccountRegistry.swift Scripts/AccountProbe/AccountWindowFrame.swift \
        Scripts/AccountProbe/AccountsView.swift "${CODEX_SOURCES[@]}" \
        -o "$APP/Contents/MacOS/TokenCoffeeAccountProbe"
    IDENTITY="${TOKENCOFFEE_SIGNING_IDENTITY:-Developer ID Application: Andreas Pardeike (W65292CD8T)}"
    PROBE_ENTITLEMENTS=Scripts/AccountProbe/Probe.entitlements
    if [[ "${3:-}" == --allow-callback ]]; then
        PROBE_ENTITLEMENTS=Scripts/AccountProbe/Callback.entitlements
    fi
    if [[ "${6:-}" == --terminal-exception ]]; then
        PROBE_ENTITLEMENTS=Scripts/AccountProbe/TerminalException.entitlements
    fi
    if [[ "$NATIVE_HTTP" == true ]]; then
        PROBE_ENTITLEMENTS=Scripts/AccountProbe/Probe.entitlements
    fi
    if [[ "$WATCH" == true ]]; then PROBE_ENTITLEMENTS=Scripts/AccountProbe/TerminalException.entitlements; fi
    run sign-probe codesign --force --options runtime --entitlements "$PROBE_ENTITLEMENTS" \
        --sign "$IDENTITY" "$APP"
    run verify-probe-signature codesign --verify --deep --strict "$APP"
    if [[ "${2:-}" == --bundled-client && ( "$NATIVE_HTTP" != true || "$WATCH" == true ) ]]; then
        run verify-client-still-unmodified cmp "$(realpath "$(command -v claude)")" "$CLAUDE_EXECUTABLE"
    fi
    run inspect-probe-signature codesign -d --entitlements - "$APP"
    PROBE_ARGS=("$CLAUDE_EXECUTABLE" "$PWD/Scripts/AccountProbe/outside-control.txt" "$PROBE_RUN_ID")
    if [[ "${4:-}" == --resume ]]; then PROBE_ARGS+=(--resume); fi
    if [[ -n "${5:-}" ]]; then PROBE_ARGS+=("$5"); fi
    if [[ "$WATCH" == true ]]; then
        run launch-probe brrainztools launch "$APP/Contents/MacOS/TokenCoffeeAccountProbe" \
            --args "${PROBE_ARGS[@]}"
    else
        run launch-probe brrainztools launch "$APP/Contents/MacOS/TokenCoffeeAccountProbe" \
            --wait-window --no-prompt --timeout 20 --args "${PROBE_ARGS[@]}"
        run verify-probe-window brrainztools ax --app "$APP" wait-for-window 'Token Coffee Account Probe' --no-prompt --timeout 10
    fi
    verify_account_preflight() {
        local report="$HOME/Library/Containers/com.pardeike.TokenCoffee.AccountProbe/Data/Library/Application Support/TokenCoffeeAccountProbe/report.json"
        local attempt
        for ((attempt=0; attempt<15; attempt++)); do
            if [[ -f "$report" ]] && jq -e --arg run "$PROBE_RUN_ID" '.result as $result | .runID == $run and (["version_passed", "initial_status", "resume_status", "capabilities", "login_verified"] | index($result)) == null' "$report" >/dev/null; then
                jq -c '{result, outsideRead, privateStorage, executableAccess, launchError, underlyingError, exitStatus, exitReason, authExitStatus, initialStatusDiagnostic, login, usage}' "$report"
                jq -e '.result == "ready_for_login" or .result == "restart_verified" or .result == "native_ready"' "$report" >/dev/null
                return $?
            fi
            sleep 1
        done
        printf 'No fresh sandbox preflight report within 15 seconds.\n' >&2
        return 1
    }
    run sandbox-preflight verify_account_preflight
    if [[ "$WATCH" == true ]]; then
        verify_watch() {
            local attempt
            for ((attempt=0; attempt<30; attempt++)); do
                if [[ -f "$WATCH_REPORT" ]] && jq -e --arg run "$PROBE_RUN_ID" '.runID == $run and .status == "watching" and .lastSuccess != null' "$WATCH_REPORT" >/dev/null; then return 0; fi
                if [[ -f "$WATCH_REPORT" ]] && jq -e --arg run "$PROBE_RUN_ID" '.runID == $run and .status == "needs_attention"' "$WATCH_REPORT" >/dev/null; then
                    jq '{status, failure}' "$WATCH_REPORT"
                    return 1
                fi
                sleep 1
            done
            printf 'Watcher has not completed its first safe usage read within 30 seconds.\n'
            return 1
        }
        run verify-claude-watch verify_watch
    fi
    # 'ok' confirms sandbox preflight only, never provider login or usage.
    printf 'ok\n'
    exit 0
fi
SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO)
if [[ "$MODE" != --prototype && "$MODE" != --linked-dashboard && -n "${TOKENCOFFEE_DEVELOPMENT_TEAM:-}" ]]; then
    SIGNING_ARGS=(-allowProvisioningUpdates CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic
        "DEVELOPMENT_TEAM=$TOKENCOFFEE_DEVELOPMENT_TEAM"
        "PRODUCT_BUNDLE_IDENTIFIER=${TOKENCOFFEE_BUNDLE_ID:-com.pardeike.TokenCoffee}"
        "CLOUDKIT_CONTAINER_ENVIRONMENT=${TOKENCOFFEE_CLOUDKIT_ENVIRONMENT:-Development}")
fi
run generate xcodegen generate
if [[ "$MODE" == --prototype || "$MODE" == --linked-dashboard ]]; then
    run tests xcodebuild -scheme TokenCoffee -configuration Debug -derivedDataPath .build/DerivedData \
        -destination 'platform=macOS,arch=arm64' -only-testing:TokenCoffeeAppTests/PrototypeTests \
        -only-testing:TokenCoffeeAppTests/LinkedDashboardTests \
        -only-testing:TokenCoffeeCoreTests/LinkedAccountManagementTests \
        -only-testing:TokenCoffeeCoreTests/ClaudeUsageWindowsTests test "${SIGNING_ARGS[@]}"
    DERIVED=.build/Prototype
    LAUNCH_MODE=--prototype
    WINDOW_TITLE='Token Coffee Prototype'
    if [[ "$MODE" == --linked-dashboard ]]; then
        DERIVED=.build/LinkedDashboard
        LAUNCH_MODE=--linked-accounts
        WINDOW_TITLE='Token Coffee Linked Accounts'
        SIGNING_ARGS+=(PRODUCT_BUNDLE_IDENTIFIER=com.pardeike.TokenCoffee.AccountProbe)
    fi
    APP="$PWD/$DERIVED/Build/Products/Release/Token Coffee.app"
    stop_prototype() {
        local instances
        instances=$(brrainztools apps "$APP" | jq -r --arg app "$APP" '.data.matches[] | select(.bundlePath == $app) | .processID')
        for instance in $instances; do
            brrainztools quit --pid "$instance" --wait --timeout 20
        done
    }
    run stop-previous-prototype stop_prototype
    run dashboard-build xcodebuild -scheme TokenCoffee -configuration Release -derivedDataPath "$DERIVED" build "${SIGNING_ARGS[@]}"
    IDENTITY="${TOKENCOFFEE_SIGNING_IDENTITY:-Developer ID Application: Andreas Pardeike (W65292CD8T)}"
    run sign-framework codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/TokenCoffeeCore.framework"
    for library in "$APP/Contents/MacOS/"*.dylib; do
        [[ -f "$library" ]] || continue
        run sign-library codesign --force --options runtime --sign "$IDENTITY" "$library"
    done
    DASHBOARD_ENTITLEMENTS=Scripts/Prototype.entitlements
    if [[ "$MODE" == --linked-dashboard ]]; then DASHBOARD_ENTITLEMENTS=Scripts/AccountProbe/Probe.entitlements; fi
    run sign-app codesign --force --options runtime --entitlements "$DASHBOARD_ENTITLEMENTS" --sign "$IDENTITY" "$APP"
    run verify-signature codesign --verify --deep --strict "$APP"
    run launch brrainztools launch "$APP/Contents/MacOS/Token Coffee" --wait-window --no-prompt --timeout 20 --args "$LAUNCH_MODE"
    run verify-window brrainztools ax --app "$APP" wait-for-window "$WINDOW_TITLE" --no-prompt --timeout 10
elif [[ "$MODE" == --test ]]; then
    run tests xcodebuild -scheme TokenCoffee -configuration Debug -derivedDataPath .build/DerivedData \
        -destination 'platform=macOS,arch=arm64' test CODE_SIGNING_ALLOWED=NO
else
    run build xcodebuild -scheme TokenCoffee -configuration Debug -derivedDataPath .build/DerivedData build "${SIGNING_ARGS[@]}"
fi
printf 'ok\n'
