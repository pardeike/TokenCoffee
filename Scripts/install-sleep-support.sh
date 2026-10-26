#!/bin/bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
LOG_DIRECTORY="${TOKENCOFFEE_INSTALL_LOG_DIRECTORY:-$HOME/Library/Logs/TokenCoffee}"
mkdir -p "$LOG_DIRECTORY"
LOG="$LOG_DIRECTORY/install-sleep-support-$(date +%Y%m%d-%H%M%S).log"
exec 3>&2
BACKUP=""
AGENT_WAS_LOADED=0
RECOVERY_WAS_LOADED=0
SUPPORT="$HOME/Library/Application Support/TokenCoffee/Sleep Protection"
AGENTS="$HOME/Library/LaunchAgents"
LABEL=com.pardeike.TokenCoffee.sleep-agent
LEGACY_LABEL=com.pardeike.TokenCoffee.clamshell-failsafe
install_support() {
    local default_source="$PWD/.build/Normal/SleepSupport/tokencoffee-sleep-guard"
    if [[ -f "$PWD/tokencoffee-sleep-guard" ]]; then default_source="$PWD/tokencoffee-sleep-guard"; fi
    local source="${1:-$default_source}"
    if pgrep -f '[T]oken Coffee.app/Contents/MacOS/Token Coffee' >/dev/null; then
        printf 'Quit Token Coffee before installing sleep support.\n' >&2
        return 1
    fi
    codesign --verify --strict "$source"
    if [[ ! -d "$HOME/Library/Containers/com.pardeike.TokenCoffee/Data" ]]; then
        printf 'Open Token Coffee once, then quit it before installing sleep support.\n' >&2
        return 1
    fi
    mkdir -p "$SUPPORT" "$AGENTS"
    chmod 700 "$SUPPORT"
    BACKUP="$SUPPORT/Install Backups/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$BACKUP"
    for file in "$SUPPORT/tokencoffee-sleep-guard" "$AGENTS/$LABEL.plist" "$AGENTS/$LEGACY_LABEL.plist"; do
        if [[ -f "$file" ]]; then cp "$file" "$BACKUP/"; fi
    done
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then AGENT_WAS_LOADED=1; fi
    if launchctl print "gui/$(id -u)/$LEGACY_LABEL" >/dev/null 2>&1; then RECOVERY_WAS_LOADED=1; fi
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
    # The user installs this agent explicitly from outside App Sandbox.
    cp "$source" "$SUPPORT/tokencoffee-sleep-guard.new"
    chmod 755 "$SUPPORT/tokencoffee-sleep-guard.new"
    mv "$SUPPORT/tokencoffee-sleep-guard.new" "$SUPPORT/tokencoffee-sleep-guard"
    cat >"$AGENTS/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$SUPPORT/tokencoffee-sleep-guard</string><string>serve</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>1</integer>
<key>ProcessType</key><string>Interactive</string>
<key>StandardErrorPath</key><string>$SUPPORT/agent.log</string>
</dict></plist>
PLIST
    plutil -lint "$AGENTS/$LABEL.plist"
    "$SUPPORT/tokencoffee-sleep-guard" recover
    rm -f "$HOME/Library/Containers/com.pardeike.TokenCoffee/Data/.sleep-agent.sock"
    launchctl bootstrap "gui/$(id -u)" "$AGENTS/$LABEL.plist"
    for attempt in {1..40}; do
        if [[ -S "$HOME/Library/Containers/com.pardeike.TokenCoffee/Data/.sleep-agent.sock" ]]; then
            launchctl print "gui/$(id -u)/$LABEL"
            codesign --verify --strict "$SUPPORT/tokencoffee-sleep-guard"
            "$SUPPORT/tokencoffee-sleep-guard" probe
            rm -f "$AGENTS/$LEGACY_LABEL.plist"
            return 0
        fi
        sleep 0.25
    done
    printf 'The sleep agent did not create its local socket.\n' >&2
    tail -n 5 "$SUPPORT/agent.log" >&2
    return 1
}
restore_support() {
    if [[ -n "$BACKUP" ]]; then
        launchctl bootout "gui/$(id -u)/$LABEL" >>"$LOG" 2>&1 || true
        for file in "$SUPPORT/tokencoffee-sleep-guard" "$AGENTS/$LABEL.plist" "$AGENTS/$LEGACY_LABEL.plist"; do
            if [[ -f "$BACKUP/$(basename "$file")" ]]; then cp "$BACKUP/$(basename "$file")" "$file"; else rm -f "$file"; fi
        done
        if (( AGENT_WAS_LOADED )); then launchctl bootstrap "gui/$(id -u)" "$AGENTS/$LABEL.plist" >>"$LOG" 2>&1 || true; fi
        if (( RECOVERY_WAS_LOADED )); then launchctl bootstrap "gui/$(id -u)" "$AGENTS/$LEGACY_LABEL.plist" >>"$LOG" 2>&1 || true; fi
    fi
}
failed() {
    local result=$?
    trap - ERR
    set +e
    restore_support
    printf 'failed: install sleep support\n' >&3
    tail -n 8 "$LOG" >&3
    printf 'log: %s\n' "$LOG" >&3
    exit "$result"
}
cancel() {
    trap - ERR INT TERM
    set +e
    pkill -TERM -P "$$" 2>/dev/null
    restore_support
    printf 'failed: install sleep support (cancelled)\nlog: %s\n' "$LOG" >&3
    exit 130
}
trap failed ERR
trap cancel INT TERM
install_support "$@" >>"$LOG" 2>&1
printf 'ok\n'
