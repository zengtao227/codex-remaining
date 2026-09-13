#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT/dist"

if ! command -v plutil >/dev/null 2>&1; then
  echo "error: plutil is required to package a release" >&2
  exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Info.plist")"
EXPECTED_TAG="v$VERSION"
REQUESTED_TAG="${1:-$EXPECTED_TAG}"

if [ "$REQUESTED_TAG" != "$EXPECTED_TAG" ]; then
  echo "error: tag $REQUESTED_TAG does not match Info.plist version $VERSION" >&2
  exit 1
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

APP_DIR="$(CODEX_REMAINING_ARCHS='arm64 x86_64' "$ROOT/scripts/build-app.sh")"
ZIP_PATH="$DIST_DIR/Codex-Remaining-$EXPECTED_TAG-universal.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

printf '%s\n' "$ZIP_PATH" "$CHECKSUM_PATH"
