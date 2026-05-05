#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

xcodegen generate
xcodebuild -scheme TokenCoffee -configuration Debug test CODE_SIGNING_ALLOWED=NO
