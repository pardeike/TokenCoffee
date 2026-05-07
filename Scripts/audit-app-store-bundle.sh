#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

APP="${1:-}"

[ -n "$APP" ] || fail "usage: $0 /path/to/Token Coffee.app"
[ -d "$APP" ] || fail "app bundle not found: $APP"
[ -d "$APP/Contents" ] || fail "not an app bundle: $APP"

TMP_PREFIX="${TMPDIR:-/tmp}/tokencoffee-audit.$$"
MACHO_LIST="$TMP_PREFIX.machos"
ENTITLEMENTS="$TMP_PREFIX.entitlements"
trap 'rm -f "$MACHO_LIST" "$ENTITLEMENTS"' EXIT

FORBIDDEN_FOUND=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  printf 'error: forbidden Codex helper remains in bundle: %s\n' "$path" >&2
  FORBIDDEN_FOUND=1
done <<EOF
$(find "$APP" -type f \( -name codex -o -name codex-aarch64-apple-darwin \) -print)
EOF

[ "$FORBIDDEN_FOUND" -eq 0 ] || exit 1

: > "$MACHO_LIST"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if file "$path" | grep -q 'Mach-O'; then
    printf '%s\n' "$path" >> "$MACHO_LIST"
  fi
done <<EOF
$(find "$APP" -type f -print)
EOF

BLOCKED_FRAMEWORKS="
AudioUnit.framework
AVFoundation.framework
CoreAudio.framework
CoreMedia.framework
CoreVideo.framework
IOSurface.framework
Metal.framework
MetalKit.framework
OpenGL.framework
ScreenCaptureKit.framework
VideoToolbox.framework
"

LINK_FOUND=0
while IFS= read -r binary; do
  [ -n "$binary" ] || continue
  deps="$(otool -L "$binary" 2>/dev/null || true)"
  for framework in $BLOCKED_FRAMEWORKS; do
    case "$deps" in
      *"$framework"*)
        printf 'error: %s links forbidden helper-only framework %s\n' "$binary" "$framework" >&2
        LINK_FOUND=1
        ;;
    esac
  done
done < "$MACHO_LIST"

[ "$LINK_FOUND" -eq 0 ] || exit 1

if codesign -d --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null; then
  ENTITLEMENT_FOUND=0
  for entitlement in \
    com.apple.security.files.user-selected.executable \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.files.bookmarks.app-scope \
    com.apple.security.network.server
  do
    if grep -q "$entitlement" "$ENTITLEMENTS"; then
      printf 'error: app has stale entitlement %s\n' "$entitlement" >&2
      ENTITLEMENT_FOUND=1
    fi
  done
  [ "$ENTITLEMENT_FOUND" -eq 0 ] || exit 1
fi

if codesign -dv "$APP" >/dev/null 2>&1; then
  codesign --verify --deep --strict "$APP"
fi

if [ -n "${TOKENCOFFEE_PRIVATE_API_SYMBOLS_FILE:-}" ]; then
  [ -f "$TOKENCOFFEE_PRIVATE_API_SYMBOLS_FILE" ] || fail "private API symbol file not found: $TOKENCOFFEE_PRIVATE_API_SYMBOLS_FILE"
  SYMBOL_FOUND=0
  while IFS= read -r symbol || [ -n "$symbol" ]; do
    case "$symbol" in
      ''|\#*) continue ;;
    esac
    while IFS= read -r binary; do
      [ -n "$binary" ] || continue
      if nm -m "$binary" 2>/dev/null | grep -F -q -- "$symbol"; then
        printf 'error: %s contains private API symbol pattern %s\n' "$binary" "$symbol" >&2
        SYMBOL_FOUND=1
      fi
    done < "$MACHO_LIST"
  done < "$TOKENCOFFEE_PRIVATE_API_SYMBOLS_FILE"
  [ "$SYMBOL_FOUND" -eq 0 ] || exit 1
fi

printf 'Bundle audit passed: %s\n' "$APP"
