# App Store release runbook

Lineform is distributed through the **App Store only**: the Mac app and the iPhone app share one
listing. The store handles installation and updates. There is no parallel distribution channel,
self-update mechanism, or command-line helper. Sections 0–7 are the Mac release; the iPhone release
is [§ iPhone](#iphone), after them.

This is the complete release path for production builds. Read
`docs/postmortems/2026-07-02-launch-brick-and-file-access.md` before changing signing,
provisioning, iCloud capabilities, or sandbox behavior.

## Owner step, one time only: add the iPhone app to the listing

The iPhone app (`LineformiOS` target) ships in the same App Store listing as the Mac app, with the
same bundle ID, `com.lineform.app`. Before the first iPhone build is uploaded, the account owner
does these two things once. Neither can be done from the repository.

1. **App Store Connect: add the iOS platform to the existing app record.**
   - Open App Store Connect › Apps › Lineform.
   - Next to the macOS platform in the sidebar, choose **Add Platform** (the **+**), then **iOS**.
   - Do not create a new app record. The iPhone app uses the same record and the same bundle ID.
2. **Developer account: enable iCloud Documents for `com.lineform.app` on iOS.**
   - Open developer.apple.com › Certificates, Identifiers & Profiles › Identifiers ›
     `com.lineform.app`.
   - Confirm the **iCloud** capability is on, with iCloud Documents (CloudKit) support, and that
     the container `iCloud.com.lineform.app` is assigned. The Mac app already uses this
     identifier and container; the iOS app needs the same settings.
   - Save. Then create (or let Xcode create) an **iOS App Store** provisioning profile for
     `com.lineform.app`. Dump its whole `Entitlements` dictionary (see §2) and confirm it lists
     `iCloud.com.lineform.app` as an iCloud container and `CloudDocuments` as an iCloud service.

After these steps, archive the iPhone app from the `LineformiOS` scheme with its iOS profile and
upload it to the same app record. The iOS Release target uses Automatic signing with team
`TV4QZT7A7X`. Its version and build number are the Mac's (`MARKETING_VERSION`,
`CURRENT_PROJECT_VERSION`).

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
- [ ] On macOS 27 or later, switch repeatedly between every Reading Experience theme, including
      several light ↔ Quiet transitions. Confirm the editor, toolbar, tabs, and Files sidebar stay
      responsive, CPU returns to idle, and memory does not grow continuously. This catches the
      `NSHostingView`/AppKit appearance-authority loop that shipped in 1.7.2.
- [ ] Run the automated macOS 27 real-window gate before archiving. It performs 300 theme changes
      across Write, Read, and Split with the tab bar, Files sidebar, and Reading inspector active;
      it fails on stalled progress, more than 192 MiB of post-warmup resident-memory growth, or a
      process that does not return near idle. The test skips on older macOS versions because they
      use the separate explicit-AppKit appearance path:

      ```sh
      xcodebuild test \
        -project Lineform.xcodeproj \
        -scheme Lineform \
        -testPlan LineformHosted \
        -destination 'platform=macOS' \
        -parallel-testing-enabled NO \
        -only-testing:LineformTests/EditorDrawerMotionHostedTests/testThemeSwitchStressAcrossEditorSurfacesStaysResponsiveAndResourceBoundedOnMacOS27
      ```

      Keep the resulting `Theme switch stress metrics` XCTest attachment with the release evidence.
- [ ] Install the build through TestFlight and launch it.
- [ ] Choose a workspace, quit, relaunch, and open a file from that workspace. A same-session open
      panel grant can hide a broken security-scoped bookmark.
- [ ] With no restored document, verify cold launch's first visible Lineform window is the untitled
      editor — the generic Open browser must not flash first. Verify Dock reopen behaves the same
      way without an edge/shadow pulse, and the first-launch intro still owns a clean install.
- [ ] Verify File ▸ Open replaces only a pristine untitled tab, opens beside edited/file-backed work
      in the same window, and does not flash or leave a second window behind.
- [ ] Close the opened file, then close an edited untitled final tab. Confirm Save, Cancel, and
      Don't Save each take effect on the first attempt through both ⌘W and the window close button.
- [ ] Open or save a Markdown file, relaunch, and verify the default-app invitation appears once on
      that later launch. Confirm Not Now stays dismissed and Settings keeps the Make Default action.
