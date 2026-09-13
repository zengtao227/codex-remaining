#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$("$ROOT/scripts/build-app.sh")"
"$APP_DIR/Contents/MacOS/CodexRemaining" --self-test
