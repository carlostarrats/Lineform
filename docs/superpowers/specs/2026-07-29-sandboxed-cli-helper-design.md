# Sandboxed CLI helper — blocked on the obvious routes, one untested route remains

**Status: not solved, not proven impossible.** Every *file-based* hand-off from a sandboxed helper
fails, but **URL-scheme opening works**, and that route has not been built or tested. An earlier
revision of this document declared the whole thing impossible; that was an over-generalisation
from four failing file/app routes, corrected on the same day.

Every finding below was produced by running a real Developer ID-signed sandboxed binary.

## What a sandboxed helper can and cannot do

| Capability | Result |
|---|---|
| Launch at all (needs embedded `__TEXT,__info_plist` with `CFBundleIdentifier`) | ✅ works |
| `stat` an arbitrary argv path, incl. outside any container | ✅ works |
| Write piped stdin into a shared App Group container | ✅ works |
| **Open an `https://` URL** (scheme-based) | ✅ **works** |
| `NSWorkspace.open(_:withApplicationAt:)` at the enclosing `.app` | ❌ `permErr -54` |
| `/usr/bin/open -a <app path>` (the original implementation) | ❌ `permErr -54` |
| `/usr/bin/open -b <bundle identifier>` | ❌ `permErr -54` |
| `NSWorkspace.open(_:)` on a **file URL**, default handler, no app named | ❌ returns `false` |

The failures are not about paths (same result from `/tmp`, `~/Applications`, `~/Documents`), not
about signing (fails launching Apple-signed `TextEdit.app`), and not about missing file
entitlements (adding `com.apple.security.files.user-selected.read-write` changes nothing).

The distinction that matters: **a sandboxed process may open a URL by scheme, but may not launch an
application or open a file URL.**

## The untested route: a `lineform://` URL scheme

The app registers a custom scheme; the helper opens `lineform://open?path=…` instead of handing
over a file. Scheme opening is permitted from the sandbox, so the app would launch.

**The open question is file access, and it is a real one.** A path delivered through a URL scheme
carries no sandbox extension, so the app has no grant for it — unlike a document opened through
LaunchServices, which is why `open -a` works today. Realistically:

- Files **inside the user's workspace** would work: `OutlineFileBrowserStore` already holds a
  security-scoped bookmark for that folder for its lifetime, so the app can read them.
- Files **outside it** would not, without prompting the user — which defeats the point of a CLI.

So the honest position is that a URL scheme probably rescues the common case (`lineform` on a file
in your workspace) and not the general one. That is a product judgement, not a technical unknown,
and it needs a prototype before anyone commits to it.

Not yet investigated: whether the helper could pass the file's CONTENT through the App Group
container instead of a path. That works for `lineform -` today, but for a named file it would open
a copy rather than the real document, which is wrong for an editor.

## The mistake this document already made once

The first revision claimed **"`lineform file.md` WORKS sandboxed"**, from seeing the helper get
*past* its file-existence check — which proves `stat` succeeded and nothing more. The probe lived
outside an `.app`, so it bailed before reaching the hand-off.

The second revision then claimed the opposite — **impossible** — after four file/app routes failed.
That was also wrong: the routes tested shared an assumption (hand over a file or name an app) and
the untested route does neither.

Both errors have the same shape: generalising from the routes that happened to be tried. Before
concluding "X cannot be done", list what was actually exercised and what that has in common.

## Current state of the code

The sandbox work was reverted. `packaging/build-release.sh` had been changed to sign the helper
sandboxed, which would have shipped a CLI that could not open anything, so the revert was
load-bearing rather than tidying. The helper is back to its proven unsandboxed configuration and
was re-verified end to end (`lineform file.md`, `… | lineform -`, `--version`).

The App Group `group.TV4QZT7A7X.com.lineform` exists in the portal and both provisioning profiles
carry it; the app no longer declares it. Re-adding it needs no portal work.

Worth keeping regardless: a sandboxed bare Mach-O **SIGTRAPs before `main`** without an embedded
`CFBundleIdentifier`, and a sandboxed helper **can** `stat` paths outside its container.
