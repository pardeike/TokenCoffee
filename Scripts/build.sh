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
        wait "$CHILD" || true
    fi
    printf 'failed: %s (cancelled)\nlog: %s\n' "$STEP" "$LOG" >&2
    exit 130
}
trap cancel INT TERM
run() {
    STEP="$1"; shift
    "$@" >>"$LOG" 2>&1 &
    CHILD=$!
    local result=0
    wait "$CHILD" || result=$?
    CHILD=""
    if (( result != 0 )); then
        printf 'failed: %s\n' "$STEP" >&2
        if rg -m 12 'error:|Test Case .*failed|Keychain .*failed|Missing or incorrect' "$LOG" >/dev/null; then
            rg -m 12 'error:|Test Case .*failed|Keychain .*failed|Missing or incorrect' "$LOG" | cut -c1-500 >&2
        else
            tail -n 10 "$LOG" | cut -c1-500 >&2
        fi
        printf 'log: %s\n' "$LOG" >&2
        exit "$result"
    fi
}
MODE="${1:-build}"
case "$MODE" in
    build|--test|--run|--verify|--package|--deploy) ;;
    *) printf 'Use Scripts/build.sh [--test|--verify|--run|--package|--deploy HOST]. Prototype launch modes are retired.\n' >&2; exit 2 ;;
esac
if [[ "$MODE" == --deploy && $# != 2 ]]; then
    printf 'Use Scripts/build.sh --deploy HOST\n' >&2
    exit 2
fi
TEAM="${TOKENCOFFEE_DEVELOPMENT_TEAM:-W65292CD8T}"
BUNDLE_ID=com.pardeike.TokenCoffee
ENVIRONMENT="${TOKENCOFFEE_CLOUDKIT_ENVIRONMENT:-Development}"
DERIVED="$PWD/.build/Normal"
APP="$DERIVED/Build/Products/Release/Token Coffee.app"
SIGNING=(-allowProvisioningUpdates CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic
    "DEVELOPMENT_TEAM=$TEAM"
    "CLOUDKIT_CONTAINER_ENVIRONMENT=$ENVIRONMENT")
run generate xcodegen generate
build_sleep_support() {
    mkdir -p "$DERIVED/SleepSupport"
    xcrun clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=15.0 \
        "-DTOKENCOFFEE_TEAM_ID=\"$TEAM\"" \
        -framework CoreFoundation -framework CoreGraphics -framework IOKit -framework Security Sources/SleepGuard/main.c \
        -o "$DERIVED/SleepSupport/tokencoffee-sleep-guard"
    xcrun clang -O2 -Wall -Wextra -Werror -DSLEEP_GUARD_TESTING -mmacosx-version-min=15.0 \
        -framework CoreFoundation -framework CoreGraphics -framework IOKit -framework Security Sources/SleepGuard/main.c \
        -o "$DERIVED/SleepSupport/test-sleep-guard"
    python3 Scripts/test-sleep-guard.py "$DERIVED/SleepSupport/test-sleep-guard"
}
run sleep-support build_sleep_support
if [[ "$MODE" == --test || "$MODE" == --verify || "$MODE" == --run || "$MODE" == --deploy ]]; then
    run tests xcodebuild -scheme TokenCoffee -configuration Debug -derivedDataPath "$DERIVED" \
        -destination 'platform=macOS,arch=arm64' test "${SIGNING[@]}"
fi
run build xcodebuild -scheme TokenCoffee -configuration Release -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS,arch=arm64' build "${SIGNING[@]}"
verify_signature() {
    codesign --verify --deep --strict "$APP"
    codesign -d --entitlements :- "$APP" > "$DERIVED/signed-entitlements.plist" 2>/dev/null
    local identity
    identity=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$DERIVED/signed-entitlements.plist")
    [[ "$identity" == "$TEAM.$BUNDLE_ID" ]] || { printf 'Missing or incorrect signed application identifier\n'; return 1; }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$DERIVED/signed-entitlements.plist")" == true ]]
}
run signature verify_signature
sign_sleep_support() {
    local identity
    identity=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)
    [[ -n "$identity" ]] || { printf 'Missing signing identity for sleep support\n'; return 1; }
    codesign --force --options runtime --timestamp --identifier com.pardeike.TokenCoffee.SleepGuard --sign "$identity" "$DERIVED/SleepSupport/tokencoffee-sleep-guard"
    codesign --verify --strict "$DERIVED/SleepSupport/tokencoffee-sleep-guard"
}
run sleep-support-signature sign_sleep_support
verify_sleep_support_identity() {
    xcrun clang -O2 -Wall -Wextra -Werror -mmacosx-version-min=15.0 \
        "-DTOKENCOFFEE_TEAM_ID=\"$TEAM\"" -framework CoreFoundation -framework Security \
        Scripts/test-sleep-guard-signature.c -o "$DERIVED/SleepSupport/test-sleep-guard-signature"
    "$DERIVED/SleepSupport/test-sleep-guard-signature" accept "$APP" \
        reject "$DERIVED/SleepSupport/tokencoffee-sleep-guard" reject /usr/bin/true
}
run sleep-support-identity verify_sleep_support_identity
run keychain-crud "$APP/Contents/MacOS/Token Coffee" --verify-account-keychain
if [[ "$MODE" == --run ]]; then
    stop_previous() {
        local ids
        ids=$(brrainztools apps 'Token Coffee' | jq -r '.data.matches[] | select(.bundleIdentifier == "com.pardeike.TokenCoffee" or .bundleIdentifier == "com.pardeike.TokenCoffee.AccountProbe") | .processID')
        for id in $ids; do brrainztools quit --pid "$id" --wait --timeout 20; done
    }
    run stop-previous stop_previous
    run sleep-support-install env "TOKENCOFFEE_INSTALL_LOG_DIRECTORY=$PWD/.build/logs" Scripts/install-sleep-support.sh
    run sleep-support-connection "$APP/Contents/MacOS/Token Coffee" --verify-sleep-protection
    run transfer-settings xcrun swift Scripts/transfer-prototype-data.swift
    run launch brrainztools launch "$APP/Contents/MacOS/Token Coffee" --wait-window --no-prompt --timeout 20
    run verify-window brrainztools ax --app "$APP" wait-for-window 'Token Coffee' --no-prompt --timeout 10
fi
if [[ "$MODE" == --package ]]; then
    run audit Scripts/audit-app-store-bundle.sh "$APP"
    run package-directory mkdir -p dist
    run package ditto -c -k --norsrc --keepParent "$APP" dist/TokenCoffee.zip
fi
if [[ "$MODE" == --deploy ]]; then
    run deploy Scripts/deploy-to-mac.sh "$2" "$APP" "$DERIVED/SleepSupport/tokencoffee-sleep-guard"
fi
printf 'ok\n'
