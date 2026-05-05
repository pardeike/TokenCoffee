#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

PROJECT_FILE="TokenCoffee.xcodeproj/project.pbxproj"

if [ ! -f "$PROJECT_FILE" ]; then
  printf '%s\n' "Missing $PROJECT_FILE" >&2
  exit 1
fi

if ! grep -q 'AppIcon.icon' "$PROJECT_FILE"; then
  printf '%s\n' "Generated project does not reference AppIcon.icon" >&2
  exit 1
fi

perl -0pi -e 's#(/\* AppIcon\.icon \*/ = \{isa = PBXFileReference; )(?![^}]*lastKnownFileType = )#${1}lastKnownFileType = folder.iconcomposer.icon; #g' "$PROJECT_FILE"

if ! grep -q 'AppIcon.icon \*/ = {isa = PBXFileReference; lastKnownFileType = folder.iconcomposer.icon; path = AppIcon.icon;' "$PROJECT_FILE"; then
  printf '%s\n' "Failed to mark AppIcon.icon as folder.iconcomposer.icon" >&2
  exit 1
fi

if grep -Eq '(Cup[123]\.svg|icon\.json) in Resources' "$PROJECT_FILE"; then
  printf '%s\n' "Icon Composer internals leaked into Copy Bundle Resources" >&2
  exit 1
fi
