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
    build|--test|--run|--verify|--package) ;;
    *) printf 'Use Scripts/build.sh [--test|--verify|--run|--package]. Prototype launch modes are retired.\n' >&2; exit 2 ;;
esac
TEAM="${TOKENCOFFEE_DEVELOPMENT_TEAM:-W65292CD8T}"
BUNDLE_ID=com.pardeike.TokenCoffee
ENVIRONMENT="${TOKENCOFFEE_CLOUDKIT_ENVIRONMENT:-Development}"
DERIVED="$PWD/.build/Normal"
APP="$DERIVED/Build/Products/Release/Token Coffee.app"
SIGNING=(-allowProvisioningUpdates CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic
    "DEVELOPMENT_TEAM=$TEAM"
    "CLOUDKIT_CONTAINER_ENVIRONMENT=$ENVIRONMENT")
run generate xcodegen generate
if [[ "$MODE" == --test || "$MODE" == --verify || "$MODE" == --run ]]; then
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
run keychain-crud "$APP/Contents/MacOS/Token Coffee" --verify-account-keychain
if [[ "$MODE" == --run ]]; then
    stop_previous() {
        local ids
        ids=$(brrainztools apps 'Token Coffee' | jq -r '.data.matches[] | select(.bundleIdentifier == "com.pardeike.TokenCoffee" or .bundleIdentifier == "com.pardeike.TokenCoffee.AccountProbe") | .processID')
        for id in $ids; do brrainztools quit --pid "$id" --wait --timeout 20; done
    }
    run stop-previous stop_previous
    run transfer-settings xcrun swift Scripts/transfer-prototype-data.swift
    run launch brrainztools launch "$APP/Contents/MacOS/Token Coffee" --wait-window --no-prompt --timeout 20
    run verify-window brrainztools ax --app "$APP" wait-for-window 'Token Coffee' --no-prompt --timeout 10
fi
if [[ "$MODE" == --package ]]; then
    run audit Scripts/audit-app-store-bundle.sh "$APP"
    run package-directory mkdir -p dist
    run package ditto -c -k --norsrc --keepParent "$APP" dist/TokenCoffee.zip
fi
printf 'ok\n'
