#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --product cabletapper
BIN="$(swift build -c release --show-bin-path)/cabletapper"
APP="$ROOT/dist/CableTapper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/cabletapper"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Ad-hoc sign with entitlements for local TCC prompts.
codesign --force --sign - --entitlements "$ROOT/Resources/CableTapper.entitlements" "$APP"
echo "Built $APP"
echo "Run: open $APP --args status"
echo "Or:  $APP/Contents/MacOS/cabletapper advertise"