- [ ] Exercise the iCloud Files root, document autosave, Quick Look, export, and print.
- [ ] Do not treat the absence of the App Store rating sheet as a TestFlight defect: StoreKit
      suppresses review prompts in TestFlight. In a local Debug build, launch with
      `LINEFORM_FORCE_REVIEW_PROMPT=1` and verify the QA trace reaches `requesting StoreKit system
      sheet` over an unobstructed editor after the four-second quiet period, then does not request
      again for that app version. Inspect the system sheet in an Xcode development run; StoreKit
      can suppress the UI for a standalone ad-hoc launch. Never replace it with a custom pre-prompt.

A TestFlight build uses the production bundle ID and iCloud container. Installing it can replace the
store copy. Do not delete it casually while signed into the production iCloud account; deletion can
be interpreted as an uninstall and affect the app's iCloud container.

## 5. App Privacy

The App Privacy answer is **Data Not Collected**:

- Documents remain in user-selected files or the user's own iCloud Drive.
- The app has no account, analytics, telemetry, advertising identifier, or document upload.
- Announcements are an optional once-a-day GET of a static public JSON file. The request has no
  body, query string, identifier, or cookie, and the Settings switch prevents the request itself.
- Check for Updates is a user-initiated GET of
  `https://itunes.apple.com/lookup?bundleId=com.lineform.app&entity=macSoftware`, made only when the
  user chooses Lineform ▸ Check for Updates…. It uses an ephemeral session with no cookies and no
  identifier, and nothing from it is stored, so Data Not Collected stands.
- Diagram failures remain local and cannot be submitted from the app.
- **Bring-your-own AI does not change this answer (checked 2026-11-12).** With an AI
  connected, the prose of a selection the writer acts on goes from the writer's Mac DIRECTLY to the
  provider the writer chose (Anthropic, OpenAI, Google, or an address they typed — often a model on
  their own Mac), under the writer's own account, API key, and contract with that provider. The
  developer receives nothing: there is no Lineform server, proxy, relay, SDK, or analytics on that
  path; the provider is not a "third-party partner", which Apple's App Privacy details page defines
  as "analytics tools, advertising networks, third-party SDKs, or other external vendors whose code
  you've added to your app" — Lineform adds no provider code (raw `URLSession` HTTP, no SDK), has no
  agreement or shared account with any provider, and never sees or pays for the traffic; the key is
  in the writer's Keychain. ("Collect" is defined there as "transmitting data off the device in a way
  that allows you and/or your third-party partners to access it for a period longer than what is
  necessary to service the transmitted request in real time" — checked 2026-11-12.) Nothing is sent unless
  the writer connected AND chose an action. That is the same shape as a mail or browser client
  sending to a server the user configured, which is not collection by the app's developer.
  **Owner check:** this reasoning is sound but it is a judgement, not a quote of an Apple ruling on
  BYO-key AI. If App Review or Apple's App Privacy FAQ ever treats a user-configured third-party AI
  as the developer's "third-party partner", the answer would become "User Content — Other User
  Content, not linked, not used for tracking, App Functionality". Re-read Apple's App Privacy
  details page before each submission that touches the AI path.

Review these facts against the shipping binary whenever a network call, entitlement, or external
service changes.

## 6. Product metadata and review notes

- [ ] Category matches `public.app-category.productivity`.
- [ ] Screenshots, description, keywords, support URL, marketing URL, age rating, and copyright are
      current.
- [ ] Claims match `README.md`, `POSITIONING_AND_MARKETING.md`, bundled Help, and the actual build.
- [ ] Use **free** and **source-available**, never “open source” (PolyForm Shield 1.0.0).
- [ ] Do not describe a CLI or app-managed updates; neither exists.
- [ ] Explain the announcements request and the user-initiated Check for Updates lookup if App
      Review asks why `network.client` is present.
- [ ] Claims say "No AI built in. Connect your own if you want it." — never "no AI" or "No AI
      inside" (bring-your-own AI ships).
