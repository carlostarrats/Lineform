# Mac App Store release — deploy-day runbook

Everything that only matters on the day Lineform is actually submitted to the Mac App Store.
The App Store is now the **only** channel: on 2026-08-06 Sparkle, the `lineform` CLI, and the
entire Direct/DMG path (`packaging/build-release.sh`, `build-dmg.sh`, `notarize-dmg.sh`,
`generate-appcast.sh`, `verify-update.sh`, `docs/appcast.xml`, `docs/release-notes/`, and the
Release Build workflow) were deleted. There is no fallback distribution to fall back to — this
runbook is the release process.

Read `docs/postmortems/2026-07-02-launch-brick-and-file-access.md` before touching signing.

## 0. Preconditions — do not start until all are true

- [x] **DONE 2026-08-06 — the `lineform` CLI is gone from the tree entirely.** (Decided
      2026-07-29.) It does not ship in the App Store build. Originally: omit
      `Contents/Helpers/lineform`, and remove the "Install Command Line Tool…" item from
      `AppCommands.swift` in that build — a menu item installing a helper the bundle does not
      contain is a broken affordance.

      Why: every executable in an App Store bundle must be sandboxed, and a sandboxed helper
      cannot hand a FILE to the app (`NSWorkspace` by app path, `open -a`, `open -b`, and a
      file-URL default-handler open all fail regardless of location, signing, or file
      entitlements). A custom `lineform://` URL scheme WOULD launch the app — scheme opening is
      permitted from the sandbox — but a path delivered that way carries no sandbox extension, so
      the app could only read files inside the workspace folder it already holds a bookmark for.

      That half-working version was considered and **rejected**: a CLI that opens files in one
      folder and silently fails elsewhere is worse than no CLI. Do not re-propose the URL scheme
      as a rescue for this.

      Consequence: going App Store-only ends the CLI. `POSITIONING_AND_MARKETING.md` and the
      website must stop claiming it for any App Store release. Detail:
      `docs/superpowers/specs/2026-07-29-sandboxed-cli-helper-design.md`.

- [x] **DONE 2026-08-06 — Sparkle is gone:** the SPM dependency, `Lineform/App/AppUpdater.swift`, the
      "Check for Updates…" item in `AppCommands.swift`, `SUFeedURL` + `SUPublicEDKey` in
      `Lineform/Info.plist`, and the `com.apple.security.temporary-exception.mach-lookup.global-name`
      pair (`com.lineform.app-spki` / `-spks`) in `Lineform/Lineform.entitlements`.
      Sparkle's `Autoupdate`/`Updater`/`InstallerLauncher` are unsandboxed by design and fail
      upload validation; there is no configuration that fixes it. App Store apps may not ship
      their own update mechanism regardless.
- [ ] Full default test plan green.

## 1. Info.plist keys

**DONE 2026-08-06 — both keys are in `Lineform/Info.plist`**, and
`ReleaseResourceTests.testInfoPlistCarriesAppStoreSubmissionKeys` fails if either goes missing.
Neither has any effect on a local build, which is why nothing else would notice.

```xml
<key>LSApplicationCategoryType</key>
<string>public.app-category.productivity</string>   <!-- submission is REJECTED without this -->
<key>ITSAppUsesNonExemptEncryption</key>
<false/>   <!-- HTTPS + system crypto only; without it every submission asks the export question -->
```

## 2. Signing — a separate track from Developer ID

Developer ID certificates **do not work** for the App Store.

- [ ] Create an **Apple Distribution** certificate.
- [ ] Create a **Mac App Store** provisioning profile for `com.lineform.app`, carrying the
      capabilities the app actually declares: **iCloud** (CloudDocuments +
      `iCloud.com.lineform.app`). The App Group `group.TV4QZT7A7X.com.lineform` exists on the App
      ID but the app no longer declares it — it was added for the abandoned sandboxed helper. Do
      not add an entitlement the app does not use; unused entitlements get questioned at review.
