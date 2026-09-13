#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
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

NOTARY_VALUES=(
  "${NOTARY_KEY_PATH:-}"
  "${NOTARY_KEY_ID:-}"
  "${NOTARY_ISSUER_ID:-}"
)
NOTARY_VALUE_COUNT=0
for value in "${NOTARY_VALUES[@]}"; do
  if [ -n "$value" ]; then
    NOTARY_VALUE_COUNT=$((NOTARY_VALUE_COUNT + 1))
  fi
done

REQUIRE_NOTARIZATION="${CODEX_REMAINING_REQUIRE_NOTARIZATION:-0}"
if [ "$REQUIRE_NOTARIZATION" != "0" ] && [ "$REQUIRE_NOTARIZATION" != "1" ]; then
  echo "error: CODEX_REMAINING_REQUIRE_NOTARIZATION must be 0 or 1" >&2
  exit 1
fi

NOTARIZE=0
if [ "$REQUIRE_NOTARIZATION" = "1" ] || [ "$NOTARY_VALUE_COUNT" -gt 0 ]; then
  NOTARIZE=1
fi

if [ "$NOTARIZE" = "1" ]; then
  if [ -z "${CODE_SIGN_IDENTITY:-}" ]; then
    echo "error: CODE_SIGN_IDENTITY is required for notarized releases" >&2
    exit 1
  fi
  if [ "$NOTARY_VALUE_COUNT" -ne 3 ]; then
    echo "error: NOTARY_KEY_PATH, NOTARY_KEY_ID, and NOTARY_ISSUER_ID are all required" >&2
    exit 1
  fi
  if [ ! -f "$NOTARY_KEY_PATH" ]; then
    echo "error: NOTARY_KEY_PATH does not exist" >&2
    exit 1
  fi
  if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: xcrun is required for notarization" >&2
    exit 1
  fi
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR" "$BUILD_DIR"
WORK_DIR="$(mktemp -d "$BUILD_DIR/.release.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

APP_DIR="$(
  CODEX_REMAINING_ARCHS='arm64 x86_64' \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}" \
  CODE_SIGN_KEYCHAIN="${CODE_SIGN_KEYCHAIN:-}" \
  "$ROOT/scripts/build-app.sh"
)"

gatekeeper_assess() {
  local app_path="$1"
  if command -v syspolicy_check >/dev/null 2>&1; then
    syspolicy_check distribution "$app_path"
  else
    spctl --assess --type execute --verbose=4 "$app_path"
  fi
}

if [ "$NOTARIZE" = "1" ]; then
  SIGN_INFO="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1)"
  if ! grep -q 'Authority=Developer ID Application:' <<< "$SIGN_INFO"; then
    echo "error: release app is not signed with a Developer ID Application identity" >&2
    printf '%s\n' "$SIGN_INFO" >&2
    exit 1
  fi
  if ! grep -Eq 'flags=.*runtime' <<< "$SIGN_INFO"; then
    echo "error: release app does not have Hardened Runtime enabled" >&2
    printf '%s\n' "$SIGN_INFO" >&2
    exit 1
  fi
  if ! grep -q '^Timestamp=' <<< "$SIGN_INFO"; then
    echo "error: release app does not have a secure signing timestamp" >&2
    printf '%s\n' "$SIGN_INFO" >&2
    exit 1
  fi

  NOTARY_UPLOAD="$WORK_DIR/Codex-Remaining-$EXPECTED_TAG-notary-upload.zip"
  NOTARY_RESULT="$WORK_DIR/notary-result.json"
  NOTARY_LOG="$WORK_DIR/notary-log.json"

  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$NOTARY_UPLOAD"

  if ! xcrun notarytool submit "$NOTARY_UPLOAD" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" \
    --wait \
    --output-format json > "$NOTARY_RESULT"; then
    echo "error: notarytool submission command failed" >&2
    cat "$NOTARY_RESULT" >&2 || true
    exit 1
  fi

  NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT")"
  NOTARY_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT")"

  if [ "$NOTARY_STATUS" != "Accepted" ]; then
    echo "error: Apple notarization status is $NOTARY_STATUS (submission $NOTARY_ID)" >&2
    xcrun notarytool log "$NOTARY_ID" \
      --key "$NOTARY_KEY_PATH" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" \
      "$NOTARY_LOG" || true
    cat "$NOTARY_LOG" >&2 || cat "$NOTARY_RESULT" >&2 || true
    exit 1
  fi

  echo "Apple notarization accepted: $NOTARY_ID" >&2
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  gatekeeper_assess "$APP_DIR"
fi

ZIP_PATH="$DIST_DIR/Codex-Remaining-$EXPECTED_TAG-universal.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"

# Create the public archive only after stapling so offline Gatekeeper checks can
# use the embedded notarization ticket.
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

# Verify the exact archive we are about to publish, not only the pre-zip bundle.
VERIFY_DIR="$WORK_DIR/verify"
mkdir -p "$VERIFY_DIR"
/usr/bin/ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
VERIFY_APP="$VERIFY_DIR/Codex Remaining.app"

codesign --verify --deep --strict --verbose=2 "$VERIFY_APP"

if command -v xcrun >/dev/null 2>&1; then
  LIPO="$(xcrun --find lipo)"
else
  LIPO="$(command -v lipo)"
fi
for arch in arm64 x86_64; do
  "$LIPO" "$VERIFY_APP/Contents/MacOS/CodexRemaining" -verify_arch "$arch"
done

if [ "$NOTARIZE" = "1" ]; then
  xcrun stapler validate "$VERIFY_APP"
  gatekeeper_assess "$VERIFY_APP"
fi

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

printf '%s\n' "$ZIP_PATH" "$CHECKSUM_PATH"