- [ ] **App Review 5.1.2(i) — third-party AI (checked 2026-11-12).** Wording checked at
      `https://developer.apple.com/app-store/review/guidelines/`: "You must clearly disclose where
      personal data will be shared with third parties, including with third-party AI, and obtain
      explicit permission before doing so." Lineform meets it this way:
      - **Disclosure + permission = the Connect button.** Its label names what and to whom —
        "Connect — Lineform will send the text you choose to Anthropic" (OpenAI / Google / the typed
        host) — directly above the privacy note: "Lineform sends only the text you act on, only when
        you choose an AI action, directly to the provider you connected, under your account and that
        provider's terms. Lineform's developer receives nothing." Clicking it (or Return in a field)
        is the explicit, prior, informed act. It is translated in every shipped language.
      - **Nothing is shared before it.** No request at launch, on opening the window, or on Connect
        itself (the key is not tested). AI menu items do not exist until connected.
      - **Each send is user-initiated.** A request happens only when the writer selects text and
        chooses Rewrite / Proofread / Mark, or sends a comment from the selection toolbar, and only that
        selection's prose (plus the comment the writer typed) is sent. Bundled
        Privacy.md and Help.md describe what, to whom, when, the Keychain, and Disconnect.
      - **Conclusion:** no per-action prompt is required by the text of 5.1.2(i); the guideline asks
        for clear disclosure and explicit permission *before* sharing, which the consent label gives
        once per provider, and each action is itself the writer's choice. Do NOT shorten the label
        to a bare "Connect". If App Review asks for more (e.g. a per-action confirmation), bring it
        to the owner — do not add UI on review feedback alone.
      - **Review note to paste:** "Lineform has no built-in AI. Optionally, the user can connect
        their own AI provider (Lineform ▸ Connect Your AI…) with their own API key, stored in the
        Keychain. The Connect button states which company will receive the text. Nothing is sent on
        connect. Afterwards, only the prose of a selection the user chooses an AI action for (from the
        right-click menu, or the selection toolbar's comment card, with the comment the user typed)
        is sent, directly from the Mac to that provider; the developer operates no
        server and receives nothing. To test without an account, choose Other and point it at a
        local OpenAI-compatible server (e.g. Ollama at http://localhost:11434/v1)."

## 7. Post-release checks

- [ ] Confirm the intended build is live on the App Store listing.
- [ ] Confirm `https://lineform.app` points users to the App Store.
- [ ] Install or update from the store on a clean user account and repeat the workspace-relaunch,
      iCloud, Quick Look, export, and print smoke tests.
- [ ] Monitor App Store processing, crash reports, reviews, and the GitHub issue tracker for
      release-specific regressions.

## iPhone

The iPhone app (`LineformiOS` scheme) is a second platform on the same App Store record, with the
same bundle ID (`com.lineform.app`), version and build number as the Mac app. Do the one-time owner
steps at the top of this page first. Everything in "Persistent cautions" below applies to the
iPhone too: a TestFlight or store copy uses the production iCloud container.

### i. Preconditions

- [ ] The `LineformiOS` suite passes on a simulator:
      `xcodebuild test -project Lineform.xcodeproj -scheme LineformiOS -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.5'`.
- [ ] `PhoneReleaseResourceTests` passes. It pins the submission keys
      (`LSApplicationCategoryType`, `ITSAppUsesNonExemptEncryption`), file sharing and the document
      types, the iCloud container declaration, the ATS rule (at most `NSAllowsLocalNetworking`), the
      absence of any `NS…UsageDescription`, the privacy manifest, the compiled icon, and that the
      Mac app, its Quick Look extension and the iPhone app carry one `MARKETING_VERSION` and one
      `CURRENT_PROJECT_VERSION` in Debug and Release.
- [ ] The Mac release for the same version is ready, or the version is bumped for both. One
      listing means one version: never bump only one target.

### ii. Privacy manifest

`LineformiOS/PrivacyInfo.xcprivacy` (iPhone only; the Mac ships none). No tracking, no tracking
domains, no collected data types, and these required-reason APIs:

| Category | Reasons | Why |
|---|---|---|
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` | Settings, reading profiles, the Files sort, the first-run flag: the app's own defaults, no App Group. |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` | Modification dates of files in the app's Documents folder and its iCloud container (live reload, image cache keys, the Files list). |
| | `3B52.1` | The same for a document or Workspace folder the writer picked in Files. |
| | `DDA9.1` | The Files list shows a file's created or modified date when sorted by date. |

How it was settled (2026-11-23): `LineformiOS/`, `Packages/LineformCore/Sources`, and the
statically linked BeautifulMermaid 1.0.4, elk-swift 1.0.2 and SwiftMath 1.7.3 were searched for
`UserDefaults`, file timestamps (`modificationDate`, `creationDate`, `contentModificationDate`,
`attributesOfItem`, `stat`), boot time (`systemUptime`, `mach_absolute_time`,
`CACurrentMediaTime`), disk space (`volumeAvailableCapacity`, `systemFreeSize`, `statfs`) and active
keyboards (`activeInputModes`). Only the first two categories occur, and none in the three
packages (which ship no manifest of their own). Search again when a dependency moves or a feature
reads one of these APIs, and update the manifest and its test together.

### iii. Archive and validate

```sh
xcodebuild -project Lineform.xcodeproj -scheme LineformiOS -configuration Release \
  -destination 'generic/platform=iOS' archive \
  -archivePath ~/Desktop/LineformiOS-<version>-<build>.xcarchive
```

- [ ] Open the archive in Organizer and run **Validate App** with the iOS App Store profile. It is
      the gate for a wrong profile, a missing entitlement, or a bad icon.
- [ ] Dump the embedded profile's whole `Entitlements` dictionary and read it (never extract one
      dotted key; see §2):

      ```sh
      security cms -D -i "<archive>/Products/Applications/LineformiOS.app/embedded.mobileprovision" \
        | plutil -extract Entitlements xml1 -o - -
      ```

      It must list `iCloud.com.lineform.app` under the iCloud container and ubiquity container
      identifiers, `CloudDocuments` under iCloud services, and team `TV4QZT7A7X`.
- [ ] Confirm `PrivacyInfo.xcprivacy` and `Assets.car` are in the archived app, and that the app's
      `Info.plist` shows the expected `CFBundleShortVersionString` and `CFBundleVersion`.
- [ ] Upload from Organizer. As for the Mac, the upload is done only when App Store Connect shows
      the build under the iOS platform with the expected version and build.

### iv. TestFlight

Assign the build to **Lineform Internal**, install it from TestFlight on a real iPhone, and test it
by hand. The simulator suite cannot cover these:

- [ ] **Selection row and the system edit menu.** Select text: the edit menu floats at the
      selection and the selection row rises at the bottom, above the keyboard or the home
      indicator. Neither covers the other; the edit menu's items are the system's own.
- [ ] **iCloud files.** With iCloud Drive on: a new document saves into iCloud Drive › Lineform.
      Rename a file and delete a file from the Files list; confirm the Files app agrees, and that
      the open document follows a rename and is detached (text kept) after a delete. Turn iCloud
      Drive off for Lineform: the app keeps working with On My iPhone, with no error.
- [ ] **Relaunch.** Choose a Workspace folder in Files, force-quit, relaunch, and open a file from
      it (the security-scoped bookmark path).
- [ ] **Keyboard in Preview.** Type in Preview's top pane: the keyboard does not cover the caret,
      and the Read pane follows.
- [ ] **VoiceOver.** One pass through Write, Read, Preview, the Menu sheet, the Styling sheet, the
      selection row, an AI review (its custom actions), and the first-run screens.
- [ ] **Reconnect with a real Files pick.** Open a document whose image is missing, tap Reconnect
      in Read, pick the image in Files, and confirm the link is rewritten and the image shows.
- [ ] **Whole-document AI.** With a provider connected: Menu ▸ Document ▸ Ask AI… on a short
      document (the comment field opens) and on one over 1,500 words (the confirmation shows
      first); review, accept part, and check one undo restores it.
- [ ] **Export and share.** Export each format, Save to Files from the share sheet, print to a
      printer or PDF, and read aloud.
- [ ] **Clean install.** Delete the TestFlight app only on a test account (see the cautions), then
      install: first run plays once, and the next launch opens the document.

### v. App Privacy

The answer stays **Data Not Collected**, for the Mac's reasons in §5, which hold on iPhone:

- Documents stay in the writer's own files: On My iPhone › Lineform, their iCloud Drive, or a
  folder they picked. No account, analytics, telemetry, advertising identifier or document upload.
- The iPhone build's only network path is the AI the writer connects: the prose of a selection (or
  the whole document, when they choose Ask AI for it, after a confirmation above 1,500 words) goes
  from the iPhone directly to the provider they chose, under their own key, kept in the Keychain.
  The developer receives nothing. The §5 owner check applies unchanged.