- [ ] Same for the Quick Look extension, `com.lineform.app.quicklook` — it is an embedded target
      with its own sandbox entitlements and needs its own profile.

**The gate that matters.** After any certificate or capability change, verify the signing cert is
actually embedded in the profile before shipping. This is the exact failure that shipped as the
1.1.0 launch brick: entitlement present in the signature, absent from the profile → passes
codesign, notarization and Gatekeeper, then AMFI SIGKILLs the app at launch on every machine.

Xcode will happily reuse a **cached** profile and produce exactly that mismatch — it did on
2026-07-29 when the App Group was added. If a capability changed, clear the cache and force a
fresh fetch:

```sh
# back up first
cp ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile /tmp/profile-backup/
# delete only the Lineform ones, then re-archive with -allowProvisioningUpdates
```

Then confirm the profile actually contains what you expect:

```sh
security cms -D -i "<App>/Contents/embedded.provisionprofile" \
  | plutil -extract Entitlements xml1 -o - -
```

`plutil -extract Entitlements.com\.apple\.security\.application-groups` silently returns nothing
for these keys — dump the whole Entitlements dict and read it, or you will "verify" a profile that
does not contain the capability.

## 3. Build and submit

Submission goes through Xcode archive → Organizer (or `altool`/`notarytool` equivalents). There
is no build script: `packaging/build-release.sh` and the rest of the Developer ID + DMG + notarize
+ staple chain were deleted with Direct distribution. `packaging/` now holds only the two
localization extraction scripts.

The gates those scripts enforced do not disappear, they move. Cert-in-provisioning-profile is §2
above. The clean-build rule (never archive over a stale `Lineform.app`) is now yours to keep by
hand. Nested-bundle signing is caught by Organizer's Validate App rather than by a hand-rolled
re-sign list.

