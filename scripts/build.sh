#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Mic Input Guard.app"
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1;; esac
plutil -lint "$ROOT/Resources/Info.plist"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/build/ModuleCache"
xcrun swiftc -target "$ARCH-apple-macosx13.0" -module-cache-path "$ROOT/build/ModuleCache" \
  -swift-version 5 -O -framework AppKit -framework CoreAudio -framework UserNotifications \
  "$ROOT/Sources/MicInputGuard.swift" -o "$APP/Contents/MacOS/MicInputGuard"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/config.json" "$APP/Contents/Resources/config.json"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/MicInputGuard" --help > /dev/null
printf 'Built: %s\n' "$APP"
