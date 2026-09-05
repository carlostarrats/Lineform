# Lineform conservative QA — 2026-09-04

## Result and limits

Two reproducible P1 document-close deadlocks were fixed narrowly and verified in the real app.
The complete default and hosted test plans pass. This is **not an unqualified clean bill of
health**: an earlier test-enabled runtime session produced an unresolved file-identity/overwrite
observation. The simpler reproductions and the original sequence in an ordinary Debug build did
not reproduce it. No speculative tab/navigation change was made to address it.

Environment: Apple silicon, macOS 26.6.2 (25G83), Xcode SDK 26.5, deployment target macOS 14.
Starting commit: `15f5b2db80c51dad8dff49de6909736f40c7022e`, branch `codex/work-2026-08-30`.
AGENTS.md and all seven architecture documents were read before the review/fixes.
The installed `/Applications/Lineform.app` was not modified. QA used the explicitly selected
`/private/tmp/lineform-default-app-derived/Build/Products/Debug/Lineform.app`.

## Confirmed defects and fixes

### P1: Save from the final-tab close alert hangs the app

Reproduction: edit Untitled, Command-W, Save, accept the native save panel. The bytes were
successfully written, but the app became unresponsive. A main-thread sample showed
`SaveAndCloseCoordinator` calling `NSWindow.performClose` from the document's save callback,
then waiting on `_NSDocumentSerializationSemaphore` inside native can-close handling. The
coordinator also removed the final tab instead of retaining the DocumentGroup scene state.

Fix: capture the alert's owning window before dismissing the alert; defer successful continuation
until the save callback has returned; write the saved URL to that specific tab; use the existing
container `performCloseTab` path. The last tab remains alive until scene dismissal. Nonfinal
closure activates its sibling through the same existing path. Cancel does not close or retarget.

### P1: Window close / Save All re-enters native document serialization

Reproduction: edit Untitled, click the traffic-light close button, choose Save All. The app hung
before displaying the save panel. The main-thread sample showed `windowShouldClose` starting
the save queue while AppKit still held its can-close activity. Advancing to another save or
closing from inside the queue's save callback had the corresponding re-entry risk; a hosted
regression demonstrated both continuations occurring inside that callback before the fix.

Fix: return `false` from the native close attempt before starting Save All on the main queue.
After each successful save, preserve the synchronous saved-URL write-back, then advance the
queue on the next main-queue turn. The existing native alert and save panels remain unchanged.
The injectable alert presenter is a test seam; production still calls `NSAlert.runModal()`.

Evidence samples (temporary, not shipped):

- `/tmp/lineform-qa-20260904-save-hang.sample.txt`
- `/tmp/lineform-qa-20260904-save-all-hang.sample.txt`

## Regression coverage

Five tests were added to the existing hosted `EditorDrawerMotionHostedTests` class:

- `testSaveAndCloseDoesNotRemoveTheFinalTabOrCloseInsideTheSaveCallback`
- `testCancelledSaveDoesNotCloseOrRetargetTheTab`
- `testSaveAllUnwindsEachSaveBeforeActivatingAnotherTabOrClosing`
- `testWindowSaveAllStartsOnlyAfterTheNativeCloseAttemptReturns`
- `testSaveAllCancellationKeepsRemainingTabsOpen`

The save-and-close regression failed against the old implementation (synchronous close and
empty final-tab store). The Save All callback-order regression failed against the old queue
(activation and close inside the callback). These are callback-boundary tests using AppKit
document/window subclasses, supplemented by real native-panel verification, not claims that
the fake save implementation reproduces the framework's internal semaphore itself.

## Automated results

| Run | Result |
| --- | --- |
| Initial complete default plan | 1,351 passed, 0 failed |
| Initial complete hosted plan | 18 passed, 0 failed |
| Focused fixed hosted classes plus both localization gates | 33 passed, 0 failed |
| Final complete default plan | 1,351 passed, 0 failed |
| Final complete hosted plan | 23 passed, 0 failed |
| Final ordinary Debug build | Succeeded |
| Final diff whitespace check | Passed |

