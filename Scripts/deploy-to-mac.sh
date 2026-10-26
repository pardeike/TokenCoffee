#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/logs
LOG="$PWD/.build/logs/deploy-$(date +%Y%m%d-%H%M%S).log"
exec 3>&2
failed() {
    local result=$?
    trap - ERR
    printf 'failed: remote deployment\n' >&3
    tail -n 12 "$LOG" >&3
    printf 'log: %s\n' "$LOG" >&3
    exit "$result"
}
cancel() {
    trap - INT TERM
    pkill -TERM -P "$$" 2>/dev/null || true
    printf 'failed: remote deployment (cancelled)\nlog: %s\n' "$LOG" >&3
    exit 130
}
trap failed ERR
trap cancel INT TERM
if [[ $# != 3 ]]; then
    printf 'Use Scripts/deploy-to-mac.sh HOST APP GUARD\n' >&2
    exit 2
fi
HOST="$1"
APP="$2"
GUARD="$3"
if [[ ! "$HOST" =~ ^[a-zA-Z0-9@.-]+$ || "$HOST" == -* ]]; then
    printf 'Invalid deployment host\n' >&2
    exit 2
fi
{
STAGE=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" 'mktemp -d /tmp/tokencoffee-delivery.XXXXXX')
ARCHIVE="$PWD/.build/Normal/SleepSupport/TokenCoffee.zip"
ditto -c -k --norsrc --keepParent "$APP" "$ARCHIVE"
scp -q "$ARCHIVE" "$GUARD" Scripts/install-sleep-support.sh "$HOST:$STAGE/"
ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" /bin/bash -s -- "$STAGE" <<'REMOTE'
set -euo pipefail
STAGE="$1"
cd "$STAGE"
ditto -x -k TokenCoffee.zip "$STAGE"
codesign --verify --deep --strict "$STAGE/Token Coffee.app"
codesign --verify --strict "$STAGE/tokencoffee-sleep-guard"
TOOLS="$HOME/Scripts/brrainztools"
TARGET="$HOME/Applications/Token Coffee.app"
APPINFO=$("$TOOLS" apps 'Token Coffee')
PREVIOUS=$(printf '%s' "$APPINFO" | /usr/bin/python3 -c 'import json,sys; matches=[a for a in json.load(sys.stdin)["data"]["matches"] if a.get("bundleIdentifier")=="com.pardeike.TokenCoffee"]; print(matches[0]["bundlePath"] if matches else "")')
BACKUP="$HOME/Library/Application Support/TokenCoffee/Installed App Backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP" "$HOME/Applications"
SUPPORT="$HOME/Library/Application Support/TokenCoffee/Sleep Protection"
AGENTS="$HOME/Library/LaunchAgents"
AGENT_LABEL=com.pardeike.TokenCoffee.sleep-agent
LEGACY_LABEL=com.pardeike.TokenCoffee.clamshell-failsafe
mkdir -p "$BACKUP/Sleep Support"
for file in "$SUPPORT/tokencoffee-sleep-guard" "$AGENTS/$AGENT_LABEL.plist" "$AGENTS/$LEGACY_LABEL.plist"; do
    if [[ -f "$file" ]]; then cp "$file" "$BACKUP/Sleep Support/"; fi
done
AGENT_WAS_LOADED=0
LEGACY_WAS_LOADED=0
if launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; then AGENT_WAS_LOADED=1; fi
if launchctl print "gui/$(id -u)/$LEGACY_LABEL" >/dev/null 2>&1; then LEGACY_WAS_LOADED=1; fi
DELIVERY_STARTED=0
restore_previous() {
    local result=$?
    if (( result != 0 && DELIVERY_STARTED )); then
        for pid in $("$TOOLS" apps 'Token Coffee' | /usr/bin/python3 -c 'import json,sys; print(" ".join(str(a["processID"]) for a in json.load(sys.stdin)["data"]["matches"] if a.get("bundleIdentifier")=="com.pardeike.TokenCoffee"))'); do
            "$TOOLS" quit --pid "$pid" --wait --timeout 20 || true
        done
        launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
        launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
        for file in "$SUPPORT/tokencoffee-sleep-guard" "$AGENTS/$AGENT_LABEL.plist" "$AGENTS/$LEGACY_LABEL.plist"; do
            if [[ -f "$BACKUP/Sleep Support/$(basename "$file")" ]]; then
                cp "$BACKUP/Sleep Support/$(basename "$file")" "$file"
            else
                rm -f "$file"
            fi
        done
        if (( AGENT_WAS_LOADED )); then launchctl bootstrap "gui/$(id -u)" "$AGENTS/$AGENT_LABEL.plist" || true; fi
        if (( LEGACY_WAS_LOADED )); then launchctl bootstrap "gui/$(id -u)" "$AGENTS/$LEGACY_LABEL.plist" || true; fi
        if [[ -d "$BACKUP/Token Coffee.app" ]]; then
            mv "$TARGET" "$STAGE/Failed Token Coffee.app" 2>/dev/null || true
            mv "$BACKUP/Token Coffee.app" "$TARGET"
        fi
        if [[ -n "$PREVIOUS" ]]; then "$TOOLS" launch "$PREVIOUS" || true; fi
    fi
    exit "$result"
}
trap restore_previous EXIT
LID_STATE=$(/usr/sbin/ioreg -a -r -d 1 -c IOPMrootDomain | /usr/bin/python3 -c 'import plistlib,sys; root=plistlib.loads(sys.stdin.buffer.read())[0]; print("closed" if root.get("AppleClamshellState") else "open" if "AppleClamshellState" in root else "desktop")')
if [[ "$LID_STATE" == closed ]]; then
    printf 'Open the MacBook lid before updating sleep support. The running app is unchanged.\n' >&2
    exit 1
fi
DELIVERY_STARTED=1
for pid in $(printf '%s' "$APPINFO" | /usr/bin/python3 -c 'import json,sys; print(" ".join(str(a["processID"]) for a in json.load(sys.stdin)["data"]["matches"] if a.get("bundleIdentifier")=="com.pardeike.TokenCoffee"))'); do
    "$TOOLS" quit --pid "$pid" --wait --timeout 20
done
# Preserve the root-owned App Store bundle and back up any previous user build.
if [[ -d "$TARGET" ]]; then
    mv "$TARGET" "$BACKUP/Token Coffee.app"
fi
mv "$STAGE/Token Coffee.app" "$TARGET"
# Preserve the installer's package layout in the temporary delivery directory.
mkdir -p "$STAGE/Scripts"
mv "$STAGE/install-sleep-support.sh" "$STAGE/Scripts/"
TOKENCOFFEE_INSTALL_LOG_DIRECTORY="$STAGE/.build/logs" /bin/bash "$STAGE/Scripts/install-sleep-support.sh" "$STAGE/tokencoffee-sleep-guard"
codesign --verify --deep --strict "$TARGET"
"$TARGET/Contents/MacOS/Token Coffee" --verify-account-keychain
/usr/bin/python3 -c 'import subprocess,sys; subprocess.run([sys.argv[1], "--verify-sleep-protection"], check=True, timeout=30)' "$TARGET/Contents/MacOS/Token Coffee"
"$TOOLS" launch "$TARGET"
PREFERRED=$(/usr/libexec/PlistBuddy -c 'Print :preferredPowerMode' "$HOME/Library/Containers/com.pardeike.TokenCoffee/Data/Library/Preferences/com.pardeike.TokenCoffee.plist" 2>/dev/null || printf 'off')
HAS_LID=0
if [[ "$LID_STATE" != desktop ]]; then HAS_LID=1; fi
sleep_disabled() {
    /usr/sbin/ioreg -a -r -d 1 -c IOPMrootDomain | /usr/bin/python3 -c 'import plistlib,sys; sys.exit(0 if plistlib.loads(sys.stdin.buffer.read())[0].get("SleepDisabled") is True else 1)'
}
# Wait for the startup condition. The application itself has no polling loop.
for attempt in {1..40}; do
    if [[ "$PREFERRED" == off || "$HAS_LID" == 0 ]] || sleep_disabled; then
        inventory=$("$TOOLS" apps 'Token Coffee')
        pid=$(printf '%s' "$inventory" | /usr/bin/python3 -c 'import json,sys; matches=[a for a in json.load(sys.stdin)["data"]["matches"] if a.get("bundleIdentifier")=="com.pardeike.TokenCoffee"]; assert len(matches)==1 and matches[0]["bundlePath"]==sys.argv[1], "The delivered app is not the sole running Token Coffee"; print(matches[0]["processID"])' "$TARGET")
        if [[ "$PREFERRED" != off ]]; then
            /usr/bin/pgrep -f 'tokencoffee-sleep-guard serve'
            assertions=$(/usr/bin/pmset -g assertions)
            printf '%s' "$assertions" | /usr/bin/grep -F "pid $pid(Token Coffee)" | /usr/bin/grep -F 'PreventUserIdleSystemSleep'
            if [[ "$PREFERRED" == keepAwakeDisplay ]]; then
                printf '%s' "$assertions" | /usr/bin/grep -F "pid $pid(Token Coffee)" | /usr/bin/grep -F 'PreventUserIdleDisplaySleep'
            fi
        fi
        exit 0
    fi
    sleep 0.25
done
printf 'App launched but closed-lid sleep protection did not become active\n' >&2
exit 1
REMOTE
} >>"$LOG" 2>&1
printf 'ok\n'
