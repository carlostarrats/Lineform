# iPhone app

The iPhone app is the `LineformiOS` target in `Lineform.xcodeproj`. It shares the App Store
listing, bundle identifier (`com.lineform.app`), version and build number with the Mac app, and
links the same `LineformCore` package. Minimum iOS: 26.0. iPhone only
(`TARGETED_DEVICE_FAMILY = 1`); Mac Catalyst, "Designed for iPhone" on the Mac and visionOS are
all off, so the iPhone build of `com.lineform.app` can never run on a Mac.

This page covers roadmap step 3 (shell and files), step 4 (Write mode), step 5 (Read and
Preview, with the Write/Read/Preview switch), step 7 (the Styling sheet) and step 11 (first run).
The Menu sheet and the rest arrive in later steps.

## Each app stands alone

No iPhone copy mentions or assumes a Mac. There is no account and no sign-in. iCloud being off is
a fully working state, never an error or a prompt.

## Target, scheme and tests

- Sources: `LineformiOS/` (`LineformiOSApp`, `DocumentScreen`, `OpenDocument`, `FileListSheet`,
  `Editor/`: `MarkdownEditor`, and `LineformTextView` in `LineformiOSTextView.swift`; `Read/`:
  `LineformReadView`, `ReadViewRepresentable`, `ReadOverlayButtons`, `PreviewSplit` and
  `LinkedScroll`; `Chrome/`: `ModeSwitch`, `ModePositionKeeper`, `MotionPolicy` and
  `StylingButton`; `Styling/`: `StylingSheet`, `StylingPresetCard`, `StylingRows` and
  `StylingDrag`. Every name
  differs from the Mac sources' file names), with its own `Info.plist`, `Localizable.xcstrings`
  (six languages) and entitlements.
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
- **Spell check that skips code** (`SpellCheckPass.swift`, `LineformiOSTextView+SpellCheck.swift`).
  The system checker, autocorrection and smart quotes, dashes and inserts are off, as in the
  Mac's `configureForMarkdownEditing`. `SpellCheckPass` runs `UITextChecker` on the main actor
  over `MarkdownSpellCheckRegions.checkableRanges` of the visible range plus 2,000 characters
  (snapped to lines), so fenced code, inline code, front matter, math and link or image
  destinations are never flagged. It runs 0.4 s after the last edit and after a scroll, never
  per keystroke and never while there is marked text. The language is the keyboard's primary
  language; when it has no `UITextChecker` dictionary (the emoji keyboard), the first preferred
  language that has one; with none, nothing is checked. Each misspelling gets a 1.5 pt dotted
  red line (`systemRed` resolved for the theme's own light or dark, `Theme.usesDarkChrome`, not
  the system appearance), stroked by a `CAShapeLayer`
  above the text from TextKit 1 line fragments; nothing is written to the text storage, so copy,
  paste and the saved file never see it. An edit that touches a misspelling drops its underline
  at once, and one before it shifts it. On a misspelling the edit menu
  (`textView(_:editMenuForTextIn:suggestedActions:)`) leads with up to five guesses, then Learn
  Spelling (the system dictionary) and Ignore Spelling (this document's checker). A guess goes
  through `applyRuleEdit`: one undo step, and autosave sees it. Never call a whole-document pass
  from here; `testSpellPassIsScopedRatio` gates it at 4× on the Mac's 730 KB corpus.
- **Writing Tools** is off (`writingToolsBehavior = .none`, results limited to plain text and
  lists, as on the Mac), and the delegate's `writingToolsIgnoredRangesIn` returns
  `MarkdownWritingToolsProtection.ignoredRanges`, so the protection holds if it is turned on.
- **Image paste and drop** (`LineformiOSTextView+ImagePaste.swift`). The text view sets a
  `pasteConfiguration` for images and overrides `paste(itemProviders:)` and `paste(_:)` (the edit
  menu and ⌘V); a `UIDropInteraction` takes drag sessions that carry an image and no text, so a
  text drag keeps the system's text drop. In `paste(_:)`, while the pasteboard has a string, the
  ordinary text paste runs: a string never takes the image path (the Mac's rule).
  `paste(itemProviders:)` decides from its providers alone, never from a pasteboard, because a
  drop arrives there too and has none. Every provider starts loading at once (a drop session's
  providers are only good during `performDrop`); only the inserts run one after another. Each
  image is decoded and
  re-encoded with `UIImage.pngData()` off the main thread, then written with a coordinated
  `.withoutOverwriting` write to `<document folder>/images/<name>.png`. The name is
  `ImageFileNaming`'s (the item's suggested name, else `image`, sanitized and uniqued as
  `image-2.png` and so on); a name taken at the last moment is uniqued again, never replaced.
  The link (`ImageLinkRewrite.markdownDestination`) goes in on its own line at the start of the
  caret's line (`ImageInsertionText.insertingOnLine`, keeping CRLF) through `applyRuleEdit`, so
  it is one undo step and autosave sees it. The folder comes from `OpenDocument`, the editor's
  `ImageInsertionHost`: the open file's folder; for a document never saved, `flush` first
  creates its file through the autosave rules, and if that fails nothing is written or
  inserted and the save-failed notice shows. A blank document has nothing to be named from, so
  it gets the save folder, and the save right after the link creates its file there. Nothing is
  ever written outside the document's own folder or the save folder. When the image cannot be
  written there (the folder is not writable, as for a file opened from another provider where
  only the file is in scope), nothing is inserted and a short notice ("Can't save images beside
  this document.") shows for a few seconds; there is no fallback folder, because a link to an
  absolute path in the app's container would not travel with the document. An image lands only
  in the document that was open when its paste or drop started (`imageInsertionDocumentIdentity`,
  bumped when another document takes this one's place); otherwise its PNG is removed and nothing
  is inserted.
- **Stored properties.** `LineformTextView` comes from UIKit's `textViewUsingTextLayoutManager:`
  factory, on which Swift's property initializers never run: memory is zeroed instead, so a
  class-typed default reads as nil and an optional struct (`CGPoint?`, `NSRange?`) reads as a
  zero value, not nil. All editor state with a starting value lives in `LineformTextView.State`,
  made on first use behind the only stored property (an optional class reference, nil when
  zeroed). `EditorConstructionTests` reads every value through `init(usingTextLayoutManager:)`,
  `init(frame:textContainer:)`, `init?(coder:)` and `make(profile:)`.
- Chrome floats over the text. No bar spans the top of the page; the page colour runs edge to
  edge, and only the container safe area is ignored so the editor still resizes for the keyboard.
- Text set from code keeps the selection, clamped to the new text, so a live reload does not move
  the caret.

## Write, Read and Preview

Roadmap step 5 (plan `2026-11-21-iphone-read-and-preview.md` in the Lineform-mobile planning
folder). The three modes are the package's `EditorDisplayMode`, the same values and titles as the
Mac.

### The mode switch

- `ModeSwitch` (`Chrome/ModeSwitch.swift`) is the Mac's `EditorModeSegmentedControl`, value for
  value, kept as statics so tests read them: 78×30 segments, 3 pt padding, a 3 pt divider slot with
  1×18 dividers at 0.45 (only between unselected segments), 14 pt regular labels, an
  `.ultraThinMaterial` capsule with the Mac's light and dark fills, its 0.5 pt stroke and its shadow
  (black 0.035, radius 5, y 1). The selected pill moves with the liquid bridge: spring(0.24, 0.78),
  then after 0.16 s spring(0.30, 0.82). There is no hover on a phone, so the Mac's hover fill
  (0.48 of the selected fill) is the pressed state, shown while a segment is held: the pill is always
  drawn and its opacity animates with the Mac's hover, `easeInOut(LineformDesign.Motion.hover)`
  (0.12 s) through `EditorMotionPolicy`, so Reduce Motion turns it off. Its accessibility label is
  the Mac's "Editor mode".
- It floats at the top centre, 8 pt inside the safe area, over the page. There is no full-width bar.
  The editor and Read view get an extra 52 pt top `contentInset` (8 + 36 + 8,
  `ModeSwitch.pageTopClearance`) so the first line is never under the pill.
- Reduce Motion (`accessibilityReduceMotion`) skips the bridge and the animations, as
  `EditorMotionPolicy` does on the Mac. `Chrome/MotionPolicy.swift` is a copy of that type, because
  the package may not import SwiftUI.
- `DocumentScreen` keeps the mode in `@SceneStorage("displayMode")` (default Write), mirrored into
  `@State`: a screen hosted outside a scene (the tests) cannot write scene storage. Every switch
  writes both, so a Preview that iOS ends reopens in Preview. ⌘E on a hardware keyboard toggles
  Write and Read (the Mac's "Toggle Write / Read").

### Keeping your place across a switch

`ModePositionKeeper` records the source location at the top of the outgoing surface (the editor
for Write and Preview, the Read view for Read) and restores it on the incoming one a tick later,
only if no newer switch happened. Write uses `scrollCharacterRangeToTopPersistently` (8 pt margin,
re-asserted for 5 ticks, a touch stops it); Read uses `scrollSourceLocationToTop`; Preview moves
the editor through `SplitScrollJumpPlan` and, while linked, Read follows. Several switches in one
tick keep the first target and restore only the last mode; if the editor had the focus at the
first of them and the burst ends in Write, it gets the focus back. A scene restored straight into
Read gives Read the focus, so shake-to-undo routes. Both surfaces probe the top 14 pt down
(the Mac editor's `visibleTopProbeInset`), so a line parked 8 pt below the top reads as itself and
the position never drifts a line per round trip. The source↔rendered lookups are the package's
`SourcePosition` (`sourceLocation(atRenderedIndex:in:)`, `renderedIndex(forSourceLocation:in:)`),
the same code the Mac's split scroll uses.

The editor stays mounted in every mode. In Read it sits under the opaque Read view with no hit
testing and hidden from accessibility, and it applies Read's edits (below), so the document has one
undo history in every mode. The Read
view exists only in Read and Preview, so typing in Write never renders.

### Read

`LineformReadView` (`Read/LineformReadView.swift`) is a non-editable, selectable
`UITextView(usingTextLayoutManager: false)` showing `MarkdownPreviewRenderer`'s output. TextKit 1
for the same reasons as the editor, and because `HorizontalRuleAttachment` overrides only the
TextKit 1 attachment methods. Like the editor, it comes from UIKit's factory path, so all its state
lives in a lazily made `State` object (`testFactoryPathHasEveryDefault`).

- **Layout.** `EditorReadingLayout` at the sides, 32 pt top and bottom, line-fragment padding 0.
  The render column is `min(textColumnMaxWidth, the window's longest side)`, so rasters keep room
  for landscape.
- **Real display metrics.** It renders only once it is in a window, and every render passes
  `RenderDisplayMetrics(scale: traitCollection.displayScale, visibleViewportHeight: window.bounds.height)`,
  never the iOS placeholder default. A display-scale change re-renders. `apply(text:profile:documentDirectory:)`
  renders only when the text, profile, folder or scale changed.
- **Rotation and font size.** A width change captures the Mac's `ReflowAnchor` first (a view at
  the top stays pinned to the top), applies the width, refits block images with
  `BlockAttachmentRefit` (height capped by `ImageFit.maxHeight` of the visible height), rescales the
  table tab stops, then restores the anchor, again once in the next `layoutSubviews` because
  UITextView can pull the offset back while it grows `contentSize`. A profile change keeps the top
  passage by its source position.
- **Tables** are the iOS tab-stop rows (`docs/architecture/rendering.md`, platform seam). The view
  rescales their stops to `blockAttachmentFitWidth` on every render and width change, and draws
  the hairline grid behind the text. The row lines end at that fit width, and the column edges are
  the running sum of the renderer's column fractions (`.markdownTableColumnFractions`, from
  `fitColumnPercentages`, the numbers the stops are placed with) times the fit width, so no edge
  cuts a cell that fits its column, whatever the alignment.
- **Checkboxes.** A tap recognizer begins only on a checkbox glyph rect (`checkboxSourceRange(at:)`,
  the Mac's glyph hit test).
- **Copy and Reconnect pills** are `UIButton` subviews in content coordinates (so a scroll carries
  them), placed with the Mac's values: Copy a 26 pt circle 8 pt inside the column's right edge;
  Reconnect 22 pt high, radius 11, an 11 pt medium label, 8 pt after its run while it fits inside
  the reading column, otherwise 4 pt under the run, never past the column's right edge. They move after a render, refit, width or profile change. Copy slices the rendered
  source into `UIPasteboard.general`, shows a checkmark for 1.0 s, and never edits the document.
  Reconnect presents `.fileImporter` with the Mac's image types.
- **Images are local only.** Remote and `data:` URLs stay placeholders. Files load only from the
  document's folder or from a URL Reconnect's picker returned.
- **Accessibility.** `accessibilityCustomActions` mirror every pill and checkbox with the Mac's
  strings: "Copy code block %lld", "Reconnect image", "Toggle task: %@" and "Toggle task".
- **Bottom clearance.** Read, and Preview's lower pane, get a bottom `contentInset` of
  `DocumentScreen.bottomChromeClearance` (chromeMargin + 38 + 8 = 66 pt), applied like the top
  clearance, so the last line and its pill scroll clear of the Menu and link buttons. (The editor
  has no such inset; the buttons float over it as before.)
- **Position.** `onVisibleTopSourceLocationChanged` fires 0.08 s after scrolling stops.
  `scrollSourceLocationToTop` waits until the view is rendered, in a window and sized, parks the
  line 8 pt below the top and clamps to the laid-out end.

### Read edits go through `OpenDocument`

Read changes the document only through checkboxes and Reconnect; Copy never does.

- `OpenDocument.toggleCheckbox(at:renderedFrom:)` uses `CheckboxToggle.toggledText(in:at:)`. It
  also carries the source the view rendered, and refuses the toggle when that differs from the
  document's text: after typing in Write, the 0.12 s preview debounce can leave rendered ranges
  stale, and a stale range must never toggle another line. A nil result does nothing.
- `OpenDocument.reconnectImage(at:with:renderedFrom:)` uses `ImageLinkRewrite.linkPath(for:documentDirectory:)`
  and `rewritten(in:at:newPath:)`, relative to `documentDirectory` (the open file's folder). The
  screen captures the rendered source with the range when the picker opens, and a pick that
  returns after the text changed is refused. It keeps the picked URL's security scope until the
  document closes or detaches.
- Both hand the new text to the editor (`OpenDocument.readEditor`, `ReadEditApplying`), which
  applies it as ONE localized ranged edit through its rule-edit helper (`applyRuleEdit`, without
  scrolling), with its own undo registration; the editor's binding then calls `edit(_:)`, so they
  autosave like typing. Both keep every `\r\n`. Line offsets come from the renderer's
  attributes, never recomputed.

### Undo across modes

- A document has ONE undo history in every mode: the editor's. A Read edit is one step in it,
  with redo, in order with the typing around it; ⌘Z or shake undoes it in Write, in Read and in
  either Preview pane. `OpenDocument` has no undo manager of its own.
- The Read view's `undoManager` returns the editor's. It offers ⌘Z and ⇧⌘Z key commands itself
  (a non-editable text view has no undo of its own), and Read takes first responder when entered,
  so shake and ⌘Z reach it. In Write and in Preview's editor the editor answers them as usual.
- Only an outside replacement (a live reload, another file) clears the editor's undo:
  `MarkdownEditor` calls `setDocumentText`, so undo never puts older text over the new.

### Preview

`PreviewSplit` lays out all three modes. Preview is the editor over Read, each half of the height
above the keyboard, split by a hairline (theme ink at 0.15 through `readableInk`, ratio 1.5, at
1/displayScale). The editor keeps its caret visible when the keyboard resizes it
(`keepsCaretVisibleOnResize`). Read renders the text 0.12 s after an edit
(`LineformReadView.previewTextDelay`); any other change renders at once.

- **Linked scrolling** (`LinkedScroll`) matches the Mac: it copies the vertical distance from the
  top, clamped to the other pane's scrollable range, with no block mapping
  (`docs/architecture/editor-behavior.md` explains why), and an `isApplying` guard so a copied
  offset never echoes back. The distance is inset-normalised (`contentOffset.y +
  adjustedContentInset.top`) because the top pane sits under the status bar and the bottom one
  does not. The link is on by default; re-linking aligns Preview to Write; unlinking leaves both
  panes where they are. The Read pane reports to the link only its own scrolling (tracking,
  dragging, decelerating, a tap on the status bar) and explicit restores; an offset UIKit or a
  layout pass sets (render, refit, width change, content growing) never drives the editor. A Read
  pane entered before it had content aligns to the editor once after its first render, while
  linked.
- **The link button** (`PreviewLinkButton`) is a 38 pt circle with the `link` symbol, 12 pt left of
  the Menu button, in Preview only, with the Menu button's floating-card chrome. Linked it is
  systemBlue on a blue wash; unlinked it is struck through in the ink at 0.62. The press animates
  like the mode control's (every layer drawn, only opacities change). Labels are the Mac's
  "Link split scrolling" and "Unlink split scrolling".

## Styling sheet

Roadmap step 7 (plan `2026-11-22-iphone-styling-sheet.md` in the Lineform-mobile planning folder).

- **Button.** `StylingButton` is a 44 pt "Aa" circle with the Menu button's floating-card chrome,
  to the right of Menu (`[link (Preview only)] [Menu] [Aa]`). Its label is the Mac's "Reading
  Experience".
- **Sheet.** Page-coloured from the live profile's theme, corner radius `LineformDesign.Radius.modal`
  (20), detents medium and large, drag indicator, colour scheme forced from
  `Theme.usesDarkChrome` (never the system appearance). The page behind the medium detent is not
  dimmed and stays usable, so every change shows live. A Reconnect tapped there closes the sheet
  first, then opens the image picker (one view cannot present both). The sheet also sets
  `preferredColorScheme`, so its grabber and the Font menu follow the theme too.
- **Controls.** The Mac panel (`ReadingExperiencePopover.swift`), in its order and with its values:
  header "Reading"; "Themes" with the six preset cards in three columns; Font (the available
  grouped options, so Comic Sans, a Mac system font, never shows; a retired font shows the
  default); Font Size, Line Height, Block Spacing (Read / Preview), Letter Spacing and Column
  Width sliders (continuous, no steps); Reading Ruler and Typewriter Mode with their
  descriptions; Reset to Default (resets only the current preset). The ranges, the value wording
  and the visible font id come from the package's `ReadingExperienceControls`, which the Mac's
  panel forwards to, so the two cannot drift.
- **Not on the sheet.** The desktop panel has no separate theme picker, margins slider or High
  Contrast toggle (each preset carries its theme), so the iPhone sheet has none either. Automatic
  Dark Mode is a Settings row. Column width keeps the Mac's 460–1200 range ("Full" from 1160): on
  a portrait phone the 40 pt margin governs, and the setting shows in landscape.
- **Persistence.** Every control writes through `ReadingProfileStore` (`applyPreset`, `update`,
  `resetCurrentPreset`), per device in `UserDefaults.standard`, never synced. `DocumentScreen`
  observes the store, so the editor and the Read view restyle without a relaunch.
- **Slider drags on large documents.** Measured on 1 MB (Debug, simulator), one profile change
  costs: in Write, 4 ms for the base attributes and under 1 ms for the token pass, then about
  640 ms for the reading assists, because the restyle invalidates layout and placing the ruler or
  centring the caret lays out the whole prefix up to the caret; in Read, about 450 ms to render,
  390 ms to place the pills and 430 ms to lay out. So while a slider is held (`StylingDrag.isActive`):
  - `ProfileUpdateCoalescer` writes the store at most once per run-loop turn, with the newest
    value.
  - The editor restyles live, but `refreshReadingAssists` only hides the ruler and leaves the
    caret where it is.
  - `LineformReadView.apply` keeps the newest profile without rendering it or changing its
    insets.

  When the last held slider is released (drags are counted, so two fingers work), the final
  value lands in the store, and the drag stays active for one more main-queue turn: SwiftUI hands
  that value to the views after the write, so their last update is still deferred. Then
  `StylingDrag.didEndNotification` runs the assists and the render once, on the final value.
  While a drag is active the Read view also keeps laying out for the profile it rendered, so a
  scroll or rotation never re-wraps the old render at a new column. A sheet dismissed mid-drag,
  or the app resigning active (an interrupted touch may never report its end), ends every drag. What
  remains is the one catch-up at release and the same cost for a preset tap or a toggle on a
  1 MB document in Read. `StylingPerformanceTests` prints the numbers and asserts the structure
  (one store update per turn, no prefix layout during a drag, one render at its end).

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
  boundary, a 200-byte cap, a unique name compared case- and normalisation-insensitively). A
  line of nothing but image references is skipped, and a link counts as its text, so a pasted
  image never names the document; a document of only images is Untitled, and a title typed
  later renames it.
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

## First run

The first launch on a device shows `FirstRunOverlay` over the already-loaded blank document; every
later launch opens straight into a fresh Untitled document, as on the Mac.

- **The gate.** `FirstRunGate.shouldShowAtLaunch` reads the per-device flag
  `LineformiOSFirstRunCompleted.v1` in `UserDefaults.standard` (never iCloud key-value storage).
  `LINEFORM_SHOW_FIRST_RUN=1` forces it for QA (`SIMCTL_CHILD_LINEFORM_SHOW_FIRST_RUN=1` with
  `simctl launch`). The flag is set only when the writer reaches the document, so quitting
  mid-intro shows it again.
- **Restoration wins.** `DocumentScreen` shows the overlay only while `openDocumentBookmark` and
  `openDocumentPath` are both empty (`FirstRunGate.shouldPresent`), so a scene iOS ended with a
  document open reopens that document.
- **Tests.** The test host is the app, so `LineformiOSApp` skips first run under XCTest at the
  launch call site (`XCTestConfigurationFilePath`); the gate itself stays pure and is tested
  directly (`FirstRunTests`).
- **Stages** (`FirstRunStage`): `.line` → `.expect` → `.points` → `.done`. `.line` is
  `FirstRunLineView`, a `WKWebView` loading the Mac's bundled `FirstLaunchIntro/` folder (the same
  folder reference in both targets' Resources phases, never a copy). Its timer starts when the page
  has loaded, not when the view appears, because a cold WebKit start takes about a second to paint.
  `.expect` shows "What to expect", which fades out; `.points` shows the three points and Start
  Writing and waits. A tap or a sideways swipe skips ahead (a vertical drag scrolls the points at
  large Dynamic Type); Return and the VoiceOver "Continue" action do the same. Reaching `.done`
  marks the flag once, fades the overlay out and focuses the editor.
- **The web view** uses a non-persistent data store, allows only file URLs and cancels every other
  navigation without opening it, and takes no touches. A document-end user script localizes the
  tagline and restyles it for the phone (dark ink over the paper, pinned right and wrapping); the
  Mac files are untouched. WebKit is linked only by the iPhone target; the package purity test bans
  it there.
- **Reduce Motion.** The page shows the finished line at once (`prefers-reduced-motion`), `.line`
  holds for 1.2 s instead of 2.6 s, and every native fade is off.
- **Copy.** `FirstRunCopy` is the one place the heading, the three points and the button title
  live, keyed by their English in `LineformiOS/Localizable.xcstrings` (six languages; the
  translations still need a native speaker's check). The owner edits the wording there.

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