Final total: **1,374 distinct tests passed, zero failures** across both plans. Focused reruns
are not added again to that total. Expected red regression runs are not represented as passes.
The first sandboxed test invocation failed because Xcode could not write its package caches;
the approved invocation then ran the full suite successfully.

Commands used the Lineform scheme, `platform=macOS`, serial testing, and
`/tmp/lineform-default-app-derived`; the hosted run adds `-testPlan LineformHosted`.
Final result bundles and logs:

- `/tmp/lineform-qa-20260904-final-default.xcresult` and matching `.log`
- `/tmp/lineform-qa-20260904-final-hosted.xcresult` and matching `.log`
- `/tmp/lineform-qa-20260904-final-build.log`

## Real-runtime coverage

The initial runtime pass used the test-built app. Final core lifecycle checks were repeated
after an ordinary `xcodebuild build` restored the normal Debug entitlements (without XCTest's
injected test-service and broad read exceptions).

- Opened the exact QA application icon in Finder with no document: Untitled appeared. Quit
  and cold-launched through that icon: Untitled appeared again.
- File Open from pristine Untitled replaced it with the selected file, with no residual blank
  tab/window in the inspected state. Before/after screenshots and the tab-native code path
  support this; no high-frame-rate recording was made, so sub-frame flicker is not certified.
- File Open beside an edited untitled tab preserved its exact draft; Command-W on the opened
  file returned to that draft. Multiple tabs and multiple existing windows were exercised.
- Command-W on an unsaved final tab presented one close alert. Cancel preserved it; Save
  opened a panel and closed on successful save; cancelling that panel kept the draft; Don't
  Save closed it on the first attempt. Save was verified again under normal Debug sandboxing.
- Traffic-light Cancel and Don't Save worked first attempt. Save All opened a panel and
  closed after save, including under normal Debug sandboxing.
- Multi-tab Save All saved the first unsaved tab, presented the second panel once, and
  cancelling that second panel retained all tabs with the first correctly retargeted. Saving
  and closing the remaining unsaved tab then activated its sibling without another first-tab save.
- Closing a background saved tab retained the selected draft. Saving a dirty background tab
  in the normal sandbox wrote that tab's exact text and retained the foreground draft intact.
  External changes to the active file appeared; a clean background tab loaded an external
  rewrite when selected.
- Native workspace selection, sidebar in-place replacement, Open in New Tab, background
  rename, and background trash were exercised. Trash cleared the open tab's file identity
  and retained its text as unsaved work. Only the disposable Beta fixture was trashed.
- Quick Open found Alpha and selected its already-open tab. Find/Replace produced the correct
  match counts and source/preview change, and Undo restored the replacement.
- Write, Read, and Split rendered the smoke fixture; code, table alignment, callout, Mermaid,
  inline/block math, task checkbox, emoji and decomposed accent were inspected. The checkbox's
  accessibility action updated source. Mode changes and linked split state were exercised;
  fine-grained motion/scroll behavior also has hosted regression coverage.
- Exact Unicode paste survived heading-level toggling. List continuation/termination, table
  insertion, Tab cell navigation, and table reformat were exercised. CUA's synthetic typing
  did not faithfully enter non-ASCII text, so Unicode checks used exact paste and file loading.
- Save As retargeted the real Markdown document. Autosave and explicit Save wrote the edited
  fixture. HTML, PDF, Styled PDF and RTF were exported through the real menus; both PDFs were
  rendered to PNG and visually inspected, and RTF text was extracted. Source remained open.
- Print displayed the native one-page preview. No physical print was sent: no printer selected.
- Original and Quiet themes, toolbar/sidebar ink and inspector geometry were visually checked;
  Original was restored. Native accessibility labels/actions were inspected, not a full
  VoiceOver or Switch Control session.

Disposable runtime files and exports remain under `/tmp/lineform-qa-workspace.yFaNkL` and
`/tmp/lineform-qa-20260904-*`. The Debug workspace chooser now references that QA folder;
the production app's workspace was not changed. No default-file association was accepted.

## Broad review and unavailable boundaries

