#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="$project_dir/build/Stimulate.app"

if [[ $# -gt 1 ]] || [[ $# -eq 1 && "$1" != "--install" ]]; then
  echo "Usage: ./build.sh [--install]" >&2
  exit 2
fi

if /usr/bin/pgrep -x Stimulate >/dev/null; then
  echo "Quit Stimulate and wait for any session to stop before rebuilding." >&2
  exit 1
fi

/bin/mkdir -p "$app_dir/Contents/MacOS"
/usr/bin/xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
  -mmacosx-version-min=13.0 "$project_dir/main.m" \
  -framework Cocoa -framework IOKit \
  -o "$app_dir/Contents/MacOS/Stimulate"
/bin/cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
# Finder/file-provider metadata is not valid in a signed bundle. Leave quarantine intact.
/usr/bin/xattr -dr com.apple.FinderInfo "$app_dir" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$app_dir" 2>/dev/null || true
/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/codesign --verify --verbose "$app_dir"
"$app_dir/Contents/MacOS/Stimulate" --self-test

if [[ "${1:-}" == "--install" ]]; then
  /bin/mkdir -p "$HOME/Applications"
  /usr/bin/ditto "$app_dir" "$HOME/Applications/Stimulate.app"
  echo "Installed: $HOME/Applications/Stimulate.app"
else
  echo "Built: $app_dir"
fi
