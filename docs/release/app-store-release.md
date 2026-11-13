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
- [ ] Explain the announcements request if App Review asks why `network.client` is present.
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
        chooses Rewrite / Proofread / Mark, and only that selection's prose is sent. Bundled
        Privacy.md and Help.md describe what, to whom, when, the Keychain, and Disconnect.
      - **Conclusion:** no per-action prompt is required by the text of 5.1.2(i); the guideline asks
        for clear disclosure and explicit permission *before* sharing, which the consent label gives
        once per provider, and each action is itself the writer's choice. Do NOT shorten the label
        to a bare "Connect". If App Review asks for more (e.g. a per-action confirmation), bring it
        to the owner — do not add UI on review feedback alone.
      - **Review note to paste:** "Lineform has no built-in AI. Optionally, the user can connect
        their own AI provider (Lineform ▸ Connect Your AI…) with their own API key, stored in the
        Keychain. The Connect button states which company will receive the text. Nothing is sent on
        connect. Afterwards, only the prose of a selection the user right-clicks and chooses an AI
        action for is sent, directly from the Mac to that provider; the developer operates no
        server and receives nothing. To test without an account, choose Other and point it at a
        local OpenAI-compatible server (e.g. Ollama at http://localhost:11434/v1)."

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
