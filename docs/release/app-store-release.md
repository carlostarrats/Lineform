# Mac App Store release — deploy-day runbook

Everything that only matters on the day Lineform is actually submitted to the Mac App Store.
Nothing here is ongoing work. The one engineering change that must land before this runbook is
useful is removing Sparkle. (A sandboxed `lineform` helper was investigated and abandoned — it
cannot work; see the first precondition.)

Read `docs/postmortems/2026-07-02-launch-brick-and-file-access.md` before touching signing.

## 0. Preconditions — do not start until all are true

- [ ] **DECIDED 2026-07-29: the `lineform` CLI does NOT ship in the App Store build.** Omit
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
- **Diagram failure reporting** — REMOVED 2026-07-29, precisely so this question has a clean answer.
  It was the only feature that transmitted document content off the device.

So the honest answer is **Data Not Collected**, with nothing to argue about: the app has no
account system, no analytics, and no path that sends document content anywhere.

## 4b. Verify at review time

- [ ] **"Install Command Line Tool…" must not appear in an App Store build.** If the CLI is
      omitted (the recommendation above), the menu item has to go with it — an item that installs
      a helper the build does not contain is a broken affordance, and it points at
      `/usr/local/bin`, which review would question anyway.

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
- [ ] **Tear down the diagram-report backend.** It has been dead since 2026-07-29 and nothing in
      the app or the release process calls it, but both pieces are still live: the Cloudflare
      Worker `lineform-diagram-report` (on the `lineform` workers.dev subdomain) and the private
      GitHub repo `carlostarrats/lineform-reports`. Delete the Worker, revoke its `GITHUB_TOKEN`
      secret (a fine-grained PAT scoped to that repo's Issues), and archive or delete the repo.
      Then remove `worker/` from this repository — it is kept only so a deployed service is not
      left without source, so once the service is gone the source has no reason to stay.

## Notes for whoever runs this

- The App Store build and any Direct build share bundle ID `com.lineform.app` and the same iCloud
  container. Do not run-then-delete locally built Release/Export copies while signed into the
  production iCloud account — that is what trips the container uninstall purge.
- A sandboxed binary cannot run under ad-hoc signing at all; it SIGTRAPs before `main`. Anything
  sandboxed is therefore untestable in Debug, which is why the helper keeps a Debug/Release
  entitlement split.
