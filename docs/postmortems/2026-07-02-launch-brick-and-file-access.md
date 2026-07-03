# Postmortem: 1.1.0 launch brick + workspace file-access bug (2026-07-02/03)

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

**Do not do again / gates added (do not remove):**
- `packaging/build-release.sh` fails (exit 68) if the signing cert's SHA-1 is not in the
  embedded profile's `DeveloperCertificates`.
- `packaging/build-release.sh` launches the packaged app once after signing and fails
  (exit 69) if launchd refuses to spawn it or it dies within 3s.
- After ANY certificate change (renewal, dedupe, new machine), re-check the profile
  embeds the surviving cert BEFORE the next release. Never *revoke* a Developer ID cert
  on the Apple portal (OCSP can kill already-shipped builds); deleting from the local
  keychain is safe for shipped apps but remember the profile may still reference it.
- Bricked users cannot be rescued via Sparkle (the app can't run to check for updates).
  Release-page instructions must say: re-download and **replace the app in place** —
  never "delete and reinstall" (deleting can trigger the iCloud container purge).

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
   coexisted with a fully green suite for the app's entire life. Every release must
   exercise the real flows: launch the packaged app, open a real document from a
   workspace folder after a relaunch, run `packaging/verify-update.sh`.
2. **The update path has its own failure modes** (EdDSA key mismatch ⇒ every update
   rejected; bad delta ⇒ failed updates; signature computed before stapling ⇒ length/sig
   mismatch). `packaging/verify-update.sh` gates all of these headlessly — run it after
   appcast generation, before publishing. Regenerate the appcast **after**
   `stapler staple` (stapling changes the DMG bytes).
3. **`generate_appcast` rewrites every entry's enclosure URL with one prefix**, 404ing
   old versions whose assets live on their own tags. Hand-merge only the new top item
   into `docs/appcast.xml`; keep per-tag URLs for history.
4. **Dev-machine noise can mask or mimic product bugs.** Launching many re-signed app
   copies churns the shared sandbox container and TCC state; CLI test runs re-prompt for
   Documents access (ad-hoc re-signing). Distinguish machine-local damage from shipped
   defects before concluding either way — in this incident the machine damage and a
   real shipped bug were *both* present.
