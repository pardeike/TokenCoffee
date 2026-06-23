#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

DERIVED_DATA="${TOKENCOFFEE_REPLAY_DERIVED_DATA:-/tmp/TokenCoffeeForecastReplayBuild}"
BUILD_LOG="${DERIVED_DATA}/xcodebuild.log"
COMPILE_LOG="${DERIVED_DATA}/swiftc.log"
mkdir -p "$DERIVED_DATA"

if ! xcodebuild \
  -project TokenCoffee.xcodeproj \
  -scheme TokenCoffeeCore \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build \
  CODE_SIGNING_ALLOWED=NO \
  >"$BUILD_LOG" 2>&1; then
  tail -n 80 "$BUILD_LOG" >&2
  exit 1
fi

if ! swiftc \
  -O \
  -F "$DERIVED_DATA/Build/Products/Debug" \
  -F "$DERIVED_DATA/Build/Products/Debug/PackageFrameworks" \
  -I "$DERIVED_DATA/Build/Products/Debug" \
  -framework TokenCoffeeCore \
  -Xlinker -rpath -Xlinker "$DERIVED_DATA/Build/Products/Debug" \
  -Xlinker -rpath -Xlinker "$DERIVED_DATA/Build/Products/Debug/PackageFrameworks" \
  Scripts/ForecastReplay.swift \
  -o "$DERIVED_DATA/forecast-replay" \
  >"$COMPILE_LOG" 2>&1; then
  tail -n 80 "$COMPILE_LOG" >&2
  exit 1
fi

"$DERIVED_DATA/forecast-replay" "$@"
