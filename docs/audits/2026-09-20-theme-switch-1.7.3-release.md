# Lineform 1.7.3 theme-switch release review

Date: September 20, 2026

Release: 1.7.3 (build 31)

App Store Connect app: 6800480078

Decision: submitted to App Review; not yet approved or live

## Incident and fix

Lineform 1.7.2 could enter an unbounded main-thread appearance loop on macOS 27 when a reader
theme crossed between light and dark, most visibly Original ↔ Quiet. A sample of the released app
showed `NSHostingView.updateEnvironment` changing `window.appearance`, followed by
`WindowChromeReader`'s KVO healer writing the AppKit appearance back. The cycle consumed more than
one CPU core and grew the process to roughly 4 GB in under a minute.

Version 1.7.3 gives each supported OS path one appearance authority:

- macOS 27 and later: SwiftUI's root color-scheme override owns appearance. Lineform does not pin
  or observe `window.appearance` or `contentView.appearance`.
- macOS 14–26: the established explicit AppKit appearance and KVO drift healer remain in place.
- Both paths still apply the theme page color to `window.backgroundColor`.

The behavior is covered by version-injected tests so the older and newer paths can both be asserted
on the current host.

## Review and QA evidence

- Independent diff review found no remaining correctness issue in the scoped fix.
- The released 1.7.2 build reproduced the fault at about 103% CPU with runaway memory.
- A fresh fixed Debug build switched Original → Quiet → Paper → Quiet → Calm → Original in
  0.72–0.83 seconds per change. It returned to 0% CPU and about 176 MB RSS.
- Visual checks confirmed correct Original and Quiet rendering. Tab create/close and Files-sidebar
  collapse/expand remained responsive under Quiet.
- Default test plan: 1,366 passed, 0 failed.
- Hosted real-window test plan: 25 passed, 0 failed.
- Release archive: successful, no compiler warning was observed in the archive output.
- App and Quick Look extension: version 1.7.3 (31), universal `arm64` + `x86_64`, version-matched.
- Deep code-sign verification passed. Production sandbox, CloudDocuments, iCloud container,
  user-selected file, network-client, and print entitlements were present as intended.
- Six app localizations and `Contents/Resources/Metadata.appintents` were present.
- The archive contains the app and sandboxed Quick Look Mach-O binaries; no helper or updater was
  added.

The default tests were run from an exact temporary copy under `/tmp`. Source-reading tests stalled
when the test host opened repository files under Documents because of the macOS TCC path; moving the
same source out of Documents produced the complete clean 1,366-test result.

## TestFlight and App Store evidence

- Apple build ID: `5dc230cd-9663-4139-8b92-2f2fe5859991`.
- Apple processing: `VALID`, `APP_STORE_ELIGIBLE`, macOS 14.0 minimum.
- TestFlight: explicitly assigned to **Lineform Internal**, `IN_BETA_TESTING`, auto-notify enabled.
- TestFlight What to Test note asks for repeated switching across all themes, especially light ↔
  Quiet, while checking the editor, toolbar, tabs, and Files sidebar.
- The TestFlight app showed version 1.7.3 (31), the new note, and the Install action. The uploaded
  build was not installed during this run, so the runtime evidence above is from the source-identical
  fixed Debug build; signed-binary evidence is archive inspection plus Apple validation.
- App Privacy was verified in the rendered App Store Connect UI as published **Data Not Collected**.
- Six localized What's New notes were applied and read back through App Store Connect.
- App Store version ID: `ab1f29bc-319a-478a-bfda-a5b45645fe7b`.
- Review submission ID: `e8c95e15-2548-4217-8e8c-a42070adf8de`.
- Final version and submission state: `WAITING_FOR_REVIEW`, with exactly one submission item and
  automatic release after approval.

`WAITING_FOR_REVIEW` is submission evidence, not approval or availability on the App Store. The
current live version remains 1.7.2 until Apple approves and releases 1.7.3.
