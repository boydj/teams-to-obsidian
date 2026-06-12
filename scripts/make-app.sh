#!/usr/bin/env bash
# Assembles dist/TeamsToObsidian.app from the SwiftPM release build.
# A real .app bundle is required for the TCC permission prompts and the
# login item to behave properly.
set -euo pipefail
cd "$(dirname "$0")/.."

BINARY=".build/release/teams-to-obsidian"
APP="dist/TeamsToObsidian.app"

if [[ ! -x "$BINARY" ]]; then
  echo "error: $BINARY not found — run 'make build' first" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/teams-to-obsidian"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo "Assembled $APP"
