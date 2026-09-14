#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
exec ./Scripts/build.sh --package
