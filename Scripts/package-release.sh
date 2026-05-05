#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

DERIVED_DATA="$PWD/.build/DerivedData"
APP="$DERIVED_DATA/Build/Products/Release/TokenHelper.app"
ZIP="$PWD/dist/TokenHelper.zip"

xcodegen generate
xcodebuild -scheme TokenHelper -configuration Release -derivedDataPath "$DERIVED_DATA" clean build
codesign --force --deep --sign - "$APP"

rm -rf dist
mkdir -p dist
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP" "$ZIP"

printf '%s\n' "$ZIP"
