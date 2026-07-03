#!/usr/bin/env bash
set -euo pipefail

# Verify the Sparkle UPDATE PATH for the current top appcast entry — the release-specific
# risks that a plain "does the DMG launch" check does not cover, and that shipped broken as
# 1.1.0 build 14 (bad app) / would ship broken if the EdDSA key or a delta were wrong:
#
#   1. The app's embedded SUPublicEDKey matches the private signing key in the keychain.
#      If not, Sparkle rejects every update as "improperly signed" and NO ONE can update.
#   2. The appcast's edSignature for the full DMG is correct for the exact DMG bytes
#      (Ed25519 is deterministic, so re-signing must reproduce the published signature).
#   3. Each delta in the top item reconstructs the new build from the real old build:
#      BinaryDelta apply(old.app, delta) -> app with the new CFBundleVersion, a valid code
#      signature, and (with LAUNCH_TEST=YES) one that actually launches.
#
# Run after generate-appcast.sh, against dist/ + docs/appcast.xml. LAUNCH_TEST defaults to
# YES on an interactive Mac; set LAUNCH_TEST=NO on headless CI (no window server).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${1:-$REPO_ROOT/dist}"
APPCAST="${APPCAST:-$REPO_ROOT/docs/appcast.xml}"
LAUNCH_TEST="${LAUNCH_TEST:-YES}"

