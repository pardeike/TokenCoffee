#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

DERIVED_DATA="$PWD/.build/DerivedData"
APP="$DERIVED_DATA/Build/Products/Release/Token Coffee.app"
APP_ENTITLEMENTS="$DERIVED_DATA/Build/Intermediates.noindex/TokenCoffee.build/Release/TokenCoffee.build/Token Coffee.app.xcent"
APP_AD_HOC_ENTITLEMENTS="$DERIVED_DATA/Build/Intermediates.noindex/TokenCoffee.build/Release/TokenCoffee.build/TokenCoffeeAdHoc.entitlements"
ZIP="$PWD/dist/TokenCoffee.zip"
BUNDLE_ID="${TOKENCOFFEE_BUNDLE_ID:-com.pardeike.TokenCoffee}"
CLOUDKIT_ENVIRONMENT="${TOKENCOFFEE_CLOUDKIT_ENVIRONMENT:-Production}"
PROVISIONING_ARGS=""
SIGNING_ARGS="CODE_SIGNING_ALLOWED=NO"
AD_HOC_SIGN=1

if [ -n "${TOKENCOFFEE_DEVELOPMENT_TEAM:-}" ]; then
  PROVISIONING_ARGS="-allowProvisioningUpdates"
  SIGNING_ARGS="CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=$TOKENCOFFEE_DEVELOPMENT_TEAM PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID CLOUDKIT_CONTAINER_ENVIRONMENT=$CLOUDKIT_ENVIRONMENT"
  AD_HOC_SIGN=0
fi

xcodegen generate
xcodebuild $PROVISIONING_ARGS -scheme TokenCoffee -configuration Release -derivedDataPath "$DERIVED_DATA" clean build $SIGNING_ARGS

if [ "$AD_HOC_SIGN" -eq 1 ]; then
  find "$APP/Contents/Frameworks" -type d -name "*.framework" -prune -exec codesign --force --sign - --options runtime {} \;
  codesign --verify --verbose=2 "$APP/Contents/MacOS/codex"
  if [ -f "$APP_ENTITLEMENTS" ]; then
    APP_SIGN_ENTITLEMENTS="$APP_ENTITLEMENTS"
  else
    mkdir -p "$(dirname "$APP_AD_HOC_ENTITLEMENTS")"
    cat > "$APP_AD_HOC_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
  <key>com.apple.security.network.client</key>
  <true/>
</dict>
</plist>
PLIST
    APP_SIGN_ENTITLEMENTS="$APP_AD_HOC_ENTITLEMENTS"
  fi
  codesign --force --sign - --options runtime --entitlements "$APP_SIGN_ENTITLEMENTS" "$APP"
fi

rm -rf dist
mkdir -p dist
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP" "$ZIP"

printf '%s\n' "$ZIP"
