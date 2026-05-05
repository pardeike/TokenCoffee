#!/usr/bin/env bash
set -euo pipefail

helper_source="${SRCROOT}/Vendor/Codex/0.128.0/codex-aarch64-apple-darwin"
helper_destination="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}/codex"
helper_entitlements="${SRCROOT}/Sources/TokenCoffeeApp/CodexHelper.inherit.entitlements"
entitlements_dump="${DERIVED_FILE_DIR}/codex-helper-entitlements.plist"

if [[ ! -f "${helper_source}" ]]; then
  echo "error: Missing vendored Codex helper: ${helper_source}" >&2
  exit 1
fi

mkdir -p "$(dirname "${helper_destination}")"
cp -f "${helper_source}" "${helper_destination}"
chmod 755 "${helper_destination}"
xattr -cr "${helper_destination}" 2>/dev/null || true

signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" || -z "${signing_identity}" ]]; then
  signing_identity="-"
fi

/usr/bin/codesign \
  --force \
  --sign "${signing_identity}" \
  --entitlements "${helper_entitlements}" \
  --options runtime \
  "${helper_destination}"

/usr/bin/codesign --verify --verbose=2 "${helper_destination}"
/usr/bin/codesign -d --entitlements :- "${helper_destination}" > "${entitlements_dump}" 2>/dev/null

if [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - "${entitlements_dump}")" != "true" ]]; then
  echo "error: Codex helper is missing com.apple.security.app-sandbox." >&2
  exit 1
fi

if [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.inherit' raw -o - "${entitlements_dump}")" != "true" ]]; then
  echo "error: Codex helper is missing com.apple.security.inherit." >&2
  exit 1
fi