- [ ] `xcodebuild archive` with the App Store profile.
- [ ] Validate in Organizer before uploading — this is where an unsandboxed nested binary is caught.
- [ ] Verify `Contents/Resources/Metadata.appintents` exists in the archived app.
      `AppIntents.framework` must stay LINKED in the app target's Frameworks phase; `import
      AppIntents` alone emits nothing and the Shortcuts/Spotlight/Siri actions silently never
      register. This already shipped broken once.

## 3b. TestFlight — testing the build you actually upload

TestFlight supports Mac apps, and it is the only way to run Lineform in the configuration the
store will ship: sandboxed, signed by Apple, against the Mac App Store provisioning profile. A
Direct build cannot tell you any of that. Same upload feeds both TestFlight and the store — there
is no separate beta build.

- [ ] **Validate in Organizer first** (§3). It is the cheap gate: an unsandboxed nested binary —
      Sparkle's XPC services, `Contents/Helpers/lineform` — fails there, before an upload is
      spent. TestFlight cannot tell you anything about the preconditions in §0; those must
      already be done or the archive will not validate.
- [ ] Add yourself as an **internal tester** (App Store Connect users on the team; up to 100, 30
      devices each). Internal builds need **no Beta App Review** and appear minutes after
      processing. External testing (up to 10,000) needs review on the first build and is not
      worth the wait for self-testing.
- [ ] Testers install the **TestFlight app from the Mac App Store** (requires macOS 12+; the
      deployment target is 14.0, so every supported Mac qualifies), then install Lineform from it.
- [ ] Builds **expire after 90 days**.

**What to actually exercise.** "It launches" is not "it works" — the same rule as the Direct
release. The sandbox and bookmark paths are what a TestFlight build exists to prove: open a
workspace folder, quit, relaunch, and open a file from that folder again (a same-session
`NSOpenPanel` grant hides bookmark bugs). Then check the Files sidebar's iCloud root, since the
App Store profile is where the iCloud entitlement is first exercised for real. See
`docs/postmortems/2026-07-02-launch-brick-and-file-access.md`.

**The iCloud caveat is the same one as everywhere else, and it bites here.** A TestFlight build
carries bundle ID `com.lineform.app` and the same `iCloud.com.lineform.app` container as the
Direct build — installing it replaces the local copy, and *deleting* it afterwards is exactly the
uninstall signal that trips the app-container purge. Do not run-then-delete TestFlight builds
while signed into the production iCloud account.

## 4. App Privacy questionnaire

Answer honestly against what the app *can* transmit, not how often it does.

- **Announcements** — collects nothing. A plain GET of a static public file: no request body, no
  query string, no identifiers, no cookies, ephemeral session. Not a disclosure.
- **iCloud documents** — the user's own iCloud Drive, not a developer-operated service. Not a
  disclosure.
- **Diagram failure reporting** — REMOVED 2026-07-29, precisely so this question has a clean answer.
  It was the only feature that transmitted document content off the device.

So the honest answer is **Data Not Collected**, with nothing to argue about: the app has no
account system, no analytics, and no path that sends document content anywhere.

## 4b. Verify at review time

- [x] **DONE 2026-08-06 — "Install Command Line Tool…" is gone from the app menu**, along with
      "Check for Updates…". Neither the item nor the helper it installed exists any more. (It
      pointed at `/usr/local/bin`, which review would have questioned regardless.)

## 5. Metadata

App record, category (matching `LSApplicationCategoryType`), macOS screenshots, description,
keywords, support URL, marketing URL, age rating, copyright.

Keep claims consistent with `POSITIONING_AND_MARKETING.md`: **free** and **source-available**
(never "open source" — PolyForm Shield 1.0.0), "No AI inside" is accurate and intentional, and
only Atkinson Hyperlegible + OpenDyslexic are bundled fonts. **Never describe a CLI or in-app
updates** — neither exists any more, and that doc's older CLI copy is stale (it is untracked, so
release tooling never corrects it).

## 6. After it ships

- [ ] **Point the website at the App Store listing, and take down the DMG download.** This is the
      only remaining path for a new user to get the app — `docs/appcast.xml` is deleted, so every
      copy of Lineform already installed from a DMG will check for updates once, get nothing, and
      stay on its current version forever. Those users are only reachable through the website and
      whatever channels you announce on. (The README carries no download links by design — see
      `Claude.md` ▸ Documentation Expectations — so there is nothing to update there.)
- [ ] Consider whether the existing GitHub Releases and their DMG assets stay up. They still work
      as downloads and are now the only thing contradicting "the App Store is the only channel."
- [ ] **Revoke or retire the Sparkle EdDSA private key** (it signed the appcast; nothing signs
      anything now) and the `SPARKLE_PUBLIC_ED_KEY` GitHub Actions secret, which no workflow reads.
- [ ] Developer ID is the only way to hand someone an arbitrary build, and it no longer has a
      script. TestFlight (§3b) replaces it only for registered testers, only for builds that
      already passed store validation, and only for 90 days at a time.
- [ ] **Tear down the diagram-report backend.** It has been dead since 2026-07-29 and nothing in
      the app or the release process calls it, but both pieces are still live: the Cloudflare
      Worker `lineform-diagram-report` (on the `lineform` workers.dev subdomain) and the private
      GitHub repo `carlostarrats/lineform-reports`. Delete the Worker, revoke its `GITHUB_TOKEN`
      secret (a fine-grained PAT scoped to that repo's Issues), and archive or delete the repo.
      Then remove `worker/` from this repository — it is kept only so a deployed service is not
      left without source, so once the service is gone the source has no reason to stay.

## Notes for whoever runs this

- Every build — App Store, TestFlight, and any local Release/Export copy — shares bundle ID
  `com.lineform.app` and the same iCloud container. Do not run-then-delete locally built copies while signed into the
  production iCloud account — that is what trips the container uninstall purge.
- A sandboxed binary cannot run under ad-hoc signing at all; it SIGTRAPs before `main`. Anything
  sandboxed is therefore untestable in Debug, which is why the helper keeps a Debug/Release
  entitlement split.
