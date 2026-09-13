#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/Codex Remaining.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

SDK_ARGS=()
if command -v xcrun >/dev/null 2>&1; then
  SWIFTC="$(xcrun --sdk macosx --find swiftc)"
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
  SDK_ARGS=(-sdk "$SDK_PATH")
elif command -v swiftc >/dev/null 2>&1; then
  SWIFTC="$(command -v swiftc)"
else
  echo "error: swiftc not found. Install Apple's Command Line Tools or Xcode." >&2
  exit 1
fi

case "$(uname -m)" in
  arm64|x86_64) TARGET_ARCH="$(uname -m)" ;;
  *)
    echo "error: unsupported Mac architecture: $(uname -m)" >&2
    exit 1
    ;;
esac
TARGET="$TARGET_ARCH-apple-macosx13.0"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"

"$SWIFTC" \
  -O \
  -target "$TARGET" \
  "${SDK_ARGS[@]}" \
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
