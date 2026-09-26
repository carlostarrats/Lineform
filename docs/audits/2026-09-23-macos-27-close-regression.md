# macOS 27 final-tab close regression (2026-09-23)

## Installed-app reproduction

In `/Applications/Lineform.app` version 1.7.3 (build 31), I typed into an Untitled document,
pressed ⌘W, and chose **Don't Save**. A different Markdown file opened from Finder with its
correct contents, but the discarded Untitled document remained behind it. Closing the newer
file exposed a second native save panel for the old draft. The test-created provisional file
was removed through that panel and verified absent afterward.

## Source change

`confirmCloseTab` now waits for the owning window's sheet to end before closing the approved
tab. For the final tab, an explicit **Don't Save** choice uses SwiftUI's destructive
`dismissWindow` behavior so DocumentGroup does not present a second save panel. Clean and
successfully saved tabs retain interactive dismissal. The final tab remains in `EditorTabStore`
until the scene closes.

## Candidate verification

One signed Debug candidate was built in a single temporary DerivedData directory and run on
macOS 27.0. The installed App Store app was not replaced.

- Final edited Untitled → ⌘W → **Don't Save**: before any UI reactivation, the app had no key
  window and `NSDocumentController` had zero documents. Its provisional autosave file existed
  before the close and was absent afterward.
- **Cancel** on the close alert retained the exact draft. **Save** wrote the expected text to
  one chosen fixture file, then left no window or document. Cancelling the native Save panel
  retained the draft; a later **Don't Save** removed it and its provisional autosave.
- Two distinct Markdown files opened through File ▸ Open as tabs with their correct contents.
  Closing the second selected the first; closing the last left no window or document.
- After tab creation/closure and a Read ↔ Write transition, final-tab **Don't Save** again
  left no window or document. Discarding a dirty nonfinal tab preserved its clean sibling.
- From a zero-document state, Finder **Open With** sent a new fixture to the candidate. A
  debugger check before UI activation found exactly one open document, with the requested
  file URL and window title. ⌘W closed it. No old draft resurfaced.

UI inspection can activate a windowless Lineform instance and trigger its Dock-reopen path,
creating a fresh empty Untitled window. The zero-window and Finder-open checks above were
made before such inspection; a transient blank seen during earlier automation was not counted
as a close failure.

The temporary candidate process, its Quick Look registration, and the generated build directory
were removed after verification. Only the installed Quick Look registration remained. These
checks verify the candidate on macOS 27; the installed build 31 remains affected until an
updated app is distributed. Other macOS versions were not exercised in this run.

## September 25 follow-up: versioned 1.7.4 candidate

The fix was compiled again as 1.7.4 (build 32) in one reusable temporary DerivedData directory.
The full default test plan passed 1,367/1,367 tests. In the running candidate, two separate
edited Untitled documents were closed with ⌘W → **Don't Save**. A debugger inspection before
UI reactivation found zero `NSDocumentController` documents and no key window after the second
discard. Launch Services then opened a distinct Markdown fixture as the only live document;
its URL, title, and visible text matched that fixture. Closing it left zero documents and no key
window. A second distinct fixture opened as the only live document with its own correct text.

The hosted suite passed 25/26 tests. Its release-blocking macOS 27 theme-switch stress test
completed all 300 transitions with bounded memory and an idle CPU but missed its strict
15-second limit. The measured elapsed times ranged from 15.25 to 19.59 seconds across full
and isolated runs; a later run after other builds stopped still took 15.79 seconds. The machine
had shown load average around 20 while Spotlight indexed and another Xcode build had run
concurrently. The same gate recorded 14.683
seconds on the known-good build 31 source (see `2026-09-20-theme-switch-1.7.3-release.md`).
This is a timing-gate failure, not evidence that the document-close fix regressed themes;
the release precondition remains unmet. The installed App Store build 31 is unchanged.

## Installed TestFlight investigation and fix (September 25)

The Debug candidate was insufficient: it lacked the production iCloud entitlement. I uploaded
1.7.4 build 32 for internal TestFlight, installed it over `/Applications/Lineform.app`, and
reproduced the remaining defect. After **Don't Save**, the window closed but the test-created
Untitled draft still existed in Lineform's iCloud Documents folder. On relaunch an old draft
opened again. Build 33 removed a final-tab draft file, but the nonfinal-tab journey still left
one behind. Build 34 retained and removed that nonfinal draft URL, but ⌘W on the clean sibling
presented a native **Keep this new document?** panel for the discarded draft. Each failure was
verified in the installed TestFlight app before the next source change. I removed only the exact
test-created draft files left by those failed runs after checking their contents.

