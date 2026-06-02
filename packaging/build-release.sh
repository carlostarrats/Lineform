#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$REPO_ROOT/DerivedData/Release}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/dist}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-TV4QZT7A7X}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application: Carlos Tarrats (TV4QZT7A7X)}"

if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "error: set SPARKLE_PUBLIC_ED_KEY to the public key from Sparkle's generate_keys tool." >&2
  exit 65
fi

cd "$REPO_ROOT"

xcodebuild \
  -project Lineform.xcodeproj \
  -scheme Lineform \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  build

"$REPO_ROOT/packaging/build-dmg.sh" \
  "$DERIVED_DATA_PATH/Build/Products/Release/Lineform.app" \
  "$OUTPUT_DIR"
