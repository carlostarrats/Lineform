# iPhone app

The iPhone app is the `LineformiOS` target in `Lineform.xcodeproj`. It shares the App Store
listing, bundle identifier (`com.lineform.app`), version and build number with the Mac app, and
links the same `LineformCore` package. Minimum iOS: 26.0. iPhone only
(`TARGETED_DEVICE_FAMILY = 1`); Mac Catalyst, "Designed for iPhone" on the Mac and visionOS are
all off, so the iPhone build of `com.lineform.app` can never run on a Mac.

This page covers roadmap step 3 (shell and files) and step 4 (Write mode) as it lands. Read and
Preview, the Menu sheet and the rest arrive in later steps.

## Each app stands alone

No iPhone copy mentions or assumes a Mac. There is no account and no sign-in. iCloud being off is
a fully working state, never an error or a prompt.

## Target, scheme and tests

- Sources: `LineformiOS/` (`LineformiOSApp`, `DocumentScreen`, `OpenDocument`, `FileListSheet`,
  and `Editor/`: `MarkdownEditor`, and `LineformTextView` in `LineformiOSTextView.swift`, named so no file name is shared with the Mac sources), with its own `Info.plist`, `Localizable.xcstrings` (six
  languages) and entitlements.
- Tests: `LineformiOSTests/`, hosted in the app, run by the shared `LineformiOS` scheme through
  `LineformiOS.xctestplan`. Never link `LineformCoreTestSupport` into this target.
- Run them on a simulator:

  ```sh
  xcodebuild test -project Lineform.xcodeproj -scheme LineformiOS \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=26.5'
  ```

- CI builds the target's tests for the generic simulator (`build-for-testing`), because the
  runner's simulator names are not fixed. Run the tests locally.
- The Mac scheme and its archive do not build the iOS target.

## Signing and iCloud

- **Debug carries no iCloud entitlement** (`LineformiOSDebug.entitlements` is empty), the same
  rule as the Mac's `LineformDebug.entitlements`. Debug builds and tests therefore always save to
  the on-device folder, sign ad hoc on the simulator, and can never touch the production
  container. Do not add iCloud to Debug.
- Release (`LineformiOS.entitlements`) carries CloudDocuments for `iCloud.com.lineform.app`.
- `DocumentFolderResolver` picks the save folder: `<container>/Documents` (the same folder the
  Mac's Files sidebar shows as iCloud) when the container resolves, otherwise the app's own
  `Documents` folder. `live()` asks for the ubiquity container, so call it off the main thread;
  `OpenDocument.prepare` does.
- The on-device folder appears in the Files app under On My iPhone › Lineform
  (`UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`).
- No test touches the real container: tests inject a temporary folder.

## Editor: TextKit 1

`MarkdownEditor` (SwiftUI) wraps `LineformTextView`, a `UITextView(usingTextLayoutManager: false)`.
TextKit 1 is deliberate: the Mac editor and its AI review overlay are TextKit 1, and the later
Write-mode features port from the Mac's `NSLayoutManager` code. Matching the Mac keeps the two editors laying out line
for line alike. Do not switch it to TextKit 2.

- **Reading profile.** `LineformTextView.profile` applies the base attributes
  (`MarkdownTextStyle.baseAttributes(for:)`) over the whole document, the typing attributes, the
  page colour, the caret and selection (`tintColor`) from `Theme.theme(for:)`, and the column
  insets from `EditorReadingLayout` (`profile.columnWidth` centred, never under
  `profile.marginWidth`; 20 pt top and bottom). The profile comes from the per-device
  `ReadingProfileStore` (`UserDefaults.standard`, never synced), which `DocumentScreen` observes,
  so a change re-applies without a relaunch.
- **Fonts.** The app copies `Lineform/Resources/Fonts` by reference (the same folder reference as
  the Mac, licence files included) and registers it at launch with `BundledFontRegistrar`. Comic
  Sans is a Mac system font and is unavailable on iPhone.
- **Highlighting** follows the Mac's rules (`docs/architecture/editor-behavior.md`): base
  attributes whole-document, token inks (`MarkdownTokenStyler`) only over the visible range plus
  3,000 characters (`MarkdownTokenScope`). The token pass runs 0.25 s after the last edit, and on
  scroll only when the window is no longer covered. **Every pass is skipped while there is marked
  text**, the typing-delay pass included; a skipped full pass runs once composition ends.
- **Editing rules** (`LineformiOSTextView+Editing.swift`) use the package's pure rules. Return is
  decided in the delegate's `shouldChangeTextIn` with `"\n"`, never from a raw key event, and
  only with no marked text: `MarkdownListContinuation` continues or ends a list, task or quote,
  and otherwise a CRLF document gets CRLF (`MarkdownLineEnding.inForce`); an LF Return is the
  system's. Tab and Shift-Tab are `UIKeyCommand`s that move between table cells
  (`MarkdownTableEditing.tabTarget`); outside a table `canPerformAction` declines them, so Tab is
  an ordinary Tab. The Mac's Format shortcuts (⌘1–⌘6, ⌘0, ⌘B, ⌘I, ⌘`, ⌘⇧X, ⌘⇧8, ⌘⇧7, ⌘L,
  ⌃⌘T, ⌃⌘R) are key commands with priority over the system's. The public commands for later
  steps are `insertTable()`, `reformatTable()`, `setHeadingLevel(_:)` and `apply(_:)`.
