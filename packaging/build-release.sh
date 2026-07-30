#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$REPO_ROOT/DerivedData/Release}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/dist}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-TV4QZT7A7X}"
CODE_SIGN_STYLE="${CODE_SIGN_STYLE:-Automatic}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application: Carlos Tarrats (TV4QZT7A7X)}"
# Defaults to YES: the block this gates carries the exit-68 cert-in-provisioning-profile check and
# the whole nested-bundle re-sign list — the two gates Claude.md marks as never-remove, one of which
# already shipped as a bricked 1.1.0 and the other as a 1.3.0 notary rejection. Defaulting it to NO
# meant the documented release command (`SPARKLE_PUBLIC_ED_KEY=… packaging/build-release.sh`) skipped
# BOTH and still exited 0, while the release doc asserted the gates had run. Opting out now requires
# ALLOW_UNSIGNED_DMG=YES as well, so an unsigned build can never be produced by forgetting a flag.
RESIGN_WITH_DEVELOPER_ID="${RESIGN_WITH_DEVELOPER_ID:-YES}"
ALLOW_UNSIGNED_DMG="${ALLOW_UNSIGNED_DMG:-NO}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Lineform.app"
# Xcode-managed "Mac Team Direct Provisioning Profile: com.lineform.app", refreshed
# 2026-07-02 to embed the current Developer ID cert (the older 68f81f6e… profile from
# Jun 2 predates the cert and ships an app AMFI kills at launch — see the cert gate below).
# Refresh when certs change: xcodebuild archive + -exportArchive (method developer-id,
# signingStyle automatic) -allowProvisioningUpdates mints a new one into this directory.
DEVELOPER_ID_PROFILE_PATH="${DEVELOPER_ID_PROFILE_PATH:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/2184be66-790e-4689-b859-3eaa2ca40f3e.provisionprofile}"

