#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/Codex Remaining.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

if command -v xcrun >/dev/null 2>&1; then
  SWIFTC="$(xcrun --find swiftc)"
elif command -v swiftc >/dev/null 2>&1; then
  SWIFTC="$(command -v swiftc)"
else
  echo "error: swiftc not found. Install Apple's Command Line Tools or Xcode." >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"

"$SWIFTC" \
  -O \
  -framework AppKit \
  "$ROOT/Sources/CodexRemaining/main.swift" \
  -o "$MACOS_DIR/CodexRemaining"

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
fi

# Ad-hoc signing avoids an avoidable unsigned-bundle warning during local development.
# Distribution signing/notarization is intentionally out of scope for V1.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
