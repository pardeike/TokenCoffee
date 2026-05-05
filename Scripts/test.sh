#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

xcodegen generate
xcodebuild -scheme TokenHelper -configuration Debug test