find_bin() {
  local name="$1" c
  for c in \
    "$HOME/Library/Developer/Xcode/DerivedData"/*/SourcePackages/artifacts/sparkle/Sparkle/bin/"$name" \
    "/Applications/Sparkle/bin/$name"; do
    [[ -x "$c" ]] && { echo "$c"; return; }
  done
  echo "error: could not find Sparkle tool '$name'." >&2
  exit 66
}
GENERATE_KEYS="$(find_bin generate_keys)"
SIGN_UPDATE="$(find_bin sign_update)"
BINARY_DELTA="$(find_bin BinaryDelta)"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Resolve the top appcast <item>: its full-DMG enclosure + delta enclosures ------------
TOP_ITEM="$(awk '/<item>/{i++} i==1{print} /<\/item>/{if(i==1)exit}' "$APPCAST")"
DMG_LINE="$(printf '%s\n' "$TOP_ITEM" | grep -E 'enclosure url="[^"]*\.dmg"' | head -1)"
DMG_NAME="$(printf '%s' "$DMG_LINE" | grep -oE 'url="[^"]+"' | head -1 | sed 's|.*/||; s|"||')"
DMG_LEN="$(printf '%s' "$DMG_LINE" | grep -oE 'length="[0-9]+"' | head -1 | sed 's/[^0-9]//g')"
DMG_SIG="$(printf '%s' "$DMG_LINE" | grep -oE 'edSignature="[^"]+"' | head -1 | sed 's/edSignature="//; s/"//')"
DMG_PATH="$DIST_DIR/$DMG_NAME"
[[ -f "$DMG_PATH" ]] || fail "DMG not found: $DMG_PATH"

# Mount the top DMG to read the new app's SUPublicEDKey + CFBundleVersion.
MNT="$(mktemp -d)"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
NEW_APP="$MNT/Lineform.app"
NEW_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$NEW_APP/Contents/Info.plist")"
APP_PUBKEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$NEW_APP/Contents/Info.plist")"
cleanup() { hdiutil detach "$MNT" >/dev/null 2>&1 || true; rm -rf "$MNT" "${WORK:-/nonexistent}" "${BUILD_MAP:-/nonexistent}"; }
trap cleanup EXIT

echo "Verifying update path for build $NEW_BUILD ($DMG_NAME)"

# --- 1. key pair ---------------------------------------------------------------------------
KEY_PUB="$("$GENERATE_KEYS" -p 2>/dev/null | tail -1 | tr -d '[:space:]')"
[[ "$KEY_PUB" == "$APP_PUBKEY" ]] || \
  fail "SUPublicEDKey in app ($APP_PUBKEY) != public key of signing private key ($KEY_PUB). Sparkle would reject all updates."
echo "  [ok] EdDSA key pair matches ($APP_PUBKEY)"

# --- 2. full DMG signature + length --------------------------------------------------------
ACTUAL_LEN="$(stat -f%z "$DMG_PATH")"
[[ "$ACTUAL_LEN" == "$DMG_LEN" ]] || fail "DMG length $ACTUAL_LEN != appcast length $DMG_LEN (regenerate appcast AFTER stapling)."
FRESH_SIG="$("$SIGN_UPDATE" "$DMG_PATH" 2>/dev/null | grep -oE 'edSignature="[^"]+"' | sed 's/edSignature="//; s/"//')"
[[ -n "$DMG_SIG" && "$FRESH_SIG" == "$DMG_SIG" ]] || fail "appcast edSignature does not match sign_update of the DMG bytes."
echo "  [ok] full-DMG signature valid for exact bytes"

# --- 3. deltas: reconstruct new build from the real old build ------------------------------
# Build a build-number -> old-DMG map by reading CFBundleVersion from each dist DMG.
# (bash 3.2 on macOS has no associative arrays, so use a "build<TAB>path" map file.)
BUILD_MAP="$(mktemp)"
for d in "$DIST_DIR"/Lineform-*.dmg; do
  [[ -f "$d" && "$d" != "$DMG_PATH" ]] || continue
  m="$(mktemp -d)"
  if hdiutil attach "$d" -nobrowse -readonly -mountpoint "$m" >/dev/null 2>&1; then
    b="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$m/Lineform.app/Contents/Info.plist" 2>/dev/null || true)"
    [[ -n "$b" ]] && printf '%s\t%s\n' "$b" "$d" >> "$BUILD_MAP"
    hdiutil detach "$m" >/dev/null 2>&1 || true
  fi
  rm -rf "$m"
done
dmg_for_build() { awk -F'\t' -v b="$1" '$1==b{print $2; exit}' "$BUILD_MAP"; }

WORK="$(mktemp -d)"
while IFS= read -r dl; do
  DNAME="$(printf '%s' "$dl" | grep -oE 'url="[^"]+"' | head -1 | sed 's|.*/||; s|"||')"
  DFROM="$(printf '%s' "$dl" | grep -oE 'deltaFrom="[0-9]+"' | head -1 | sed 's/[^0-9]//g')"
  [[ -n "$DNAME" && -n "$DFROM" ]] || continue
  DPATH="$DIST_DIR/$DNAME"
  [[ -f "$DPATH" ]] || fail "delta file missing from dist: $DNAME"
  OLD_DMG="$(dmg_for_build "$DFROM")"
  if [[ -z "$OLD_DMG" ]]; then
    echo "  [skip] delta from build $DFROM — no dist DMG for that build to reconstruct from"
    continue
  fi
  om="$(mktemp -d)"; hdiutil attach "$OLD_DMG" -nobrowse -readonly -mountpoint "$om" >/dev/null
  rm -rf "$WORK/old.app" "$WORK/new.app"
  ditto "$om/Lineform.app" "$WORK/old.app"; hdiutil detach "$om" >/dev/null 2>&1 || true; rm -rf "$om"
  "$BINARY_DELTA" apply "$WORK/old.app" "$WORK/new.app" "$DPATH" >/dev/null 2>&1 || fail "BinaryDelta apply failed for $DNAME (from build $DFROM)."
  GOT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$WORK/new.app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$GOT" == "$NEW_BUILD" ]] || fail "$DNAME reconstructed build $GOT, expected $NEW_BUILD."
  codesign --verify --deep --strict "$WORK/new.app" >/dev/null 2>&1 || fail "$DNAME reconstructed an app with an invalid code signature."
  if [[ "$LAUNCH_TEST" == "YES" ]]; then
    lt="$(mktemp -d)"; ditto "$WORK/new.app" "$lt/Lineform.app"
    if ! open "$lt/Lineform.app" 2>/dev/null || { sleep 3; ! pgrep -qf "$lt/Lineform.app/Contents/MacOS/Lineform"; }; then
      pkill -f "$lt/Lineform.app/Contents/MacOS/Lineform" 2>/dev/null || true; rm -rf "$lt"
      fail "$DNAME reconstructed an app that does NOT launch."
    fi
    osascript -e "tell application \"$lt/Lineform.app\" to quit" >/dev/null 2>&1 || \
      pkill -f "$lt/Lineform.app/Contents/MacOS/Lineform" 2>/dev/null || true
    rm -rf "$lt"
    echo "  [ok] delta from build $DFROM -> build $NEW_BUILD: signature valid + launches"
  else
    echo "  [ok] delta from build $DFROM -> build $NEW_BUILD: signature valid (launch test skipped)"
  fi
done < <(printf '%s\n' "$TOP_ITEM" | grep -E 'enclosure url="[^"]+\.delta"')

echo "Update-path verification PASSED for build $NEW_BUILD."
