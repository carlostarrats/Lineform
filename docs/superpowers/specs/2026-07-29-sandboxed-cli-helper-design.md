# Sandboxed CLI helper (App Store prep)

**Status:** design settled by experiment; implementation BLOCKED on one portal change.
**Date:** 2026-07-29

The bundled `lineform` helper cannot ship to the Mac App Store as built today. Every executable
inside a Mac App Store bundle must be sandboxed, and `Contents/Helpers/lineform` is signed
hardened-runtime with **no** sandbox entitlement. It is also not an Xcode target at all —
`packaging/build-release.sh` compiles and `lipo`s it after `xcodebuild`, so an App Store archive
would not contain it even if the entitlement were fixed.

Everything below was determined by running the real helper under a real sandbox, not by reading
documentation. The probes are reproducible from the commands in the "Evidence" section.

## What the experiments established

**1. A sandboxed helper needs an embedded bundle identity or it dies at launch.**

Signing the existing helper with `com.apple.security.app-sandbox` makes it SIGTRAP (rc=133)
before executing a single line — with ad-hoc signing AND with the real Developer ID cert. The
signature is not the problem: a bare Mach-O has no bundle identifier, so the sandbox cannot
establish a container.

Adding an `__TEXT,__info_plist` section carrying `CFBundleIdentifier` fixes it — the same binary,
same entitlement, same cert, then runs normally (rc=0). This is the single most surprising
finding and it is invisible until you actually run the thing.

**2. `lineform file.md` WORKS sandboxed. No bookmarks, no App Group, no user grant.**

This was the feared blocker and it is not one. A sandboxed helper can `stat` an arbitrary path
given on the command line, including files in `~/Documents`, well outside any container. The
sandbox restricts reading file *data*; the helper never reads the file — it stats it and hands
the path to LaunchServices, which opens it in the app, and the app receives its own grant exactly
as it does for a Finder double-click.

This contradicts the usual advice (that argv paths need a bookmark handshake through a shared
container). That advice applies to a helper that needs to READ the file. This one does not.

**3. `… | lineform -` BREAKS sandboxed. This is the real work.**

Piped input is written to `~/Library/Application Support/Lineform/Piped/`. Under the sandbox that
path silently redirects into the helper's own container:

```
~/Library/Containers/com.lineform.app.helper/Data/Library/Application Support/Lineform/Piped/…
```

The app cannot see it, so the document never opens. `cleanUpStalePipedFiles()` has the same
problem from the other side: it now enumerates the container instead of the real directory, so
housekeeping stops cleaning anything real.

Fixing this requires an **App Group** container shared by the app and the helper — the one piece
that cannot be done from the repo.

**4. A sandboxed helper cannot be built or tested in Debug.**

Ad-hoc signing cannot satisfy the sandbox entitlement, so a sandboxed helper SIGTRAPs on every
developer machine. This is the same rule already recorded for iCloud: *never add an entitlement
to Debug that ad-hoc signing cannot satisfy.* The helper must follow the existing Debug/Release
entitlement split — Debug unsandboxed and working, Release sandboxed.

## The resulting design

- **New Xcode target** for the helper (it must be Xcode-built to appear in an App Store archive),
  producing `Contents/Helpers/lineform` via a Copy Files phase on the app target.
- **Embedded `Info.plist` section** with `CFBundleIdentifier = com.lineform.app.helper`, without
  which the sandboxed binary cannot launch at all.
- **Two entitlement files**, mirroring `Lineform.entitlements` / `LineformDebug.entitlements`:
  Debug has no sandbox (so the CLI keeps working locally), Release has sandbox + App Group.
- **Piped directory moves into the App Group container**, resolved by one shared helper so the
  app and the CLI can never disagree about where piped files live — this is a paired definition
  and both sides must read it from the same place.
- **Housekeeping moves to the app.** Once the directory is in the group container the app can
  enumerate it, which is simpler than the current arrangement and removes the comment explaining
  why the app could not do it.
- **The `NSSavePanel` symlink install is KEPT, pending verification at submission.** An earlier
  draft of this document said it had to be dropped; that was wrong, or at least unproven. The
  entitlement `com.apple.developer.security.privileged-file-operations` covers creating such a
  link *programmatically*. This app does not: the user picks the destination in a save panel, so
  the write is a user-selected grant like any other. Whether review accepts that for
  `/usr/local/bin` is genuinely unknown, and removing a working affordance on a guess is worse
  than carrying the risk. Verify at submission; the fallback (show the bundled path with a
  copyable `ln -s`) is a small change if it is ever rejected.

## Blocker

**The App Groups capability must be enabled for App ID `TV4QZT7A7X.com.lineform` in the Apple
Developer portal, and a group (`group.TV4QZT7A7X.com.lineform`) created.** Until then the shared
container does not exist, the entitlement cannot be satisfied, and the stdin path cannot be built
or tested. This is portal work; it cannot be done from the repository.

Note that `lineform file.md` needs none of this. If the piped-stdin feature were dropped, the
helper could be sandboxed today with only the target + `Info.plist` + entitlement changes.

## Evidence

```sh
# Build the current helper exactly as build-release.sh does
swiftc -O -o lineform Lineform/CommandLineTool/LineformCommandLine.swift HelperTool/main.swift

# Sandboxed, ad-hoc            -> rc=133 (SIGTRAP, dies before main)
# Sandboxed, Developer ID      -> rc=133 (so it is NOT the signature)
# Unsandboxed, ad-hoc          -> rc=0   (works)
# Sandboxed + __info_plist     -> rc=0   (works)

# With the bundle identity embedded and the sandbox on:
./lineform /tmp/probe.md       -> reaches "could not locate Lineform.app"  => stat SUCCEEDED
./lineform ~/Documents/x.md    -> reaches "could not locate Lineform.app"  => stat SUCCEEDED
./lineform /tmp/missing.md     -> "no such file"                            => control, check ran
echo hi | ./lineform -         -> file lands in the helper's CONTAINER, not the real path
```

("could not locate Lineform.app" is the expected error for a probe binary outside an `.app`;
reaching it proves execution got past the existence check.)