The final source keeps a system draft's autosave URLs in its `DocumentTab` before the shared
`NSDocument` switches to another tab. It clears the backing document's native draft and
autosaved-content state for the incoming tab, and removes captured draft files only after an
explicit **Don't Save** when no live document owns the URL. A final-tab discard still waits for
the alert sheet to end before destructive scene dismissal.

Installed 1.7.4 build 35 (`/Applications/Lineform.app`, macOS 27.0) was verified after TestFlight
installation, not inferred from the archive:

- Its app signature verified and exactly one 1.7.4 Quick Look registration remained.
- Three separate autosaved Untitled drafts were closed with ⌘W → **Don't Save**; the exact
  provisional iCloud file was absent after each. One close followed **Cancel**, which first
  preserved the draft and its content.
- In two separate windows with a dirty Untitled draft and a clean Markdown sibling, discarding
  the draft preserved the sibling's exact text. ⌘W then closed the sibling without a native save
  panel or old draft returning.
- Three distinct Markdown fixtures opened with their own URL, title, and text. New Untitled
  windows were blank. After quitting and relaunching, Lineform again opened a blank Untitled
  rather than an old Markdown file or discarded draft.

The final signed default test plan passed 1,370/1,370. Apple archive validation succeeded;
build 35 processed as `VALID` and `INTERNAL_ONLY` and was installed through TestFlight. The
hosted plan passed 25/26; its 300-transition macOS 27 theme stress test completed but measured
17.109 seconds against the strict 15-second limit on this loaded machine. The public App Store
build remains 1.7.3 (31); build 35 is an installed internal TestFlight fix, not a public release.

## App Store submission (September 25)

Apple marked build 35 `INTERNAL_ONLY`, so it cannot be submitted for customer distribution. I
changed only `CURRENT_PROJECT_VERSION` to 36 and archived the same fixed source as 1.7.4 (36),
reusing one temporary DerivedData directory and the existing local Swift package cache. The
Release archive produced no compiler warnings; the app and Quick Look extension are both
universal (`x86_64`, `arm64`), version 36, signed, and sandboxed. The app carries the Production
CloudDocuments entitlement for `iCloud.com.lineform.app`, and `Metadata.appintents` and all six
localized resource folders are present. Xcode Organizer reported **Lineform 1.7.4 (36) validated:
Your app successfully passed all validation checks** and uploaded it by the App Store Connect
distribution path. Apple processed build ID `52eae63b-58e7-4387-ac0f-f46f27da937a` as `VALID`
and `APP_STORE_ELIGIBLE`.

The macOS 27 hosted theme gate was rerun from already-built test products on a quiet desktop. It
passed: 300 switches in 13.479 seconds (limit 15), resident-memory growth 966,656 bytes (limit
192 MiB), and idle CPU 0.002 seconds in the final 0.5-second window (limit 0.20). The passing
XCTest metrics attachment is retained in
`docs/audits/evidence/lineform-1.7.4-build-36-theme-gate.xcresult`. The previous full default plan passed
1,370/1,370; the full hosted plan passed 25/26 before this targeted theme gate passed. No app
source changed between build 35's tests and build 36's archive except the build number.

TestFlight installed build 36 over build 35 in `/Applications/Lineform.app`. Its deep signature
verified and exactly one 1.7.4 Quick Look extension remained registered. In the installed app:

- Dirty Untitled → File Open fixture A as a second tab → select Untitled → ⌘W → **Don't Save**:
  fixture A retained its unique text, and ⌘W closed it with no second native save panel.
- Reopen from zero windows: blank Untitled. File Open fixture B showed B's distinct URL, title,
  and text, rather than A or the discarded draft. ⌘W closed B.
- New dirty final Untitled → ⌘W → **Cancel** kept the exact draft. A second ⌘W → **Don't Save**
  left no window. Reopen showed blank Untitled, and a full quit/relaunch again showed blank
  Untitled. No `QA Build 36` provisional file remained in Lineform's iCloud Documents folder.

App Store version 1.7.4 was created with six localized fix notes and review instructions for the
exact macOS 27 close sequence. The pre-submission readiness check reported zero errors and zero
warnings. Submission `2f42196f-dd46-482c-b8ff-240d03fda737` contains one review item and read
back as `WAITING_FOR_REVIEW` on September 25 at 8:29 PM PDT. Release type is **MANUAL**, so Apple
approval will not publish it automatically. The currently public version remains 1.7.3 (31).
