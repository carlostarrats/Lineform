#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$REPO_ROOT/DerivedData/Release}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/dist}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-TV4QZT7A7X}"
CODE_SIGN_STYLE="${CODE_SIGN_STYLE:-Automatic}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Developer ID Application: Carlos Tarrats (TV4QZT7A7X)}"
RESIGN_WITH_DEVELOPER_ID="${RESIGN_WITH_DEVELOPER_ID:-NO}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Lineform.app"
DEVELOPER_ID_PROFILE_PATH="${DEVELOPER_ID_PROFILE_PATH:-$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/68f81f6e-70bc-441b-8a57-6cef465bbe5b.provisionprofile}"

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
  -allowProvisioningUpdates \
  build
)

if [[ "$CODE_SIGN_STYLE" != "Automatic" ]]; then
  XCODEBUILD_ARGS+=(CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}"

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

  cp "$DEVELOPER_ID_PROFILE_PATH" "$APP_PATH/Contents/embedded.provisionprofile"

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
else
  echo "warning: built with Xcode-managed signing; set RESIGN_WITH_DEVELOPER_ID=YES only with a matching Developer ID iCloud profile." >&2
fi

"$REPO_ROOT/packaging/build-dmg.sh" \
  "$APP_PATH" \
  "$OUTPUT_DIR"