| Area | Evidence beyond the runtime smoke pass / remaining limit |
| --- | --- |
| First run, startup and restoration | Launch/intro policy and keyboard/accessibility source reviewed; launch/default-app tests pass. A fresh macOS user/first-run installation and crash recovery were not directly exercised. |
| Tabs, files and identity | Store/dedupe/Save As conflict, source save and reload tests pass. Full Finder document-open/Open With and every multi-window dedupe combination were not directly tested. |
| Sidebar and performance | Scanning, debounce/watcher retargeting, flat/lazy rows, hidden-folder and large-tree tests pass. No timed huge-workspace UI benchmark or live iCloud sync was performed. Debug intentionally lacks iCloud entitlements. |
| Editing and exact source | CRLF, BOM, escaped syntax, composed-character ranges, overflow, lists/tables/images and source-save regression suites pass. Those combinations were not all repeated manually. |
| Rendering and images | Renderer, Mermaid/math, code palettes, local/remote image resolver and export tests pass. Local-image sandbox reauthorization and every diagram type were not all exercised through UI. |
| Search and navigation | Document/cross-file search, Quick Open and outline suites pass. Runtime covered document replacement and Quick Open, not a complete cross-file-search/shortcut matrix. |
| Speech, spelling, Writing Tools | Region/performance/protection, language/voice, speech stop/cancel and menu tests pass; system API paths reviewed. No audible voice-quality or live Writing Tools service verification was performed. |
| Themes/accessibility/localization | Contrast, font fallback, menu and both full localization gates pass. No all-language visual sweep or full assistive-technology walkthrough. |
| Privacy and packaging | Remote image refusal, announcement request gating/hostile-feed limits and release-resource tests pass. No packet-capture privacy certification. App/appex source entitlements reviewed; normal Debug deep/strict signature verification passed; `Metadata.appintents` exists. |
| Quick Look and App Intents | Renderer parity and bundle/metadata coverage pass. Finder extension selection and actual Shortcuts/Siri execution were not verified; installed production and Debug identities coexist. |
| Mac App Store | Release configuration reviewed only. No new archive, Organizer validation, universal Release binary verification, upload or App Store Connect changes. Debug signing does not certify production provisioning. |
| Other macOS versions | macOS 14/15 were unavailable. Existing explicit Sonoma toolbar and PDF pagination boundary tests pass. No visual/runtime claims for those systems. No OS-gated appearance policy was changed. |

## Unresolved observation — investigate before a clean sign-off

During the initial test-enabled session, after Split Find/Replace, closing Find/Replace, Undo,
Save, and New Tab, the blank selected tab displayed the previous QA filename rather than
Untitled. A subsequent filesystem check found the previous disposable Alpha fixture empty;
later typing in that tab wrote the draft to that same QA path. The overwrite itself was observed,
but its root cause and exact timing have not been established. The initial runtime had also
contained restored windows from earlier debugging, and the executable had XCTest-injected
entitlements; neither fact proves the cause.

Fresh isolated attempts at ordinary New Tab, Save then New Tab, dirty-save then New Tab,
Split then New Tab, and Undo/Save/New Tab did not reproduce it. The original Find/Replace
sequence was repeated after a normal Debug rebuild and cold process start: the new tab was
Untitled and the source remained 139 bytes with the expected text. No speculative serialization
or navigation rewrite was made. Treat this as a potentially high-severity unresolved observation,
not as a fixed defect or as evidence that the two close fixes caused it. A useful next diagnostic
is tracing backing-document URL/save completion and selected-tab identity around this sequence
in a clean process, using disposable files only.

## Scope preservation

Changed production files: `EditorContainerView.swift`, `SaveAndCloseCoordinator.swift`,
`WindowCloseController.swift`. Added five hosted tests in `EditorDrawerMotionHostedTests.swift`.
Updated the relevant lifecycle architecture notes, the save/close invariant in `AGENTS.md`,
and this audit record. No spacing,
colors, typography, animation, editor interaction design, format policy, OS-specific UI branch,
signing configuration or entitlements were changed.

Pre-existing untracked `.asc/export-1.6.1-24/` and
`docs/superpowers/specs/2026-08-22-save-web-articles-design.md` were preserved. No commit was
made during the QA pass; the owner subsequently authorized a local commit of the scoped fixes,
tests and documentation. No push, merge, release, or App Store state change was performed.
