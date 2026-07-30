# Sandboxed CLI helper — ABANDONED (it cannot work)

**Status: NOT POSSIBLE.** A sandboxed CLI helper cannot hand documents to the app, which is its
entire purpose. Established by experiment on 2026-07-29. Do not retry without reading the
"What was actually tested" section — an earlier revision of this document concluded the opposite
from a partial test and was wrong.

**Consequence: the bundled `lineform` CLI cannot ship in a Mac App Store build.** Every executable
in an App Store bundle must be sandboxed, and this one stops working the moment it is.

## The finding

A sandboxed helper can do almost everything — and then fails at the only step that matters.

| Capability | Sandboxed? |
|---|---|
| Launch at all (needs an embedded `__TEXT,__info_plist`) | ✅ works |
| `stat` an arbitrary argv path, incl. outside any container | ✅ works |
| Write piped stdin into a shared App Group container | ✅ works |
| **Hand a document to the app** | ❌ **blocked** |

Every hand-off route fails identically with `permErr` (`OSStatus -54`):

- `NSWorkspace.open(_:withApplicationAt:)` pointing at the enclosing `.app`
- spawning `/usr/bin/open -a <app path>` (the original implementation)
- spawning `/usr/bin/open -b <bundle identifier>`
- `NSWorkspace.open(_:)` with the **default handler**, naming no app at all

It is not a path problem: it fails with the app in `/tmp`, in `~/Applications`, and with the
document in `~/Documents`. It is not a signing problem: it fails when launching
`/System/Applications/TextEdit.app`, which is signed by Apple. A sandboxed helper simply cannot
launch anything through LaunchServices.

## What was actually tested (and the mistake to avoid)

The first revision of this document claimed **"`lineform file.md` WORKS sandboxed"**. That came
from observing that the sandboxed helper got *past* its file-existence check — which proves `stat`
succeeded and nothing more. The hand-off immediately after it was never exercised, because the
probe binary lived outside an `.app` and bailed earlier for an unrelated reason.

The bug was in the test rig, not the reasoning: a probe that cannot reach the interesting line
cannot tell you anything about it. Verify the step you are actually claiming.

## Options, if the CLI is wanted on the App Store

1. **Ship the CLI only in the Direct build.** Simplest and honest. The App Store build has no
   `Contents/Helpers/lineform`; everything else is unaffected. Note this means going App Store-only
   ends the CLI.
2. **Re-architect around a running app.** The helper writes a request into a shared container and
   signals the app over an App Group Mach service. Does not solve the cold case — with the app not
   running, nothing launches it — so it does not really replace `lineform file.md`.
3. **Temporary-exception entitlements.** Not attempted. Heavily scrutinised at review, and there is
   no reason to believe an exception exists for LaunchServices launches.

Recommendation: **option 1.**

## What was reverted

The sandbox-motivated changes were backed out once the finding landed, because they made things
strictly worse: `packaging/build-release.sh` had been changed to sign the helper sandboxed, which
would have shipped a completely broken CLI in the next Direct release.

Reverted: helper entitlement files, the embedded `Info.plist` section, `NSWorkspace`-based
hand-off, the App Group piped directory, and the app's own `application-groups` entitlement (no
consumer left).

Kept: the App Group **exists** in the portal and both provisioning profiles carry it, so if a use
is ever found no portal work is needed. Also kept is the knowledge that a sandboxed bare Mach-O
SIGTRAPs before `main` without an embedded `CFBundleIdentifier` — true, verified, and useful for
any future sandboxed helper.
