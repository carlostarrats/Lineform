# Mac App Store release — deploy-day runbook

Everything that only matters on the day Lineform is actually submitted to the Mac App Store.
Nothing here is ongoing work; the engineering changes that must land *before* this runbook is
useful are tracked separately (the sandboxed CLI helper, and removing Sparkle).

Read `docs/postmortems/2026-07-02-launch-brick-and-file-access.md` before touching signing.

## 0. Preconditions — do not start until all are true

- [x] **The bundled `lineform` helper is sandboxed.** DONE 2026-07-29, and verified against a real
      Developer ID-signed sandboxed binary: it launches (which requires the embedded
      `__TEXT,__info_plist` — without a bundle identity it SIGTRAPs before `main`), it stats
      arbitrary argv paths so `lineform file.md` works, and piped stdin lands in the shared App
      Group container where the app can read it. Entitlements: `HelperTool/HelperTool.entitlements`
      (Release, sandbox + group) and `HelperTool/HelperToolDebug.entitlements` (Debug, empty —
      ad-hoc signing cannot satisfy a sandbox entitlement).

- [ ] **The helper is an Xcode TARGET.** STILL OUTSTANDING — this is the one piece of the helper
      work not done. An App Store archive contains only binaries Xcode built, and today
      `packaging/build-release.sh` compiles the helper with `swiftc` *after* `xcodebuild`, so it
      would simply be absent from an archive.

      Deferred on purpose: adding the target means `build-release.sh` must stop compiling and
      signing the helper, which changes the working Direct release path. Do this **together with
      the Sparkle removal below**, when that path is being reworked anyway, rather than
      destabilising a shipping pipeline for a submission that has not been scheduled.

      What it involves: a `PBXNativeTarget` in the hand-rolled pbxproj (no synced groups — see the
      existing sequential `1F0000xx` ID convention), its own build-configuration list pointing at
      the two entitlement files, `OTHER_LDFLAGS` carrying the
      `-sectcreate __TEXT __info_plist HelperTool/HelperToolInfo.plist` that the sandbox depends
      on, a Copy Files phase on the app target writing into `Contents/Helpers`, a target
      dependency so it builds first, and deleting the `swiftc`/`lipo`/`codesign` block from
      `build-release.sh`. Keep the universal (arm64 + x86_64) requirement — the script asserts it
      today and the target must too.
- [ ] Sparkle is gone: the SPM dependency, `Lineform/App/AppUpdater.swift`, the
      "Check for Updates…" item in `AppCommands.swift`, `SUFeedURL` + `SUPublicEDKey` in
      `Lineform/Info.plist`, and the `com.apple.security.temporary-exception.mach-lookup.global-name`
      pair (`com.lineform.app-spki` / `-spks`) in `Lineform/Lineform.entitlements`.
      Sparkle's `Autoupdate`/`Updater`/`InstallerLauncher` are unsandboxed by design and fail
      upload validation; there is no configuration that fixes it. App Store apps may not ship
      their own update mechanism regardless.
- [ ] Full default test plan green.

## 1. Info.plist keys

Two keys are missing and both are required or strongly wanted. They are harmless in the current
Direct build, so they can land any time before submission.

```xml
<key>LSApplicationCategoryType</key>
<string>public.app-category.productivity</string>   <!-- submission is REJECTED without this -->
<key>ITSAppUsesNonExemptEncryption</key>
<false/>   <!-- HTTPS + system crypto only; without it every submission asks the export question -->
```

## 2. Signing — a separate track from Developer ID

Developer ID certificates **do not work** for the App Store.

- [ ] Create an **Apple Distribution** certificate.
- [ ] Create a **Mac App Store** provisioning profile for `com.lineform.app`, carrying the same
      capabilities the app already declares: **iCloud** (CloudDocuments +
      `iCloud.com.lineform.app`) and **App Groups** (`group.TV4QZT7A7X.com.lineform`).
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

Submission goes through Xcode archive → Organizer (or `altool`/`notarytool` equivalents), **not**
`packaging/build-release.sh`. That script and most of its gates are for Developer ID + DMG +
notarize + staple, none of which apply here.

- [ ] `xcodebuild archive` with the App Store profile.
- [ ] Validate in Organizer before uploading — this is where an unsandboxed nested binary is caught.
- [ ] Verify `Contents/Resources/Metadata.appintents` exists in the archived app.
      `AppIntents.framework` must stay LINKED in the app target's Frameworks phase; `import
      AppIntents` alone emits nothing and the Shortcuts/Spotlight/Siri actions silently never
      register. This already shipped broken once.

## 4. App Privacy questionnaire

Answer honestly against what the app *can* transmit, not how often it does.

- **Announcements** — collects nothing. A plain GET of a static public file: no request body, no
  query string, no identifiers, no cookies, ephemeral session. Not a disclosure.
- **iCloud documents** — the user's own iCloud Drive, not a developer-operated service. Not a
  disclosure.
- **Diagram failure reporting — this one needs a decision.** `DiagramReportService` POSTs
  `{source, error, appVersion}` to a Cloudflare Worker, where `source` is the user's Mermaid
  diagram, i.e. document content leaving the device. It is user-initiated and confirmed, which is
  good practice, but it is still a transmission the label must reflect. Either:
  1. declare it — **Other User Content**, *not linked* to identity, purpose **App Functionality**; or
  2. cut the feature from the App Store build, keeping the local diagram log and the clean
     "Data Not Collected" label.

  Do not declare "Data Not Collected" while shipping option 1's code.

## 4b. Verify at review time

- [ ] **The "Install Command Line Tool…" flow.** It writes a symlink to `/usr/local/bin/lineform`
      through an `NSSavePanel`, i.e. a user-selected destination rather than a programmatic write,
      so it does not obviously need `com.apple.developer.security.privileged-file-operations`.
      Whether review accepts it for that location is unverified. If rejected, replace it with a
      panel showing the bundled helper's path plus a copyable `ln -s` command — a small change,
      deliberately not made pre-emptively.

## 5. Metadata

App record, category (matching `LSApplicationCategoryType`), macOS screenshots, description,
keywords, support URL, marketing URL, age rating, copyright.

Keep claims consistent with `POSITIONING_AND_MARKETING.md`: **free** and **source-available**
(never "open source" — PolyForm Shield 1.0.0), "No AI inside" is accurate and intentional, and
only Atkinson Hyperlegible + OpenDyslexic are bundled fonts. Do not describe the CLI without
checking what the submitted build actually ships.

## 6. After it ships

- [ ] Decide what happens to Direct distribution. If it ends, the appcast, EdDSA keys,
      `verify-update.sh`, the Developer ID cert gates and DMG packaging all retire with it —
      and `CLAUDE.md`'s Release Verification Gates section should shrink to match.
- [ ] Update README download links and the website to point at the App Store.
- [ ] Drop the Sparkle credit from public docs once Sparkle is actually gone.

## Notes for whoever runs this

- The App Store build and any Direct build share bundle ID `com.lineform.app` and the same iCloud
  container. Do not run-then-delete locally built Release/Export copies while signed into the
  production iCloud account — that is what trips the container uninstall purge.
- A sandboxed binary cannot run under ad-hoc signing at all; it SIGTRAPs before `main`. Anything
  sandboxed is therefore untestable in Debug, which is why the helper keeps a Debug/Release
  entitlement split.
