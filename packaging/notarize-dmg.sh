#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: packaging/notarize-dmg.sh /path/to/Lineform.dmg" >&2
  exit 64
fi

DMG_PATH="$1"
NOTARY_PROFILE="${NOTARY_PROFILE:-lineform-notary}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "error: DMG not found: $DMG_PATH" >&2
  exit 66
fi

xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