- **One edit path.** Every rule edit goes through `applyRuleEdit`: one localized
  `replaceCharacters` (a whole-text `MarkdownEdit` is reduced to the span between its common
  prefix and suffix), one undo step, then the delegate's `textViewDidChange` so `OpenDocument`
  autosaves. An edit that changes nothing registers no undo step and posts nothing.
- **Reading assists** (`LineformiOSTextView+ReadingAssists.swift`) follow the profile's
  `readingRulerEnabled` and `typewriterModeEnabled`, with the current line from
  `ReadingAssistRangeResolver.focusRange(…, mode: .currentLine)`. The **Reading Ruler** is a band
  of the tint colour at alpha 0.12 over the line's enclosing rects (every visual line of a wrapped
  line), widened to the column and outset 6 × 2 pt like the Mac's. It is a plain view kept as the
  text view's lowest subview, behind UIKit's text view, so it never covers a glyph and never
  touches the text storage. **Typewriter Mode** centres the caret's line fragment with
  `setContentOffset(TypewriterScroll.origin(…), animated: false)` after each selection change and
  edit; turning it off scrolls back to where the page was when it came on, and it waits while
  the keyboard animates. Two UIKit facts shape it: TextKit 1 layout here is non-contiguous, so the
  prefix up to the caret is laid out first (only past `firstUnlaidGlyphIndex()`), and a scroll
  past the laid-out content is put back once while UITextView grows `contentSize`, so it is set
  a second time.
- Chrome floats over the text. No bar spans the top of the page; the page colour runs edge to
  edge, and only the container safe area is ignored so the editor still resizes for the keyboard.
- Text set from code keeps the selection, clamped to the new text, so a live reload does not move
  the caret.

## Files: reading, writing and live reload

`OpenDocument` owns the one open document.

- Reads and writes go through `NSFileCoordinator` and `MarkdownFileCodec`: valid UTF-8 only, a
  leading BOM survives, CRLF is never normalised. An unreadable or non-UTF-8 file is refused and
  the current document stays.
- A file from outside the app (Files, "Open in Lineform") is opened through its security scope,
  which is held while the file is open.
- Live reload uses the shared `DocumentFileWatcher` and `DocumentReloadPolicy` (0.3 s debounce).
  An external change replaces the text only while memory still equals the last synced text, so
  edits disk does not have yet are never overwritten. Our own writes are coordinated with the
  document's own presenter, so they never come back as a reload.
- An external rename (`onMove`) follows the file and stops automatic renaming.
- **An external delete** (`onDelete`, set only on iPhone) keeps the text on screen and detaches
  the document from the deleted path. It becomes a new document again: nothing is written until
  the text changes, and then it saves under a new name from its first line. The deleted file is
  never written back. The watcher checks the file is gone after the writer finishes, because the
  coordinator also announces a deletion for a `.forReplacing` write that puts the file straight
  back. Without `onDelete` (the Mac) the watcher does not answer the delete or relinquish
  callbacks at all.

