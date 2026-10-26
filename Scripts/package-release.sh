#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
if [[ $# == 0 ]]; then exec ./Scripts/build.sh --package; fi
if [[ "$1" != --sleep-support || $# -gt 2 || ( $# == 2 && "$2" != --notarize ) ]]; then
    printf 'Use Scripts/package-release.sh [--sleep-support [--notarize]]\n' >&2
    exit 2
fi
mkdir -p .build/logs dist
LOG="$PWD/.build/logs/package-support-$(date +%Y%m%d-%H%M%S).log"
exec 3>&2
STEP=verify
failed() {
    local result=$?
    trap - ERR
    printf 'failed: %s\n' "$STEP" >&3
    tail -n 12 "$LOG" >&3
    printf 'log: %s\n' "$LOG" >&3
    exit "$result"
}
cancel() {
    trap - ERR INT TERM
    pkill -TERM -P "$$" 2>/dev/null || true
    printf 'failed: %s (cancelled)\nlog: %s\n' "$STEP" "$LOG" >&3
    exit 130
}
trap failed ERR
trap cancel INT TERM
/usr/bin/caffeinate -i -w "$$" &
AWAKE_PID=$!
trap 'kill "$AWAKE_PID" 2>/dev/null || true' EXIT
package_support() {
    ./Scripts/test.sh
    STEP=package
    local stage="$PWD/.build/ReleaseSleepSupport/TokenCoffeeSleepSupport"
    local identity="${TOKENCOFFEE_SUPPORT_SIGNING_IDENTITY:-Developer ID Application: Andreas Pardeike (W65292CD8T)}"
    local team="${TOKENCOFFEE_DEVELOPMENT_TEAM:-W65292CD8T}"
    rm -rf "$stage"
    mkdir -p "$stage/Scripts"
    cp .build/Normal/SleepSupport/tokencoffee-sleep-guard "$stage/"
    cp Scripts/install-sleep-support.sh "$stage/Scripts/"
    cp Scripts/SleepSupport/README.md "$stage/"
    cp LICENSE "$stage/"
    codesign --force --options runtime --timestamp --identifier com.pardeike.TokenCoffee.SleepGuard \
        --sign "$identity" "$stage/tokencoffee-sleep-guard"
    codesign --verify --strict -R "=anchor apple generic and identifier \"com.pardeike.TokenCoffee.SleepGuard\" and certificate leaf[subject.OU] = \"$team\"" "$stage/tokencoffee-sleep-guard"
    hdiutil create -volname 'Token Coffee Sleep Support' -srcfolder "$stage" -format UDZO -ov dist/TokenCoffeeSleepSupport.dmg
    codesign --force --timestamp --sign "$identity" dist/TokenCoffeeSleepSupport.dmg
    codesign --verify --strict dist/TokenCoffeeSleepSupport.dmg
    if [[ "${2:-}" == --notarize ]]; then
        STEP=notarize
        codex-apple notarization submit --file dist/TokenCoffeeSleepSupport.dmg --wait --timeout 20m \
            > .build/ReleaseSleepSupport/notarization.json
        cat .build/ReleaseSleepSupport/notarization.json
        STEP=staple
        xcrun stapler staple dist/TokenCoffeeSleepSupport.dmg
        xcrun stapler validate dist/TokenCoffeeSleepSupport.dmg
        spctl --assess --type open --context context:primary-signature --verbose=2 dist/TokenCoffeeSleepSupport.dmg
    fi
    shasum -a 256 dist/TokenCoffeeSleepSupport.dmg > dist/TokenCoffeeSleepSupport.dmg.sha256
}
package_support "$@" >>"$LOG" 2>&1
printf 'ok\n'
