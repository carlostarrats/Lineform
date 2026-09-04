# Mac App Store release runbook

Lineform is distributed through the **Mac App Store only**. The store handles installation and
updates. There is no parallel distribution channel, self-update mechanism, or command-line helper.

This is the complete release path for production builds. Read
`docs/postmortems/2026-07-02-launch-brick-and-file-access.md` before changing signing,
provisioning, iCloud capabilities, or sandbox behavior.

## 0. Preconditions

- [ ] The full default and `LineformHosted` test plans pass serially.
- [ ] A clean Release build succeeds with no compiler warnings.
- [ ] `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, the About panel version, App Store Connect,
      and the Quick Look extension all identify the same release.
- [ ] `ReleaseResourceTests` passes, including the App Store metadata, entitlement, updater-absence,
      print, bundled-resource, and App Intents checks.
- [ ] Localization catalogs parse and all six `.lproj` folders (`en`, `es`, `fr`, `de`, `ja`,
      `zh-Hans`) exist in the built app.
- [ ] The app contains no Mach-O executable other than the main app and its sandboxed Quick Look
      extension.

## 1. App Store metadata

`Lineform/Info.plist` must retain both submission keys:

```xml
<key>LSApplicationCategoryType</key>
<string>public.app-category.productivity</string>
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

The first is the App Store category. The second records that Lineform uses only exempt system
cryptography such as HTTPS. `ReleaseResourceTests.testInfoPlistCarriesAppStoreSubmissionKeys`
guards both.

## 2. Signing and provisioning

Use an **Apple Distribution** certificate and Mac App Store provisioning profiles.

- [ ] The app profile is for `com.lineform.app` and carries CloudDocuments access to
      `iCloud.com.lineform.app`.
- [ ] The Quick Look profile is for `com.lineform.app.quicklook` and matches the extension's own
      sandbox entitlements.
- [ ] No unused App Group or temporary-exception entitlement is present.
- [ ] After any certificate or capability change, confirm the selected certificate is embedded in
      the profile used by the archive.

Xcode can reuse a cached profile after a capability or certificate change. Force a fresh profile
before archiving when either changes, then inspect the archive's embedded profile:

```sh
security cms -D -i "<App>/Contents/embedded.provisionprofile" \
  | plutil -extract Entitlements xml1 -o - -
```

Dump the full entitlement dictionary. Extracting a deeply nested key can return no output and give
a false impression that the profile was checked.

## 3. Archive, validate, and upload

Production submission uses Xcode Archive and Organizer. There is no custom packaging step.

- [ ] Archive from a clean build directory with the App Store profiles.
- [ ] Run **Validate App** in Organizer before upload. This is the gate for an incorrectly signed,
      missing, or unsandboxed nested bundle.
- [ ] Inspect the archived app and confirm
      `Contents/Resources/Metadata.appintents` exists. `AppIntents.framework` must remain linked in
      the app target or Shortcuts, Spotlight, and Siri registration silently disappears.
- [ ] Confirm the Quick Look extension is embedded, version-matched, and signed with its own
      sandbox entitlements.
- [ ] Upload the validated archive to App Store Connect.

Do not call an upload complete merely because processing started. Wait for App Store Connect to
accept the build and show the expected version and build number.

## 4. TestFlight

TestFlight exercises the same sandbox, bundle identifier, iCloud container, and store signing model
that users receive. Use it for release-candidate validation.

This release Mac has the `asc` App Store Connect CLI installed with a keychain-backed profile. Use
it before exporting credentials or falling back to browser-only checks. Never print or commit the
credential.

```sh
asc doctor
asc testflight groups list --app 6800480078 --internal
asc builds list --app 6800480078 --version <version> --build-number <build> --output json
asc builds add-groups --build-id <build-id> --group <internal-group-id>
asc testflight groups links view --group-id <internal-group-id> --type builds --paginate
```

The internal group is **Lineform Internal**. Resolve its opaque ID from App Store Connect each time;
do not hardcode it into documentation or automation.

- [ ] Assign every uploaded build to the intended internal group. Group membership is not inherited
      from the previous build.
- [ ] Verify the association after assigning it.
- [ ] Install the build through TestFlight and launch it.
- [ ] Choose a workspace, quit, relaunch, and open a file from that workspace. A same-session open
      panel grant can hide a broken security-scoped bookmark.
- [ ] With no restored document, verify cold launch and Dock reopen show an untitled editor instead
      of the generic Open browser. Verify the first-launch intro still owns a clean install.
- [ ] Verify File ▸ Open replaces only a pristine untitled tab, opens beside edited/file-backed work
      in the same window, and does not flash or leave a second window behind.
- [ ] Close the opened file, then close an edited untitled final tab. Confirm Save, Cancel, and
      Don't Save each take effect on the first attempt through both ⌘W and the window close button.
- [ ] Open or save a Markdown file, relaunch, and verify the default-app invitation appears once on
      that later launch. Confirm Not Now stays dismissed and Settings keeps the Make Default action.
- [ ] Exercise the iCloud Files root, document autosave, Quick Look, export, and print.

A TestFlight build uses the production bundle ID and iCloud container. Installing it can replace the
store copy. Do not delete it casually while signed into the production iCloud account; deletion can
be interpreted as an uninstall and affect the app's iCloud container.

## 5. App Privacy

The App Privacy answer is **Data Not Collected**:

- Documents remain in user-selected files or the user's own iCloud Drive.
- The app has no account, analytics, telemetry, advertising identifier, or document upload.
- Announcements are an optional once-a-day GET of a static public JSON file. The request has no
  body, query string, identifier, or cookie, and the Settings switch prevents the request itself.
- Diagram failures remain local and cannot be submitted from the app.

Review these facts against the shipping binary whenever a network call, entitlement, or external
service changes.

## 6. Product metadata and review notes

- [ ] Category matches `public.app-category.productivity`.
- [ ] Screenshots, description, keywords, support URL, marketing URL, age rating, and copyright are
      current.
- [ ] Claims match `README.md`, `POSITIONING_AND_MARKETING.md`, bundled Help, and the actual build.
- [ ] Use **free** and **source-available**, never “open source” (PolyForm Shield 1.0.0).
- [ ] Do not describe a CLI or app-managed updates; neither exists.
- [ ] Explain the announcements request if App Review asks why `network.client` is present.

## 7. Post-release checks

- [ ] Confirm the intended build is live on the App Store listing.
- [ ] Confirm `https://lineform.app` points users to the App Store.
- [ ] Install or update from the store on a clean user account and repeat the workspace-relaunch,
      iCloud, Quick Look, export, and print smoke tests.
- [ ] Monitor App Store processing, crash reports, reviews, and the GitHub issue tracker for
      release-specific regressions.

## Persistent cautions

- Every production, TestFlight, and local Release copy shares `com.lineform.app` and
  `iCloud.com.lineform.app`. Avoid install/delete churn while signed into the production iCloud
  account.
- Debug intentionally omits iCloud entitlements so ad-hoc test hosts launch reliably and never
  touch production iCloud data.
- Organizer validation is mandatory after adding an extension, embedded framework, or executable.