## Autosave rules

`AutosavePlanner` (package) decides each save; `OpenDocument` performs it.

- A new document saves into the save folder as soon as it has text, named from its first line
  (`DocumentNaming`: Markdown markers and unsafe characters removed, 60 characters at a word
  boundary, a 200-byte cap, a unique name compared case- and normalisation-insensitively).
- An Untitled document with nothing typed creates no file.
- While the name still follows the first line, editing the first line renames the file. Once the
  user renames the file, or the document was opened from an existing file, it is never renamed
  automatically.
- Saves run 1 s after the last keystroke, at once when the scene goes inactive or to the
  background (inside a background-task assertion), and before another file or a New Document
  replaces this one. A save that starts before the save folder is resolved waits for it;
  `prepare`, `flush` and the file sheet share one resolution (`resolveSaveFolder`).
- A new file is created with a non-replacing write (`.withoutOverwriting`, coordinated without
  `.forReplacing`). If a file appeared under the planned name at the last moment, the name is
  planned again with that name counted as taken.
- The app never shows a "Not saved" state and never asks Save / Don't Save. `flush()` reports
  whether disk has the text. A failed write keeps the text in memory, logs to os_log, shows a small
  calm notice ("Couldn’t save this document. Your text is still here.") until a save succeeds, and
  is retried on the next save. Opening another file or New Document does not go ahead while the
  current document's save fails.

## Reload and save races

`applyExternalChange` snapshots `text`, `lastSyncedText` and a sync generation (bumped whenever
`lastSyncedText` is set) before its off-main read. If any of them changed while the read was in
flight, such as our own save landing, the result is stale: deciding on it could put older disk
text back over that save. The file is read again (three tries at most) and a still-stale result
is dropped.

## Opening and iCloud downloads

Every open reads through the injected `DocumentDiskReading` off the main thread. An iCloud file
with no local copy yet (only its `.Name.md.icloud` placeholder) is handled first: the current
document is saved and put away, `startDownloadingUbiquitousItem` runs on the real URL, the screen
shows a quiet "Downloading…" state in place of the text, and the file is read once a local copy
exists. A file with a full local copy that is not current (`.downloaded`, for example offline)
opens that copy at once; the download request keeps running, and the live-reload watcher plus
`DocumentReloadPolicy` apply the current version when it arrives. A later open or New Document
supersedes a pending one. A placeholder URL always maps to the real file.

## Moves

An external rename is followed. A move into a Trash folder (a `.Trash` or `Trash` path component,
or a place the system trash directory contains) is a delete, as on the Mac. `DocumentFileWatcher`
reports no `onDelete` once it has seen `presentedItemDidMove`, so a rename is never a delete.

## Launch and scene restoration

- A normal launch opens a blank document.
- After iOS ends the app, the next launch reopens the document that was open. `@SceneStorage`
  (`openDocumentBookmark`) keeps the file's bookmark data, base64-encoded, so a file from outside
  the save folder also reopens with its security scope, and a renamed file is still found. The
  system discards scene storage after a user force-quit, so that launch is blank.
- The older `openDocumentPath` key (a path relative to the save folder, or absolute) is read once
  for scenes stored before bookmarks, then cleared.
- A stored file that no longer resolves leaves the blank document.

## The temporary file sheet

`FileListSheet` and the floating `MenuButton` (bottom right, Mac floating-card chrome) are a
stand-in until roadmap step 6's Menu sheet. The sheet offers **New Document** (flushes the pending
save, then shows a blank Untitled document), **Open from Files…**, and the save folder's
`.md`, `.markdown` and `.txt` files, newest first, kept current by `DocumentFolderMonitor`. iCloud
placeholders (`.Name.md.icloud`) are listed under their real names.

## Strings

iPhone strings live in `LineformiOS/Localizable.xcstrings`, in all six languages. Where the Mac
catalog already translates the same English text, the iPhone entry reuses that translation.
`LocalizationSourceSweepTests` scans `LineformiOS/` against this catalog, the same way it scans
`Lineform/` against the Mac catalog.