- The iPhone build has no announcements request and no Check for Updates today (Settings keeps the
  In-app notifications choice only). If either is added, it must be the Mac's request (no body,
  query identifier or cookie; announcements gated by the switch) and this section updated.
- The App Privacy answer is per app, not per platform: the one answer covers both.

### vi. App Store metadata draft (iPhone)

Name, subtitle, category, privacy policy URL and age rating are shared by both platforms. The
description, keywords, promotional text, What's New and screenshots are per platform; these are the
iPhone's. Same honesty rules as `Lineform/Resources/AppStoreMetadata.md` and §6: say **free** and
**source-available**, never "open source"; "No AI built in. Connect your own if you want it.";
App Store only; only Atkinson Hyperlegible and OpenDyslexic are bundled fonts. No iPhone copy
mentions or assumes a Mac.

**Description**

> Lineform is a free, calm Markdown editor for iPhone that keeps your writing in real files. Write,
> read, and preview ordinary .md and .txt documents saved in Lineform's iCloud Drive folder or On
> My iPhone, or open a Markdown file from the Files app and edit it in place.
>
> Switch between Write, Read, and Preview. Read renders tables, task checkboxes, callouts, fenced
> code with syntax highlighting, Mermaid diagrams, LaTeX math, and images stored beside your
> document — all drawn natively. Images at a web address are never downloaded. Shape the page with
> reading themes, fonts (including Atkinson Hyperlegible and OpenDyslexic), size, line height, and
> spacing. Find your way with the outline and search, keep earlier versions of a passage with
> History, and export to HTML, PDF, Styled PDF, and Rich Text, print, share, or have the document
> read aloud.
>
> Want AI help? Connect your own Claude, ChatGPT, Google, or OpenAI-compatible model with your own
> API key, then select text to trim it, cut it in half, rewrite it, proofread it, or mark its
> weakest and longest sentences — or tell it in your own words what to change. Every suggestion is
> reviewed before it touches your file, and your Markdown structure is never changed. Lineform
> sends only the text you act on, directly to the provider you choose.
>
> No account, no analytics, no document upload. No AI built in. Connect your own if you want it.

