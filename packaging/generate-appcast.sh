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

# Stage per-version release notes so Sparkle's generate_appcast embeds them as the
# item's <description> (the in-app updater's "What's New" pane). Convention: the tracked
# source lives at docs/release-notes/<dmg-basename>.html (e.g. Lineform-1.3.0.html for
# Lineform-1.3.0.dmg — see docs/release-notes/TEMPLATE.html). generate_appcast auto-embeds
# an .html file sitting next to each archive with the same base name, so we copy the matching
# tracked file into the updates dir. Older DMGs (present only to build deltas) needn't have
# notes; we warn only if the NEWEST version being published lacks them.
RELEASE_NOTES_DIR="$REPO_ROOT/docs/release-notes"
shopt -s nullglob
dmgs=("$UPDATES_DIR"/*.dmg)
shopt -u nullglob
if (( ${#dmgs[@]} )); then
  for dmg in "${dmgs[@]}"; do
    base="$(basename "$dmg" .dmg)"
    if [[ -f "$RELEASE_NOTES_DIR/$base.html" ]]; then
      cp "$RELEASE_NOTES_DIR/$base.html" "$UPDATES_DIR/$base.html"
      echo "[notes] embedded release notes for $base" >&2
    fi
  done
  newest_base="$(printf '%s\n' "${dmgs[@]}" | sort -V | tail -1 | xargs basename | sed 's/\.dmg$//')"
  if [[ ! -f "$RELEASE_NOTES_DIR/$newest_base.html" ]]; then
    echo "[notes] WARNING: no release notes at docs/release-notes/$newest_base.html — the in-app updater's What's New pane will be EMPTY for $newest_base. Copy docs/release-notes/TEMPLATE.html to that name, write user-facing notes, and re-run." >&2
  fi
fi

# --embed-release-notes forces the staged notes INTO the appcast's <description> (CDATA) so the
# appcast stays self-contained — no separately hosted release-notes files to publish. (HTML without
# DOCTYPE/body embeds by default; the flag guarantees it even if the notes grow a full document.)
"$GENERATE_APPCAST_BIN" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --embed-release-notes \
  "$UPDATES_DIR"

mkdir -p "$REPO_ROOT/docs"
cp "$UPDATES_DIR/appcast.xml" "$REPO_ROOT/docs/appcast.xml"
echo "$REPO_ROOT/docs/appcast.xml"
