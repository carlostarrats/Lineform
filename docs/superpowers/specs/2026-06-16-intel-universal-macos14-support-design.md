# Lineform: Intel + macOS 14 Support (1.0.9)

> **HISTORICAL.** Intel and macOS 14 support shipped. Any packaging or distribution discussion
> below describes the retired pre-App-Store process.

Date: 2026-06-16
Status: Proposed — awaiting review

## Problem

Lineform 1.0.8 cannot run on a 2018 Intel MacBook Pro (or any Intel Mac, or
any Mac below macOS 15). Two independent blockers, both confirmed by inspecting
the shipped 1.0.8 DMG:

1. **Architecture:** the shipped binary is `arm64`-only. An arm64-only app
   cannot run on Intel at all (Rosetta only translates Intel→ARM, not the
   reverse).
2. **OS floor:** `LSMinimumSystemVersion` / `MACOSX_DEPLOYMENT_TARGET` is `15.0`.
   The target machine is on an older, non-Tahoe macOS.

## Reference: Muse (proves the target config is safe)

Muse (`/Users/carlostarrats/Documents/Projects/Muse`, same author) already runs
on the target machine. Its shipped app:

- Architecture: **universal** `x86_64 arm64`
- Min macOS: **14.6**
- Uses Apple Foundation Models **the same way Lineform does** (`import
  FoundationModels` under `#if canImport`, gated `@available(macOS 26.0)`, no
  special linker flags).

Implications:
- An AI-using app can be universal and run on Intel/older macOS. The Foundation
  Models framework is **not** the cause of Lineform's arm64-only build — the
  macOS 26 SDK provides `x86_64` link stubs (Muse links it and still builds
  universal).
- The target machine runs Muse (min 14.6), so it is on **macOS 14.6 or newer**.
  A macOS 14 floor for Lineform clears it.

## Goal

Lineform 1.0.9 runs on the 2018 Intel MacBook Pro: a **universal** binary with a
**macOS 14** floor, shipped through the full public-release chain (download +
in-app update), with **no changes to app logic, features, UI, or AI behavior**.

## Non-goals

- No app logic / feature / UI / AI behavior changes. This is build config +
  release surfaces only.
- Not lowering below macOS 14 (user decision; matches Muse's proven territory).
- No change to how Apple Intelligence is gated — it stays `@available(macOS 26)`
  and simply remains off on Intel / pre-26 machines, which is the intended
  graceful degradation.

## Changes

### 1. Universal binary (`x86_64 arm64`)

- **Root cause:** `packaging/build-release.sh` runs `xcodebuild ... build`
  without forcing architectures, so it produced the active arch only (arm64).
  Muse archives, which builds all valid archs.
- **Fix:** make the release build emit both slices — pass
  `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` to the `xcodebuild` invocation in
  `build-release.sh` (and confirm no project-level setting excludes `x86_64`).
- **No weak-link flag needed:** `import FoundationModels` is already inside
  `#if canImport(FoundationModels)` and gated `@available(macOS 26.0)`, matching
  Muse. The macOS 26 SDK supplies the `x86_64` link stub.
- **Regression guard:** after the build, `build-release.sh` runs `lipo -archs`
  on the built app binary and **fails the build** if the result is not exactly
  `x86_64 arm64`. This prevents another silent arm64-only regression.

### 2. macOS 14 floor

- Set `MACOSX_DEPLOYMENT_TARGET = 14.0` across all Lineform app build
  configurations (Debug + Release; test target may stay higher if needed to
  build, but the app target is the floor that ships).
- Build with the lower target and fix anything the compiler flags as an
  un-gated macOS 14.x / 15 API. Known surface is minimal:
  - The only explicit `@available(macOS 15.0)` site is
    `LineformTextView.configureWritingTools()` — already gated, so it no-ops on
    macOS 14. No change required there.
  - If the compiler requires a macOS 14 point release for any API, bump the
    floor minimally (e.g. to 14.x, mirroring Muse's 14.6) rather than adding new
    gates. Document the exact chosen value.

### 3. Release surfaces — full 1.0.9 chain (per AGENTS.md release rule)

All of these must describe 1.0.9 before the release is complete:

- `MARKETING_VERSION` 1.0.8 → 1.0.9 and bump the build number
  (`CURRENT_PROJECT_VERSION`).
- About-panel string `V1.0.8` → `V1.0.9`, and update the assertions in
  `LineformTests/ReleaseResourceTests` that pin `1.0.8`.
- Signed + **notarized** universal DMG via `packaging/build-release.sh`.
- GitHub Release with asset `Lineform-1.0.9.dmg`.
- `docs/appcast.xml`: new 1.0.9 item with correct length and **Sparkle EdDSA
  signature**.
- `README.md`: download links → 1.0.9; add a requirements line —
  "Requires macOS 14 or later. Universal (Apple Silicon & Intel)."
- `CLAUDE.md`: update version references, the About string (`V1.0.9`), and the
  minimum-OS / universal note.
- `docs/release/github-sparkle-release.md`: update if any step changes.

## Verification

- `lipo -archs` on the built app = `x86_64 arm64` (enforced by the build guard).
- `LSMinimumSystemVersion` in the built Info.plist = `14.0` (or the chosen 14.x).
- Full deterministic test suite passes, run serially (the AGENTS.md gate):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination
  'platform=macOS' -parallel-testing-enabled NO`.
- CI green (already moved to the `macos-26` runner).
- **Residual risk (stated honestly):** this environment cannot launch the app on
  a real Intel Sonoma/Ventura machine. Build + tests confirm it compiles and
  links universal for the macOS 14 floor; the 2018 Intel MacBook Pro (or a macOS
  14 VM) is the real-world confirmation. AI code paths are unreachable below
  macOS 26, so they are not a concern on the target machine.

## Credentials note

The signed/notarized DMG and the Sparkle EdDSA signature require the author's
Developer ID identity, notary credentials, and `SPARKLE_PUBLIC_ED_KEY` on the
local machine. Those steps run locally — driven interactively or handed over as
exact commands. The code/config changes and the deterministic test run do not
require credentials.
