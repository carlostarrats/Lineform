#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATES_DIR="${1:-$REPO_ROOT/dist}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/carlostarrats/Lineform/releases/latest/download/}"
if [[ "$DOWNLOAD_URL_PREFIX" != */ ]]; then
  DOWNLOAD_URL_PREFIX="$DOWNLOAD_URL_PREFIX/"
fi

find_generate_appcast() {
  if [[ -n "${GENERATE_APPCAST:-}" && -x "$GENERATE_APPCAST" ]]; then
    echo "$GENERATE_APPCAST"
    return
  fi

  if [[ -n "${SPARKLE_BIN:-}" && -x "$SPARKLE_BIN/generate_appcast" ]]; then
    echo "$SPARKLE_BIN/generate_appcast"
    return
  fi

  local candidate
  for candidate in \
    "$HOME/Library/Developer/Xcode/DerivedData"/*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast \
    "$HOME/Library/Developer/Xcode/DerivedData"/*/SourcePackages/checkouts/Sparkle/bin/generate_appcast \
    "/Applications/Sparkle/bin/generate_appcast"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done

  echo "error: could not find Sparkle generate_appcast. Set GENERATE_APPCAST=/path/to/generate_appcast." >&2
  exit 66
}

GENERATE_APPCAST_BIN="$(find_generate_appcast)"

"$GENERATE_APPCAST_BIN" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  "$UPDATES_DIR"

mkdir -p "$REPO_ROOT/docs"
cp "$UPDATES_DIR/appcast.xml" "$REPO_ROOT/docs/appcast.xml"
echo "$REPO_ROOT/docs/appcast.xml"