if [[ -z "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  echo "error: set SPARKLE_PUBLIC_ED_KEY to the public key from Sparkle's generate_keys tool." >&2
  exit 65
fi

cd "$REPO_ROOT"

XCODEBUILD_ARGS=(
  -project Lineform.xcodeproj \
  -scheme Lineform \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE="$CODE_SIGN_STYLE" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  -allowProvisioningUpdates \
  build
)

if [[ "$CODE_SIGN_STYLE" != "Automatic" ]]; then
  XCODEBUILD_ARGS+=(CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY")
fi

# Releases must build from a CLEAN Release/Lineform.app. `Contents/Helpers/lineform` is written
# into the bundle AFTER xcodebuild, so a copy left by a previous run is present when the next
# build's CodeSign step runs and fails it with "code object is not signed at all". Claude.md has
# recorded this as a rule since it first bit; nothing enforced it, and the release depended on
# remembering to clean by hand.
rm -rf "$APP_PATH"

xcodebuild "${XCODEBUILD_ARGS[@]}"

# Build the bundled `lineform` command-line helper (universal) into Contents/Helpers.
# The helper is a standalone Foundation tool (HelperTool/main.swift) that reuses the same
# pure logic the app compiles for tests (Lineform/CommandLineTool/LineformCommandLine.swift).
# It ships WITHOUT the App Sandbox entitlement and is signed with the app below.
HELPER_DIR="$APP_PATH/Contents/Helpers"
HELPER_SRC=("$REPO_ROOT/Lineform/CommandLineTool/LineformCommandLine.swift" "$REPO_ROOT/HelperTool/main.swift")
mkdir -p "$HELPER_DIR"
swiftc -O -target arm64-apple-macos14.0  -o "$HELPER_DIR/lineform-arm64"  "${HELPER_SRC[@]}"
swiftc -O -target x86_64-apple-macos14.0 -o "$HELPER_DIR/lineform-x86_64" "${HELPER_SRC[@]}"
lipo -create -output "$HELPER_DIR/lineform" "$HELPER_DIR/lineform-arm64" "$HELPER_DIR/lineform-x86_64"
rm -f "$HELPER_DIR/lineform-arm64" "$HELPER_DIR/lineform-x86_64"

HELPER_ARCHS="$(lipo -archs "$HELPER_DIR/lineform" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
if [[ "$HELPER_ARCHS" != "arm64 x86_64" ]]; then
  echo "error: lineform helper is not universal. Expected 'arm64 x86_64', got '$HELPER_ARCHS'." >&2
  exit 67
fi
echo "Verified universal helper: $HELPER_ARCHS"

# Guard against silently shipping a non-universal binary. Lineform must run on
# both Apple Silicon and Intel Macs, so the app executable has to contain both
# the arm64 and x86_64 slices. Fail loudly if a build ever regresses to a
# single architecture.
APP_BINARY="$APP_PATH/Contents/MacOS/Lineform"
ACTUAL_ARCHS="$(lipo -archs "$APP_BINARY" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
if [[ "$ACTUAL_ARCHS" != "arm64 x86_64" ]]; then
  echo "error: release binary is not universal. Expected 'arm64 x86_64', got '$ACTUAL_ARCHS'." >&2
  echo "       $APP_BINARY" >&2
  exit 67
fi
echo "Verified universal binary: $ACTUAL_ARCHS"

sign_release_item() {
  local item_path="$1"
  codesign --force \
    --sign "$CODE_SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    "$item_path"
}

SPARKLE_PATH="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION_PATH="$SPARKLE_PATH/Versions/B"

if [[ "$RESIGN_WITH_DEVELOPER_ID" == "YES" ]]; then
  if [[ ! -f "$DEVELOPER_ID_PROFILE_PATH" ]]; then
    echo "error: Developer ID provisioning profile not found: $DEVELOPER_ID_PROFILE_PATH" >&2
    exit 66
  fi

  # HARD GATE: the signing cert must be embedded in the provisioning profile.
  # The app carries restricted iCloud entitlements, which AMFI only honors when the
  # cert that signed the app appears in the profile's DeveloperCertificates. A
  # mismatch still passes codesign --verify, notarization, and Gatekeeper, but the
  # kernel SIGKILLs the app at launch on every machine ("Lineform can't be opened").
  # This exact failure shipped as 1.1.0 build 14 — do not remove this check.
  if [[ "$CODE_SIGN_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    SIGNING_CERT_SHA1="$(echo "$CODE_SIGN_IDENTITY" | tr '[:lower:]' '[:upper:]')"
  else
    SIGNING_CERT_SHA1="$(security find-certificate -c "$CODE_SIGN_IDENTITY" -Z 2>/dev/null \
      | awk -F': ' '/^SHA-1 hash:/{print $2}' | head -1)"
  fi
  if [[ -z "$SIGNING_CERT_SHA1" ]]; then
    echo "error: could not resolve signing cert SHA-1 for identity: $CODE_SIGN_IDENTITY" >&2
    exit 68
  fi
  PROFILE_PLIST="$(mktemp)"
  security cms -D -i "$DEVELOPER_ID_PROFILE_PATH" > "$PROFILE_PLIST"
  PROFILE_CERT_SHA1S=""
  cert_index=0
  while /usr/libexec/PlistBuddy -c "Print :DeveloperCertificates:$cert_index" "$PROFILE_PLIST" \
      > "$PROFILE_PLIST.cert" 2>/dev/null; do
    PROFILE_CERT_SHA1S+=" $(openssl x509 -inform der -in "$PROFILE_PLIST.cert" -noout -fingerprint -sha1 \
      | sed 's/.*=//' | tr -d ':')"
    cert_index=$((cert_index + 1))
  done
  rm -f "$PROFILE_PLIST" "$PROFILE_PLIST.cert"
  if [[ " $PROFILE_CERT_SHA1S " != *" $SIGNING_CERT_SHA1 "* ]]; then
    echo "error: signing cert $SIGNING_CERT_SHA1 is NOT in the provisioning profile's DeveloperCertificates." >&2
    echo "       Profile: $DEVELOPER_ID_PROFILE_PATH" >&2
    echo "       Profile certs:$PROFILE_CERT_SHA1S" >&2
    echo "       An app signed this way is killed by AMFI at launch. Regenerate the Developer ID" >&2
    echo "       profile (Xcode: archive + Direct Distribution, or developer.apple.com) so it includes" >&2
    echo "       the current cert, then point DEVELOPER_ID_PROFILE_PATH at it." >&2
    exit 68
  fi
  echo "Verified signing cert $SIGNING_CERT_SHA1 is embedded in the provisioning profile."

  cp "$DEVELOPER_ID_PROFILE_PATH" "$APP_PATH/Contents/embedded.provisionprofile"

  sign_release_item "$APP_PATH/Contents/Helpers/lineform"
  # The Quick Look extension is a nested bundle and must be re-signed with Developer ID
  # too — Xcode signs it with the Apple Development cert, and notarization rejects the
  # whole archive for it ("binary is not signed with a valid Developer ID certificate",
  # "signature does not include a secure timestamp"). It keeps its own sandbox
  # entitlements, so it cannot be signed with the bare sign_release_item helper.
  codesign --force \
    --sign "$CODE_SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "$REPO_ROOT/LineformQuickLook/LineformQuickLook.entitlements" \
    "$APP_PATH/Contents/PlugIns/LineformQuickLook.appex"
  sign_release_item "$SPARKLE_VERSION_PATH/Autoupdate"
  sign_release_item "$SPARKLE_VERSION_PATH/XPCServices/Downloader.xpc"
  sign_release_item "$SPARKLE_VERSION_PATH/XPCServices/Installer.xpc"
  sign_release_item "$SPARKLE_VERSION_PATH/Updater.app"
  sign_release_item "$SPARKLE_PATH"

  codesign --force \
    --sign "$CODE_SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "$REPO_ROOT/Lineform/Lineform.entitlements" \
    "$APP_PATH"
elif [[ "$ALLOW_UNSIGNED_DMG" == "YES" ]]; then
  echo "warning: RESIGN_WITH_DEVELOPER_ID=NO — the cert/profile gate and the nested-bundle re-sign" >&2
  echo "         list were SKIPPED. This build is for local testing only. It will be rejected by" >&2
  echo "         the notary and must never be published." >&2
else
  echo "error: RESIGN_WITH_DEVELOPER_ID=NO without ALLOW_UNSIGNED_DMG=YES." >&2
  echo "       Skipping the re-sign block also skips the exit-68 cert-in-provisioning-profile gate" >&2
  echo "       and leaves the Quick Look appex carrying Xcode's Apple Development signature — the" >&2
  echo "       exact defects that shipped as the 1.1.0 launch brick and the 1.3.0 notary rejection." >&2
  echo "       For a real release, leave RESIGN_WITH_DEVELOPER_ID unset (it defaults to YES)." >&2
  echo "       For a local unsigned build, set ALLOW_UNSIGNED_DMG=YES to acknowledge it." >&2
  exit 70
fi

# HARD GATE: launch the packaged app once before building the DMG. Signing defects
# that AMFI enforces only at spawn (e.g. a cert/profile mismatch on the restricted
# iCloud entitlements) pass every static check — codesign --verify, notarization,
# Gatekeeper — and only show up as the app being SIGKILLed at launch. Catch that
# here instead of shipping it (as happened with 1.1.0 build 14).
if [[ "${SKIP_LAUNCH_SMOKE_TEST:-NO}" != "YES" ]]; then
  echo "Launch smoke test: opening packaged app..."
  SMOKE_APP_DIR="$(mktemp -d)"
  ditto "$APP_PATH" "$SMOKE_APP_DIR/Lineform.app"
  if ! open "$SMOKE_APP_DIR/Lineform.app" 2>/dev/null; then
    echo "error: packaged app FAILED TO LAUNCH (launchd refused to spawn it)." >&2
    echo "       This is the AMFI kill signature: check that the signing cert is in the" >&2
    echo "       embedded provisioning profile and the entitlements are authorized." >&2
    rm -rf "$SMOKE_APP_DIR"
    exit 69
  fi
  sleep 3
  if ! pgrep -qf "$SMOKE_APP_DIR/Lineform.app/Contents/MacOS/Lineform"; then
    echo "error: packaged app spawned but is not running after 3s (crashed at startup?)." >&2
    rm -rf "$SMOKE_APP_DIR"
    exit 69
  fi
  osascript -e "tell application \"$SMOKE_APP_DIR/Lineform.app\" to quit" >/dev/null 2>&1 || \
    pkill -f "$SMOKE_APP_DIR/Lineform.app/Contents/MacOS/Lineform" || true
  sleep 1
  rm -rf "$SMOKE_APP_DIR"
  echo "Launch smoke test passed: packaged app spawns and stays running."
else
  echo "warning: SKIP_LAUNCH_SMOKE_TEST=YES — packaged app was NOT launch-tested." >&2
fi

"$REPO_ROOT/packaging/build-dmg.sh" \
  "$APP_PATH" \
  "$OUTPUT_DIR"