**Keywords** (94 of 100 characters; "Lineform" and the subtitle's words are already indexed):

> writer,writing,notes,plain text,text editor,reader,preview,Mermaid,LaTeX,iCloud,files,md,focus

**Promotional text** (85 of 170 characters):

> A calm Markdown editor for writing, reading, and reviewing real files on your iPhone.

**What's New** (App Store Connect may not ask for it on the first iOS version; keep it for the
next one):

> Lineform is now on iPhone: Write, Read, and Preview for your Markdown files, with History,
> export, read aloud, and the AI you connect yourself.

**Review note** (adapt §6's): "Lineform has no built-in AI. Optionally, the user can connect their
own AI provider (Menu ▸ Settings ▸ Connect Your AI…) with their own API key, stored in the
Keychain. The Connect button states which company will receive the text. Nothing is sent on
connect. Afterwards, only the prose of a selection the user chooses an AI action for (or the whole
document, when the user chooses Ask AI for it) is sent, directly from the iPhone to that provider;
the developer operates no server and receives nothing."

Before submitting, check every claim above against the build being submitted
(`docs/architecture/iphone-app.md`).

### vii. Screenshots

Required: the 6.9" iPhone size, **1320 × 2868** portrait (iPhone 16 Pro Max / 17 Pro Max class).
Optional: 6.5", 1284 × 2778 (App Store Connect scales the 6.9" set down when it is missing). Up to
ten per size; the plan is six:

1. Write — a real document with a heading, a list and the formatting colours.
2. Read with a Mermaid diagram and a math block.
3. Preview — Write above, Read below.
4. The Menu sheet on Files.
5. The Styling sheet over the page.
6. An AI review (struck original, highlighted replacement, the review card). Needs a connected
   provider; capture it on a device or a simulator with a test key, never with the owner's key in
   view.

Draft captures from a Debug simulator build are in `docs/release/iphone-screenshots/` with a README
that says what each shows and how it was made. Re-capture from the release candidate before
submitting.

## Persistent cautions

- Every production, TestFlight, and local Release copy shares `com.lineform.app` and
  `iCloud.com.lineform.app`. Avoid install/delete churn while signed into the production iCloud
  account.
- Debug intentionally omits iCloud entitlements so ad-hoc test hosts launch reliably and never
  touch production iCloud data.
- Organizer validation is mandatory after adding an extension, embedded framework, or executable.
