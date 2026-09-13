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

DEFAULT_ARCH="$(uname -m)"
ARCHS_STRING="${CODEX_REMAINING_ARCHS:-$DEFAULT_ARCH}"
read -r -a ARCHS <<< "$ARCHS_STRING"

if [ "${#ARCHS[@]}" -eq 0 ]; then
  echo "error: no build architectures specified" >&2
  exit 1
fi

for arch in "${ARCHS[@]}"; do
  case "$arch" in
    arm64|x86_64) ;;
    *)
      echo "error: unsupported Mac architecture: $arch" >&2
      exit 1
      ;;
  esac
done

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$BUILD_DIR"
cp "$ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"

compile_arch() {
  local arch="$1"
  local output="$2"

  "$SWIFTC" \
    -O \
    -target "$arch-apple-macosx13.0" \
    "${SDK_ARGS[@]}" \
    -framework AppKit \
    -framework ServiceManagement \
    "$ROOT/Sources/CodexRemaining/main.swift" \
    -o "$output"
}

if [ "${#ARCHS[@]}" -eq 1 ]; then
  compile_arch "${ARCHS[0]}" "$MACOS_DIR/CodexRemaining"
else
  if command -v xcrun >/dev/null 2>&1; then
    LIPO="$(xcrun --find lipo)"
  elif command -v lipo >/dev/null 2>&1; then
    LIPO="$(command -v lipo)"
  else
    echo "error: lipo not found; universal builds require Apple's toolchain" >&2
    exit 1
  fi

  TEMP_DIR="$(mktemp -d "$BUILD_DIR/.codex-remaining.XXXXXX")"
  trap 'rm -rf "$TEMP_DIR"' EXIT

  BINARIES=()
  for arch in "${ARCHS[@]}"; do
    binary="$TEMP_DIR/CodexRemaining-$arch"
    compile_arch "$arch" "$binary"
    BINARIES+=("$binary")
  done

  "$LIPO" "${BINARIES[@]}" -create -output "$MACOS_DIR/CodexRemaining"

  # Some Command Line Tools versions accept only one architecture per
  # -verify_arch invocation, so verify the universal slices individually.
  for arch in "${ARCHS[@]}"; do
    "$LIPO" "$MACOS_DIR/CodexRemaining" -verify_arch "$arch"
  done
fi

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
fi

if ! command -v codesign >/dev/null 2>&1; then
  echo "error: codesign not found" >&2
  exit 1
fi

if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
  SIGN_ARGS=(
    --force
    --options runtime
    --timestamp
    --sign "$CODE_SIGN_IDENTITY"
  )

  if [ -n "${CODE_SIGN_KEYCHAIN:-}" ]; then
    SIGN_ARGS+=(--keychain "$CODE_SIGN_KEYCHAIN")
  fi

  codesign "${SIGN_ARGS[@]}" "$APP_DIR"
else
  # Source/CI validation remains ad-hoc signed. The release workflow supplies
  # CODE_SIGN_IDENTITY and performs Developer ID signing + notarization.
  codesign --force --sign - "$APP_DIR" >/dev/null
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "$APP_DIR"
