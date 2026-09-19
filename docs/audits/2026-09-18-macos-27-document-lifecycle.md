# macOS 27 document-lifecycle QA — 2026-09-18

## Result

The intermittent final-tab close and stale-file-opening defects were reproduced as timing and
identity hazards, fixed, and exercised through the real macOS 27 app with disposable Markdown
files. The default and affected hosted test plans pass, as do signed Debug and unsigned universal
Release builds. No submission, upload, archive validation, or release action was performed.

Environment: Apple silicon, macOS 27.0 (26A428), Xcode 27.0 (27A266a), macOS SDK 27.0,
deployment target macOS 14.0. No older macOS runtime was available, so macOS 14–26 runtime
behavior remains unverified in this pass.

## Root causes and changes

### Command-W and save/close lifecycle

- The final-tab path used SwiftUI's presentation-relative `dismiss`. While the native save/close
  presentation was unwinding, that action could dismiss the alert rather than the DocumentGroup
  scene. It now uses the window-specific `dismissWindow` action while retaining the final tab
  until the scene closes.
- Save-then-switch could repoint the shared `NSDocument` from inside its save callback. Its
  continuation now runs after that callback unwinds.
- The window's shared `NSDocument` could carry a saved sibling tab's filename into the implicit
  save panel for an untitled tab. Save-and-close, Save All, and save-then-sidebar-switch now use an
  explicit native panel keyed to the exact tab, suggest `Untitled.md`, apply the app-wide open-file
  conflict guard, and still write through `NSDocument.save(to:ofType:for:)`.

### Opening and switching Markdown files

- Delayed SwiftUI text/format callbacks from an outgoing document could update whichever tab was
  selected by delivery time. Store write-back now requires the selected document UUID to match.
- A generic file-URL observer could similarly attach an outgoing or cancelled-save URL to the new
  active tab. The DocumentGroup's initial URL is captured once against its document UUID; later
  retargeting happens only from a successful save callback carrying the captured tab ID.

### macOS 27 compatibility

- macOS 27 hides images in most SwiftUI menus by default. The Files row context menu explicitly
  requests title-and-icon labels; the AppKit-decorated main menu remains unchanged.
- SDK 27's new `Document`/`URLDocumentConfiguration` stack is macOS 27-only. Lineform retains its
  `FileDocument`/`DocumentGroup` path because it supports macOS 14 and its multi-tab save/reload
  integration depends on the existing AppKit bridge. The SDK annotates that path with future
  migration guidance rather than a current build warning. A migration is not a compatibility fix
  that can be made without a dual document architecture and full older-system requalification.
- No Siri-specific adoption was added. App Intents metadata generation and linkage were verified;
  Siri execution was not tested and is not an acceptance gate for this work.

## Automated evidence

| Check | Result |
| --- | --- |
| Focused tab-store and reload suites | 77 passed, 0 failed |
| Affected hosted real-window lifecycle suite | 7 passed, 0 failed |
| Complete default plan, exact source mirrored under `/private/tmp` | 1,365 passed, 0 failed |
| Signed non-test Debug build | Succeeded; app and nested appex pass deep/strict verification |
| Universal Release build, signing disabled | Succeeded; app and appex are arm64 + x86_64 |
| Diff whitespace check | Passed |

The source mirror avoided a macOS 27 sandbox/privacy hang in `LocalizationCatalogTests` when its
test host tried to synchronously read the catalog from the repository's Documents path. No test
was weakened or skipped. Result bundles:

- `/private/tmp/Lineform27Focused/Logs/Test/`
- `/private/tmp/Lineform27Hosted/Logs/Test/Test-Lineform-2026.09.18_17-46-54--0700.xcresult`
- `/private/tmp/Lineform27DefaultDD/Logs/Test/Test-Lineform-2026.09.18_17-48-50--0700.xcresult`

The Release product contains `Contents/Resources/Metadata.appintents`, links App Intents, embeds
the Quick Look extension, includes en/de/es/fr/ja/zh-Hans resources, and retains the required
category and encryption declarations. Source entitlements retain printing in Debug and Release;
the Quick Look extension remains sandboxed and read-only. ReleaseResource, renderer, export/print,
accessibility/contrast, localization, App Intents, and Quick Look suites are included in the
complete default-plan result.

## Real macOS 27 journeys

All document content used files under `/private/tmp/Lineform27Fixtures`; no personal document was
opened or modified.

- Final dirty tab: Cancel retained the draft; Don't Save closed the intended window; cancelling
  the nested Save panel retained the draft; Save wrote one explicitly named file and then closed.
  Don't Save was repeated because the report was intermittent.
- Multiple tabs: closing the selected tab activated its sibling; closing a background tab left the
  active tab, search/undo-sensitive state path, and text alone.
- Window close with a dirty background untitled tab: Cancel retained all tabs; Save All proposed
  `Untitled.md` rather than the previously active saved filename, saved once to the chosen fixture,
  left the sibling file unchanged, and closed after the callback unwound.
- File Open switched between unique Alpha/Beta fixtures and selecting an already-open file focused
  its existing tab without duplication. Finder Open With/Launch Services opened the selected
  fixture in the exact Debug app rather than reusing the previous document.
- Files sidebar selection replaced the current tab in place. Unsaved replacement verified Cancel,
  Don't Save, and Save; the explicit panel used `Untitled.md`, the saved draft landed only at the
  chosen path, and the selected file appeared immediately.
- A clean background Beta file was externally rewritten; selecting it showed the external bytes
  and the disk-update status before editing. A subsequent edit/save changed Beta only; Alpha and
  the other fixture identities/content remained unchanged.
- The macOS 27 Files-row context menu displayed its expected symbols and accessible action names.

## Preservation and remaining limits

The Debug preference domain was empty before QA and is empty afterward. Four intermediate and one
final Debug Quick Look registrations created by builds/tests were unregistered by exact path.
The two pre-existing release registrations (installed 1.7.1 and repository Release 1.5.0) were
left untouched. The installed `/Applications/Lineform.app`, real files, production settings, and
unrelated working-tree content were not changed.

There was no macOS 14–26 runtime, no Intel Mac, no live iCloud collaboration pass, no full
VoiceOver/Switch Control walkthrough, no physical print, no Organizer validation, and no live
Shortcuts/Spotlight/Siri invocation. Those are unverified, not green. The universal build and
existing compatibility tests reduce older-system risk but do not replace runtime evidence.
