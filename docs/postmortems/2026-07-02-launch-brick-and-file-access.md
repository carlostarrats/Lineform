# Postmortem: 1.1.0 launch brick + workspace file-access bug (2026-07-02/03)

> **Historical incident record.** Incident 1 occurred under Lineform's retired direct-download
> distribution model. Its Developer ID, disk-image, appcast, and self-update details describe what
> happened in 2026; they are not release instructions. Lineform now ships only through the Mac App
> Store. Use `docs/release/app-store-release.md` for every current release.

Two production defects shipped and were fixed in one night. This document exists so no
agent or human repeats either failure class. Read it before changing release signing,
provisioning profiles, certificates, or sandbox/bookmark code.

## Incident 1 — 1.1.0 build 14 would not launch on any Mac

**Symptom:** "The application 'Lineform' can't be opened." Instant SIGKILL at spawn
(`open` → RBSRequestErrorDomain 5 / POSIX 163 "Launchd job spawn failed", exit 137).
No crash report, no dialog detail, nothing in the app's own logs.

**Root cause:** the release was signed with a Developer ID certificate
(`6244C0B6…D407`, created Jun 15) that was **not embedded in the app's provisioning
profile** (created Jun 2, embedding only the older `300C2245…E241` + `9D0BD477…DF30`).
The app carries restricted iCloud entitlements, which AMFI only honors when the signing
cert appears in the profile's `DeveloperCertificates`. Mismatch ⇒ the kernel kills the
process at exec.

**Why nothing caught it:** `codesign --verify --deep --strict` passes, **notarization
passes**, and Gatekeeper says "accepted — Notarized Developer ID". None of them check
cert↔profile matching. The only test that catches it is *launching the packaged app*,
which the release process did not do.

**How the mismatch happened:** two same-named Developer ID certs caused a
`codesign … ambiguous` error during the 1.1.0 build. The fix chosen was deleting the
"duplicate" from the keychain — but the deleted cert was the only one the profile
authorized, and its private key went with it. The survivor signs and notarizes fine and
looks identical (same subject, same team), so nothing flagged the swap.

**Fix:** regenerated the Xcode-managed Direct profile headlessly
(`xcodebuild archive` + `-exportArchive`, method `developer-id`, signingStyle
`automatic`, `-allowProvisioningUpdates` — no developer.apple.com visit needed),
re-shipped as 1.1.0 **build 15**, pulled the broken DMG/appcast entry the same night.

**Current lesson:** after any certificate, profile, entitlement, or capability change, verify that
the archive uses the intended App Store profile and that the profile authorizes every restricted
entitlement. Then validate in Organizer and launch the uploaded build through TestFlight. A passing
compile or signature check does not prove that the executable can launch under the production
sandbox. Avoid advising users to delete the app as a generic repair step because deletion can be
interpreted as an uninstall for its iCloud container.

## Incident 2 — workspace file opens failed after relaunch ("you don't have permission")

**Symptom:** clicking a file under a user-added workspace folder in the Files sidebar
fails with *"…couldn't be opened because you don't have permission to view it."* Always
after an app relaunch; same-session opens right after choosing the folder work.

**Root cause:** `OutlineFileBrowserStore` resolved the workspace's security-scoped
bookmark but called `startAccessingSecurityScopedResource()` only transiently around the
directory scan, stopping it immediately. File reads (NSDocumentController open, live
reload) then ran with **no active sandbox grant**. Same-session opens masked the bug
because a fresh NSOpenPanel selection carries an implicit grant that lasts the session —
so casual testing always looked fine, and the failure only appeared after relaunch, when
the bookmark is the *only* carrier of access. The bug shipped in every version through
1.1.0.

**Fix (1.1.1 build 16):** the store begins the workspace scope when the bookmark
resolves (or the workspace changes) and **holds it until the workspace changes or the
store deinits**, balancing every begin with an end. Scope activation is behind the
`SecurityScopedResourceAccessing` protocol so tests assert the lifecycle
(`OutlineSidebarViewTests`: begun once at init, never ended by re-scans, released
exactly once on deinit).

**Do not do again:**
- Never treat a transient start/stop around a directory scan as sufficient for a
  security-scoped folder the user will read files from. Hold the scope for the lifetime
  of the working set; balance begin/end.
- When testing sandboxed file access, test the **relaunch path** — the session grant
  from NSOpenPanel hides bookmark bugs completely.

## Process lessons (both incidents)

1. **"It launches" is not "it works", and "tests pass" is not "the user's flow works".**
   Build 14 passed every static check and was dead on arrival; the file-access bug
   coexisted with a fully green suite for the app's entire life. Every release must validate the
   archive, launch the TestFlight build, and open a real document from a workspace folder after a
   relaunch.
2. **Profile authorization is distinct from code signing.** Verify restricted entitlements against
   the embedded profile after certificate or capability changes; do not infer authorization from a
   successful build.
3. **Dev-machine noise can mask or mimic product bugs.** Launching many re-signed app
   copies churns the shared sandbox container and TCC state; command-line XCTest runs re-prompt for
   Documents access (ad-hoc re-signing). Distinguish machine-local damage from shipped
   defects before concluding either way — in this incident the machine damage and a
   real shipped bug were *both* present.
