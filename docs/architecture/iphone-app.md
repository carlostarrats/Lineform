# iPhone app

The iPhone app is the `LineformiOS` target in `Lineform.xcodeproj`. It shares the App Store
listing, bundle identifier (`com.lineform.app`), version and build number with the Mac app, and
links the same `LineformCore` package. Minimum iOS: 26.0. iPhone only
(`TARGETED_DEVICE_FAMILY = 1`); Mac Catalyst, "Designed for iPhone" on the Mac and visionOS are
all off, so the iPhone build of `com.lineform.app` can never run on a Mac.

This page covers roadmap step 3 (shell and files), step 4 (Write mode), step 5 (Read and
Preview, with the Write/Read/Preview switch), step 6 (the Menu sheet), step 7 (the Styling
sheet), step 8 (the selection row, the comment field, AI actions with their review, and
whole-document AI), step 9 (History and History sync), step 10 (export, print, share and read
aloud), step 11 (first run) and, from step 12 (polish and release), the performance budgets. The
rest arrive in later steps.
aloud), step 11 (first run) and, from step 12, Check for Updates, announcements, the review
prompt and App Intents. The rest arrive in later steps.

## Each app stands alone

No iPhone copy mentions or assumes a Mac. There is no account and no sign-in. iCloud being off is
a fully working state, never an error or a prompt.

## Target, scheme and tests

- Sources: `LineformiOS/` (`LineformiOSApp`, `DocumentScreen`, `OpenDocument`, `AppSettings`;
  `Menu/`: `MenuSheet`, `MenuSection`, `EditorCommands`, `FilesStore`, `FilesSection`, `FolderView`,
  `OutlineSection`, `BasicsSection`, `SearchSection`, `SearchController`, `DocumentSection`,
  `SettingsSection`;
  `Editor/`: `MarkdownEditor`, and `LineformTextView` in `LineformiOSTextView.swift`; `Read/`:
  `LineformReadView`, `ReadViewRepresentable`, `ReadOverlayButtons`, `PreviewSplit` and
  `LinkedScroll`; `Chrome/`: `ModeSwitch`, `ModePositionKeeper`, `MotionPolicy` and
  `StylingButton`; `Styling/`: `StylingSheet`, `StylingPresetCard`, `StylingRows` and
  `StylingDrag`; `Integration/`: `PhoneUpdateCheck`, `PhoneAnnouncementStore`,
  `PhoneAnnouncementCard`, `PhoneReviewPrompt` and `PhoneAppIntents`. Every name
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
- **Release resources.** `LineformiOS/PrivacyInfo.xcprivacy` (no tracking, no collected data;
  required reasons for UserDefaults and file timestamps) ships in the app's Resources; the Mac
  ships none. `PhoneReleaseResourceTests` pins it with the Info.plist submission keys, the ATS
  rule, the absence of usage descriptions, the icon, and one version and build across the Mac,
  Quick Look and iPhone targets. Release steps: `docs/release/app-store-release.md` ▸ iPhone.

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
re-asserted for 5 ticks, a touch stops it; it lays out the prefix through the target and one page
below it, never the rest of the document, and clamps to the end only when the document ends
inside that page); Read uses `scrollSourceLocationToTop`; Preview moves
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
  the reading column, otherwise 4 pt under the run, never past the column's right edge. They move after a render, refit, width or profile change. Pills and the
  table grid are placed only for the characters from a page above the visible one to a page below
  it (`overlayWindow`): measuring a run lays the text out down to it, so placing every pill laid
  out a whole 1 MB document (about 330 ms). When that stretch starts inside the laid-out prefix,
  the prefix is extended through it; past it, positions are TextKit 1 estimates (far off on a long
  document), so the whole text is laid out first, as before. A scroll or a height change (SwiftUI's
  first short pass, Preview's pane growing as the keyboard goes down) that shows characters outside
  that window places them again; Copy pills keep their number counted from the document's start. Copy slices the rendered
  source into `UIPasteboard.general`, shows a checkmark for 1.0 s, and never edits the document.
  Reconnect presents `.fileImporter` with the Mac's image types.
- **Images are local only.** Remote and `data:` URLs stay placeholders. Files load only from the
  document's folder or from a URL Reconnect's picker returned.
- **Accessibility.** `accessibilityCustomActions` mirror every pill and checkbox with the Mac's
  strings: "Copy code block %lld", "Reconnect image", "Toggle task: %@" and "Toggle task".
- **Bottom clearance.** Read, and Preview's lower pane, get a bottom `contentInset` of
  `DocumentScreen.bottomChromeClearance` (chromeMargin + 44 + 8, the tallest of the Menu, Aa
  and link buttons), applied like the top clearance, so the last line and its pill scroll clear of
  them. (The editor
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

## Performance budgets

`LineformiOSTests/PhonePerformanceBudgetTests` measures the iPhone's budgets on the 1 MB corpus
and gates each as a RATIO of two costs taken in the same run, never a wall-clock ceiling (other
builds share the machine, and CI is 2–4× slower). Each gate checks first that its document-scale
side takes a measurable time (over 1 ms), takes the best per-call time over several batches, and
puts the caret, the page or the review at the worst position for what it guards.
`testMeasureBudgets` prints every number; the numbers, the machine and the rulings are in
`docs/notes/iphone-performance-baseline.md`.

| Gate | Asserts | Why |
|---|---|---|
| `testKeystrokeIsScopedRatio` | a keystroke at the end (edit, scoped tokens, visible spell pass) ≥ 4× cheaper than a whole-document token pass | typing never reaches a whole-document pass |
| `testOpenDoesNotLayOutWholeDocument` | after an open, `firstUnlaidGlyphIndex()` < half the glyphs, and the open ≥ 2× cheaper than a full layout | an open lays out the first screen only |
| `testLaunchToTypableEditor` | launch ≥ 4× cheaper than a whole-document token pass, and at most 2.5× an open of 1 MB | an empty editor does no document-scale work |
| `testReadRepeatApplyIsCheap` | a repeat apply of unchanged text ≥ 10× cheaper than the first render | SwiftUI re-applies far more often than the text changes |
| `testModeSwitchBackToWriteIsScoped` | Read → Write, page at the top, ≥ 4× cheaper than a whole-document restyle | the restore lays out through its target and a page, never the rest |
| `testAIDecisionIsScopedRatio` | one accept ≥ 4× cheaper than a whole-composition present | a decision restyles only what changed |
| `testReadingAssistsLayOutThePrefixOncePerRestyle` | after a restyle, a caret move with the ruler on ≥ 10× cheaper than the restyle | the prefix layout is paid once per restyle (ruling below) |
| `testReadOverlaysDoNotForceWholeLayout` | page at the top: placing the pills and grid from a fresh layout ≥ 4× cheaper than a full layout; no pill or table far below the page is measured | the pills are placed for the page and its neighbours only (at the end of a fresh layout the whole text is still laid out, by ruling) |

`testScopedRestoreLandsWhereTheWholeLayoutRestoreDid`, `testIncrementalPresentDrawsWhatAWholePresentDraws`
(with `testIncrementalPresentMatchesForWholeLineRewritesAndCRLF`), `testWindowedOverlaysMatchTheWholeSet`,
`testOverlaysFollowAHeightOnlyResize` and `testPillsFollowAReRenderNearTheEnd` assert that the three
scoped versions show exactly what the whole versions did.

Two costs stay, by ruling. TextKit 1's position for a line past an unlaid stretch is an estimate,
far off on a long document (the last line of 1 MB: 335,817 pt estimated, 1,786,482 pt exact), so
anything that must place the caret's line exactly lays out the prefix through it once: the
Reading Ruler and Typewriter Mode after a restyle or an open (about 600 ms on 1 MB with the caret
at the end, never during a Styling drag), and the Read → Write restore when the target is near
the end of a document whose layout was invalidated in Read (about 550 ms). Write → Read renders
the whole document (about 460 ms) and lays it out for the position restore; it is reported, not
gated.

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

## Export, print, share and read aloud

The Menu sheet's document rows (`Export/ExportRows`), in the Mac's order: **Export As** (HTML;
the Paper Size picker, PDF and Styled PDF; Rich Text), **Print…**, **Share…**, and read aloud.
`ExportCommands` does the work; the screen makes it once (`DocumentScreen`).

### What each format contains

The content is the Mac's, built by the same package code (`ExportContent`, with the Mac's exact
renderer arguments; see `export-and-print.md`). Only the page machinery is the iPhone's own.

- **HTML**: `ExportContent.htmlData`, one-to-one with the source; only math and Mermaid pictures
  are embedded.
- **PDF (Normal)**: the raw Markdown source in a monospaced face (`ExportContent.rawSource`).
- **Styled PDF**: the document rendered the way Read draws it (`ExportContent.styled`), with
  tables fitted to the page, monochrome code, and local images from the document's own folder.
  Two known differences from the Mac's Styled PDF, both matching iPhone Read: code blocks have
  no background, and the table grid is Read's hairline grid (`LineformReadView.columnEdges`), so
  a line can cross wrapped cell text.
- **Rich Text**: `ExportContent.rtfData` (math and Mermaid as caption and source text).

The page is always white with the light ink, whatever the app's appearance: `PhonePageLayout`
draws inside a light `UITraitCollection`, so a dynamic colour such as a link's resolves light in
Dark Mode too (`testDarkModeDoesNotChangeTheExport`). The paper sizes are the Mac's six
(`ExportPaperSize`); the picker starts on the region's everyday sheet
(`ExportPaperSize.regionalDefault`) and keeps the pick for the session.

### Pagination: `PhonePageLayout`

The iPhone has no `NSPrintOperation` for a file. `PhonePageLayout` paginates with TextKit 1: one
`NSLayoutManager` and one page-sized `NSTextContainer` per page, added until every glyph is laid
out. `UIGraphicsPDFRenderer` writes the PDF pages; Print draws the same layout.

**No content is ever dropped.** A line taller than the page (a tall Mermaid chain, a tall image,
display math; a picture is one line) fits no container. TextKit then either leaves the container
and every later one empty, which would end the document at that line, or (as measured on the iOS
simulator) puts the line in clipped to the page height, which cuts the picture off. So:

1. Before pagination, every picture taller than 90% of the page (less its paragraph's spacing,
   over its line-height multiple), or wider than the page, is scaled down on a copy of the string.
   The render itself is never changed, because Print lays one render out for several sheets.
2. A page that still takes no glyphs, or whose first line fills it (for example a huge font), never
   ends pagination: that line gets a page of its own, laid out without a height limit and drawn
   scaled down to fit, and the rest of the document continues in a new layout on the next page.
3. A document that would need more than 2,000 pages fails (`init` returns nil, so the export shows
   its failure notice and Print shows no pages). A short PDF is never handed out as complete.

`pageCharacterRanges` lets tests assert the pages cover the document once, with no gap and no
overlap.

### Print

Print opens `UIPrintInteractionController` with `PhonePrintRenderer`: the Styled layout, like the
Mac's ⌘P, at the preset's 72 pt margins measured from the paper (inside the printer's printable
area).

**Threading.** UIKit calls `numberOfPages` and `drawPage(at:in:)` off the main thread. Logged under
the real print panel in the simulator: `numberOfPages` on
`com.apple.UIKit.UIPrintPreviewViewController.updatePageCountThread`, `prepare(forDrawingPages:)`
and `drawPage` on an unnamed secondary thread, never on main. So the overrides are `nonisolated`
and never hop to main (main can be waiting on the print system: a `DispatchQueue.main.sync` there
can deadlock). All main-actor work (the Markdown render) happens on main before UIKit asks: `init`
renders for the region's everyday sheet, which the panel starts on, and `renderRemainingSheets()`,
started by the row once the panel is up, renders each other offered column width, one per
main-loop turn. The overrides only lay out and draw those finished strings on the calling thread,
under one lock (a layout manager with no view is confined to one thread at a time, not to main).
They read the sheet through key-value coding, because the typed `paperRect` is main-actor
isolated in Swift. `testCountsAndDrawsOffMainWhileMainWaits` counts and draws on a background
thread while main is blocked.

**Sheets.** For a content rect, the best render is the offered sheet whose content width is the
widest that still fits the rect (so fitted tables and pictures never pass the margin), otherwise
the narrowest. Until that render is ready, the starting sheet's render is used. A render narrower
than the rect reflows its text to the full width (a landscape page). A render wider than the rect
(paper smaller than every offered sheet, such as a 4×6 photo) is laid out at its own width and
drawn scaled down. The layout is made again only when the rect or the render changes, and
`drawPage` always draws the layout `numberOfPages` counted.

### Share and the export folder

An export is written to its own new folder, `tmp/Exports/<UUID>/<name>.<ext>` (`PhoneExportWriter`),
so two quick exports never share a path. The name is the document's base name, sanitized: no `/`,
`:` or control characters and no leading dots, "Untitled" when nothing is left. The write is
atomic. The system share sheet opens for the copy (its Save to Files is how an export is saved),
and the whole `Exports` folder is deleted when that sheet closes and at launch, for a copy a share
sheet still held when iOS ended the app. A share sheet that UIKit would refuse to present (the top
controller is already presenting or is being dismissed) is not presented, and its cleanup runs at
once.

`ActivityShareSheet` is presented with UIKit over the top-most presented controller, not as a
SwiftUI `.sheet`: hosted that way, the activity controller's own dismissal took the Menu sheet down
with it and the share sheet vanished.

**Share…** hands on the document's own file, saved first (`OpenDocument.flush`). It is disabled
while an Untitled document has no file to come: nothing typed, or only spaces and Returns
(`DocumentNaming.baseName` is nil, so the autosave makes no file). A failed save closes the menu so
the screen's save notice shows; a failed export does the same for the export's calm notice.

### Read aloud

`ExportCommands` drives the package's `SpeechController` and follows the Mac's start rule
(`speechSource`): in Write and Preview a selection reads the selection and a caret reads from the
caret to the end; in Read (whose selection is in rendered coordinates) and with no selection it
reads the whole document. The rows are Start Speaking, then Pause Speaking or Resume Speaking, and
Stop Speaking. Speech plays through a `.playback` / `.spokenAudio` audio session, released when
speech goes idle.

Speech stops whenever the document swaps. `OpenDocument.onDocumentSwap` is a single-subscriber
closure called from `closeCurrentDocument()`, the one place every swap goes through (New Document,
an open from the list or Files, the download path, the launch restore); it does not fire on a first
save or a first-line rename. The screen sets it to `ExportCommands.documentWillChange`. It is the
only place read aloud is stopped on a swap, the iPhone's twin of the Mac's
`resetTransientDocumentState` rule.

### Parity with the Mac

`ExportParityTests` exports `LineformiOSTests/Fixtures/export-parity/corpus.md` and compares it
with `mac-expected.json`, recorded from the Mac's own exports: the same words in the Normal PDF,
Styled PDF and RTF, page counts within one of the Mac's on US Letter and A4, the same HTML apart
from the picture bytes, and upright math and diagrams. Words are compared as multisets. Two Mac
text-extraction artifacts are normalised: a table that `NSTextTable` splits over a page break is
read twice (deduplicated on the Mac side only; the iPhone's words must contain no repeated run),
and PDFKit reads "ll" as "l" (on both sides).

To re-record (after a deliberate Mac export change, or on a new macOS: the Mac test skips when the
JSON's macOS differs), run the Mac's hosted
`TEST_RUNNER_RECORD_EXPORT_PARITY=1 xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -testPlan LineformHosted -only-testing:LineformTests/ExportParityRecordHostedTests`.
The sandboxed test host writes
`~/Library/Containers/com.lineform.app.debug/Data/tmp/mac-expected.json` and fails with that
path; copy it into `LineformiOSTests/Fixtures/export-parity/` in its own commit.

## The Menu sheet

The floating `MenuButton` (bottom right, 44 pt, Mac floating-card chrome, accessibility label
"Menu") opens `MenuSheet`: a page-coloured card with radius `LineformDesign.Radius.modal` (20),
the floating-card hairline and shadow, medium and large detents. Its header shows the save state
and `DocumentStatusText.counts` ("%lld words — %lld characters", characters only for CJK). The
save state is "Saved" only while a file holds the text (`url != nil` and `text ==
lastSyncedText`), "Unsaved changes" in the autosave delay (or after a failed save), and the Mac's
"Not saved yet" for text no file holds: a new document before its first save, or one detached
after its file was deleted elsewhere (its next change, typed or on the way to the background,
saves it as a new document). The Mac's "Autosaved" is not used: it is the Mac's flash for an autosave
as against ⌘S, and every iPhone write is an autosave, so it would add nothing.

The section bar scrolls sideways: Files, Outline, Markdown Basics, Search, History (only while
the document has history), Document, Settings (`MenuSection`; raw values are identity, never
localized). The section is kept in `@SceneStorage("menuSection")` and starts on Files. History is
not a page: choosing it closes the sheet and enters History mode (see "History"), and it is never
kept as the scene's section.

### Files

`FilesSection` (with `FolderView` and `FilesStore`) is the iPhone's Files tree. It keeps the Mac's
rules (files-sidebar.md) and adds iPhone ones:

- **Top rows:** New Document, Open from Files…, the sort menu ("Sort folders by: %@", with Name,
  Date Created and Date Modified from the package's `OutlineFileSortOrder.title`) and a Show
  Hidden Folders toggle.
- **Roots:** iCloud ("Lineform", `<container>/Documents`) when the container resolves and
  `Lineform.settings.showICloudInSidebar` is on (followed live: turning it off drops the iCloud
  list, so turning it on never shows a stale one). **On My iPhone**, the on-device save folder,
  shows when iCloud does not resolve, because that is where new documents save then, and beside
  iCloud whenever it holds documents (saved before iCloud came on). Debug never resolves iCloud.
  Then the Workspace.
- **Lazy:** nothing is looked up, scanned or watched until the section, or a search across files,
  is on screen (`setVisible(_:for:)`, counted per client, so Search ending never hides Files;
  `scanIfVisible`). Scans run off the main thread with `OutlineFileScanner` (placeholders included
  under their real names, one row when the real file is there too; `.Trash` never, whatever Show
  Hidden Folders says), latest wins.
- **Re-scans:** a sort change and a Show Hidden Folders change both re-scan. One sort serves every
  root, stored under both Mac keys (`Lineform.outline.sortOrder.icloud` and `.workspace`).
- **Drill-down:** each level is one flat, lazy `List`; a folder pushes its own level onto a
  `NavigationStack` with the system slide. Rows are an SF Symbol (`doc.text` / `folder`) and the
  name, plus the date the list is ordered by under a date sort.
- **Actions:** files swipe to Rename (an alert with a text field and the shared `FileRenaming`
  rule) and Delete (a confirmation, Cancel as default, "It will be moved to the Trash."). A long
  press offers the same, and Rename alone for a folder. Folders are never deleted. A rename of
  the open document saves it first; when that save renamed the file from a new first line, the
  rename moves the file where it is now.
- **Coordinated:** rename and Trash go through `NSFileCoordinator` with `.forMoving` (rename also
  announces `item(at:willMoveTo:)` / `didMoveTo`), on the main actor like OpenDocument's own
  writes. The open document follows a rename (`OpenDocument.userRenamed(to:)`, which stops
  automatic renaming) and lets go of a trashed file (`fileWasTrashed(at:)`); its presenter hears
  both too. Trash is `FileManager.trashItem` only: a refusal shows "Couldn’t move “%@” to the
  Trash." and the file stays. There is no `removeItem` path.
- **Workspace:** chosen with `.fileImporter(allowedContentTypes: [.folder])`; a plain
  `bookmarkData()` is kept under `Lineform.outline.workspaceBookmark` (per device). It is
  re-resolved at launch and refreshed when stale; a bookmark that cannot be resolved or refreshed,
  or a folder that is gone, shows "Workspace folder unavailable" with Change and Choose. The
  security scope is held for the store's lifetime, and `FilesStore.shared` lives as long as the
  app, so documents opened from the Workspace stay readable after the sheet closes. An empty
  Workspace names the scanned folder ("Scanned folder: %@").
- **Watching:** one `DocumentFolderMonitor` per visible root while Files is on screen. A folder
  presenter hears coordinated changes in its subfolders too (`testSubfolderChangeRefreshes`), so
  no per-subfolder monitor is needed.
- **iCloud placeholders:** listed under their real names; tapping one opens it through
  `OpenDocument`, which downloads it first. They have no Rename or Delete (the store throws
  `.notDownloaded`) until they have downloaded; see files-sidebar.md. The whole tree is not kept downloaded (unlike the
  Mac's `ensureDownloaded`): phone storage is the writer's.

### Outline and Markdown Basics

- **Outline** (`OutlineSection`, `OutlineModel`): the heading tree of the current text
  (`MarkdownOutlineParser` and `MarkdownOutlineTree`), one row per heading, indented by its depth
  in the tree. It is built at once when the section opens and rebuilt 0.3 s after the text
  changes; each change restarts the wait. Tapping a heading dismisses the sheet first, then calls
  `EditorCommands.scrollToCharacterRange`, which puts the heading at the top of the surface on
  screen in the active mode (Write, Read, or both Preview panes) through `ModePositionKeeper`. It
  does not move the selection. With no headings, the section shows the Mac's "Add # Title or
  ## Section to build an outline."
- **Markdown Basics** (`BasicsSection`): the package's `MarkdownReference` sections in a plain
  `List`, with the Mac view's section headers and row layout (the syntax, monospaced for a code
  row, over its explanation). Tapping a code row copies its `copyAffordance` text to
  `UIPasteboard` and shows "Copied" on that row for 1 s. Label rows (Tab, Block Spacing, Spelling,
  …) have no `copyAffordance`, so they are not buttons and copy nothing. VoiceOver reads one
  element per row (`Row.accessibilityLabel()`).

### Search

`SearchSection` and `SearchController` (`@MainActor @Observable`). The field sits at the top, with
the All / In document / Files filter under it. While the query is empty the section shows "Search
this document and your files."; typing fades that out and the results in. The results, in order:
this document's matches (snippet, "In document" on the right), file-name matches
(`QuickOpenIndex`, the folder on the left and the file's name on the right), then matches inside
other files (`CrossFileSearchModel`, snippet and the file's name). The Replace row (field,
Replace, Replace All) shows for All and In document and acts on this document only. A quiet status
line gives the count, "Searching…" or "No matches". Candidates come from `FilesStore`'s current
roots; the first query that needs them makes the store visible and scans it (never at launch), and
leaving the section stops it again. Tapping an in-document match dismisses the sheet and selects
the match; tapping a file opens it and, for a content match, selects the first hit at or after the
snippet's location in the opened text; that open's task holds the editor and the match, not the
controller, so the match is selected after the sheet is gone. The controller is made once, when
the section first appears (`@State`, never in `init`), and the fields write straight into it as
the writer types, so Replace and Replace All always act on what the fields show. Leaving the
section ends only Search's hold on the store (`setVisible(false, for: .search)`). Every Mac rule
from search.md carries over; see the iPhone Search paragraph there.

### Document

`DocumentSection`, in order:

- New Document and Open from Files…, as in Files.
- **Save As…** (the Mac's "Save As..." with the iPhone's ellipsis) moves the document to a file
  the writer places, as the Mac's Save As retargets its `.md`; it is not an export. See "Save As".
- Insert Table and Reformat Table, for Markdown only (the Mac shows its formatting commands for
  Markdown only too). Each closes the sheet so the change is seen.
- **Convert to Plain Text / Convert to Markdown.** The title follows `OpenDocument.textFormat`
  (`DocumentSection.conversionTitle`, the Mac's strings). The state machine is the Mac's
  `LineformDocument.convertMarkdownToPlainText` / `restoreConvertedMarkdown`, verbatim, in
  `TextFormatConversion`, over the package's `MarkdownPlainTextConverter` (lines split on `\n`
  only, never `CharacterSet.newlines`; fenced code and display math verbatim). The new text goes
  through the editor (`applyReadEdit`), so a conversion is ONE undo step. Convert to Markdown
  restores only while the converted text is unchanged; otherwise the document stays plain text
  and forgets the conversion. A `.txt` file opens as plain text with nothing to restore, so the
  row is off for it; New Document is Markdown. Every iPhone write is the text verbatim, so a
  converted `.md` saves as its plain text. The command converts the whole document: a Write
  selection is not on screen under the sheet. The sheet stays open, so the new title shows.
- **Check Document Now** closes the sheet and runs `SpellCheckPass` once over the prose of the
  whole document (`misspelledRangesInWholeDocument`), whether or not Check spelling while typing
  is on, as the Mac's command does. Every misspelling is underlined, and the first one after the
  selection (wrapping) is selected and brought to the top of the surface on screen. It is the
  only whole-document spelling pass, and it is never scheduled. With Check spelling while typing
  off, its underlines last until the next edit, which clears them.
- **Ask AI…** follows Check Document Now while an AI is connected and Write or Preview is on
  screen (`DocumentSection.showsAskAI`; the row observes `AIConnectionStore`, so connecting in
  Settings shows it). It closes the sheet and opens the comment field for the whole document,
  after the shared length policy (see "Ask AI for the whole document").
- Show Hidden Folders, the Files setting (`FilesStore.setShowsHidden`, `Lineform.outline.showsHiddenFolders`).
- Lineform Guide, Privacy Policy and Terms of Use open in Safari (`openURL`) at the package's
  `LineformLinks`, which the Mac's Help menu also forwards to.
- Export As, Print…, Share… and read aloud follow Check Document Now as their own section
  (`ExportRows`, roadmap step 10; see "Export, print, share and read aloud").

### Save As

`SaveAsPicker` (`LineformiOS/Menu/SaveAsPicker.swift`) and two `OpenDocument` calls:

- `prepareSaveAs` saves the pending text first (`flush`, so an Untitled document gets its file in
  the save folder by the ordinary autosave rules), then writes the text's exact bytes
  (`MarkdownFileCodec`: a BOM and CRLF survive) under the file's name into a fresh
  `tmp/SaveAs/<UUID>/` folder. The row is off while an Untitled document has nothing to name it
  (`canSaveAs`, the same rule as Share). A failed save closes the menu so the save notice shows.
- The system export picker, `UIDocumentPickerViewController(forExporting: [copy], asCopy: true)`,
  places that copy. It is presented with UIKit over the Menu sheet, like `ActivityShareSheet`. Its
  "Save as" name is editable, and its own "Replace?" covers a file already there. The picker
  raises if the staged file does not exist, so the copy is always written before it opens.
- `adoptSaveAs` moves the document to the picked URL: it stops watching the old file, releases the
  old file's security scope, holds the new file's scope (a place outside the app), watches the new
  file, and plans autosave as an opened file (`isNamedFromFirstLine` false: the writer chose the
  name). From then on every save goes to the new file; the old file is left as it was. Text that
  changed while the picker was up (a reload) is saved to the new file at once. A copy made for a
  document that another one has since replaced (`documentIdentity`) is refused. Picking the
  document's own file (Replace in its own folder) keeps the document where it is. The format
  (Markdown or plain text) does not change, because the text does not.
- Cancel changes nothing. `tmp/SaveAs` is deleted when the picker closes, either way, and at
  launch.

The Mac refuses a Save As onto a file open in another tab; the iPhone has one document, so there is
nothing else open to refuse. The bytes reach the new file through the picker's copy rather than
through `coordinatedWrite`; every later write is the ordinary coordinated autosave.

### Settings

`SettingsSection` over `AppSettings` (an `ObservableObject`, `AppSettings.shared` on
`UserDefaults.standard`). Each value is per device, under the Mac's `Lineform.settings.*` key
(`LineformSettingKeys`), on by default, and loads through `Published(initialValue:)`. The notes
are worded for iPhone: no iPhone string names a Mac or a sidebar
(`SettingsTests.testNoMacOrSidebarWordingInIPhoneStrings` sweeps the catalog's English).

- **Automatic Dark Mode** (`automaticDarkMode`). `DocumentScreen` draws with
  `AppSettings.displayProfile`: the Mac's `ReadingProfile.displayProfile(automaticDarkMode:systemIsDark:)`,
  with "dark" read from the trait collection's `userInterfaceStyle` (SwiftUI's `colorScheme`). In
  Dark appearance a light theme draws as Quiet; Quiet and Night keep their own. The page, Read,
  the Menu button and the sheet re-render when the appearance changes. The stored profile keeps
  the writer's theme.
- **Show iCloud in Files** (`showICloudInSidebar`, the Mac's key): the Files root for Lineform's
  iCloud folder. New documents still save there.
- **Check spelling while typing** (`checksSpellingWhileTyping`): `MarkdownEditor` hands it to
  `LineformTextView.checksSpellingWhileTyping`. Off, no typing pass is scheduled or run and the
  underlines clear; on, a pass is scheduled.
- **In-app notifications** (`checksForAnnouncements`): it gates the announcement request itself,
  and turning it off takes a card on screen away (see "Announcements").

- **Connect Your AI…** (`ConnectAISheet`) connects Claude, ChatGPT, Google or Other, one provider
  at a time, with the Mac's `ConnectAIPresentation` and `AIConnectionStore`. The key is kept in the
  Keychain (service `<bundle id>.ai`, not synchronizable); connecting deletes the other providers'
  keys. Its note says what is sent: "Only the passage you select is sent, or the whole document
  when you choose Ask AI for it, with any comment you type. For Find, that is each whole sentence
  your selection touches, or every sentence of the document. Nothing is sent until you choose an
  action." Package text that named a Mac has iPhone variants (`billingNote(.other)`,
  `reconnectMessage`, `AIConnectError.insecureAddress`).
- **Clear History** (the Mac's row, note "Removes saved versions for every document. Your files
  are not changed.", button "Clear…" and destructive confirmation "Clear all history?"):
  `SettingsSection.clearHistory(store:)` → `PhoneHistoryController.clearAllHistory(in:)`, the same
  path as the Mac (see "History").

- **Check for Updates…** (the Mac's title, last row, note "Asks the App Store whether a newer
  version of Lineform is out. Nothing about you or your documents is sent."): see "Check for
  Updates".

### Markdown Basics on iPhone

`MarkdownReference` has iPhone wording behind `#if os(iOS)`, in all six languages: "Tap it in
Read to toggle" for a done task (the Mac says Click), the heading shortcuts marked "with a
keyboard", the table row pointing at Document (the Mac names ⌃⌘T and ⌃⌘R), and the Search row as
"Tap" (the iPhone's search field has no Return-to-next). The Mac's text is unchanged
(`MarkdownReferenceSectionsTests.testIPhoneWordingSpeaksToTouch` pins both).

### Editor commands

Sections act on the editor only through `EditorCommands`, which the screen implements over the
live editor (`LiveEditorCommands`): top-aligned scrolling through `ModePositionKeeper` in the
current mode, selection, Insert and Reformat Table, Check Document Now, and `replace` /
`replaceAll`, each ONE undo step through `applyRuleEdit`. `replaceAll` rewrites one span from the first range to the last and
copies the text between the ranges through unchanged, so line endings survive.
`DocumentScreen.bottomChromeClearance` uses the tallest bottom-right button: Menu and Aa are
both 44 pt (the link button is 38), and they share one row (`bottomChromeSpacing`, 12 pt).

## History

Per-passage History on iPhone (roadmap step 9) is the Mac's feature on the Mac's engine and store:
`PhoneHistoryController` (`LineformiOS/History/`) is the Mac's `DocumentHistoryController` without
AppKit, over the package's `DocumentHistoryEngine`, and the store is the Mac's
`RoutingPassageHistoryStore` (platform `iphone`): a document in the Lineform iCloud folder keeps its
History in the container's `History/v1/` and so shares it with the Mac (the merge, tombstones,
moves and Clear History are in `editor-behavior.md` § History, Sync); every other document's
History is local to this iPhone. History never writes into the document file.

- **Nothing at launch.** `PhoneHistoryController.sharedStore` is the package's `LazyHistoryStore`
  (the Mac's is too): the app's `OpenDocument.live()` is built at launch, but the router is made at
  the store's first use — the first document opened with a file, or Clear History — and the device
  name (`iphone-<UUID>`, in the Keychain for this device only, never restored onto another iPhone)
  is read only when a document in the Lineform iCloud folder first uses History. The session's one
  prune runs at that first open, on a background queue
  (`HistoryModeTests.testTheLiveDocumentMakesNoHistoryStoreAtLaunch`).
- **Shared writes never block the editor.** Saves, moves and Clear History of shared History run on
  the shared store's queue, coalesced; a load never waits for a record iCloud has not downloaded
  (it merges at a later load). When iOS has evicted this iPhone's own record
  (`.iphone-<UUID>.json.icloud`), the save is held (load still shows it) until the record is back,
  never written over it unread (`editor-behavior.md` § History, Sync).
- **Lifecycle.** `OpenDocument` drives the controller: open, close before a swap, persist after a
  save, `documentGotFile` when an Untitled document is first saved, `fileMoved` for the first-line
  rename, a user rename, a presenter move and Save As, `documentReloaded` for live reload (History
  mode ends without the collapse), and close when the file is deleted or trashed elsewhere.
- **Edits.** Every character change reaches History from ONE text-storage hook
  (`didProcessEditing`, `.editedCharacters`), in pre-change coordinates, TRIMMED to the minimal
  changed span (`HistoryUndoCollapse.unambiguousEdit`, the Mac's per-edit trim — a change in
  repeated text reports the union of its placements, so a passage there is dropped, never left on
  the wrong copy): an undo, redo or grouped
  edit reports its whole range even where nothing changed, and the engine drops every passage an
  edit straddles. The storage has already changed when it reports, so the hook keeps a copy of the
  text while History is attached (`State.historyShadowText`, kept in step by each report; out of
  step it is remade and the edit is a whole-text replacement). History's own edits run in
  `performHistoryEdit` and are not reported; `setDocumentText` and edits over 1 000 UTF-16 units are
  whole-text replacements (`LineformiOSTextView+History.swift`,
  `HistoryEditReportingTests.testAWideEditIsTrimmedToWhatChanged`).
- **Entry points (D10, D11).** Menu ▸ **History** closes the sheet, ends any AI work
  (`SelectionController.endAIForHistory`: a review ends keeping what was accepted, then a request,
  marks or a message go — the Mac's History tab), switches to Write and enters History mode
  (`HistoryEntry.enterFromMenu`; a passage an AI accept left is selected). **Replace With…** is the
  selection row's button, its ONE entry point (the system edit menu carries only spelling),
  offered only outside History mode and where the Mac offers it
  (`LineformTextView.offersReplaceWith` → `PhoneHistoryController.canAdd`: one line, no front
  matter, fenced code or math). It ends a request or review and dismisses Find's wash first
  (`AIActionController.yieldToHistory`, the Mac's show-History path), keeps the selection as the
  passage's original, enters History mode on it, and the card opens "Type a replacement" with
  focus; leaving without a replacement discards the passage (Mac parity). History mode is Write's:
  entering it from Preview switches to Write, and switching to Read or Preview leaves it (with the
  collapse).
- **AI and History** (the Mac's semantics, `AIHistoryRecording`): `PhoneHistoryController` is the
  AI controller's History, assigned once by `DocumentScreen` (`selection.aiHistory =
  document.history`). AI is unavailable in History mode (`allowsAIAction`; the editor is read-only,
  so neither the row nor Menu ▸ Document ▸ Ask AI… shows). History records ONCE, when a review ends:
  one passage per changed paragraph, the original and the AI's text. Abandoning (a live reload,
  another document, the controller's `abandon`) records nothing (`PhoneAIHistoryTests`).
- **The editor in History mode.** Read-only (`isEditable` false, so the keyboard goes); a tap
  selects the innermost passage under it (shortest range, then the finer level) and a tap on
  ordinary text returns to the overview; the page keeps `historyCardClearance` (300 pt) below its
  last line for the card. Hardware keyboard: ← / → step the selected passage, Esc deselects, then
  leaves; a printable key leaves History mode (with the collapse) and types. ⌘Z and shake find an
  empty stand-in undo manager while History mode is up; leaving collapses the session into ONE
  undoable edit plus a version-restore undo action, as on the Mac.
- **The wash (phone exception).** Every located passage is drawn as a rounded box with the Mac's
  `HistoryPalette` fills and depth layering (`HistoryWashDisplay`, the Mac's `layerFills` without
  hover): the overview wash stacked per depth; with a passage selected, it is blue, passages inside
  it add ink layers, and every other passage takes the focus-other fill. The boxes are
  `CAShapeLayer`s in `HistoryWashView`, a subview BEHIND the text container's view (above the
  Reading Ruler), built from TextKit 1 line fragments like the spelling underlines — never text
  attributes (`HistoryModeTests.testWashIsNeverInTextStorage`). **Exception:** the Mac also recedes
  the ink outside the selected passage with layout-manager temporary attributes; iOS TextKit 1 has
  no temporary attributes, and a storage colour change would churn highlighting and undo, so the
  phone draws the wash only. Full ink on every fill is AA in every theme (`HistoryPaletteTests`).
- **The card** (`HistoryCard`): at the bottom, above the keyboard and the home indicator, full
  width inside the 20 pt chrome margin, in the floating-card chrome (page colour, hairline, shadow,
  radius 12); the Menu and Aa buttons are hidden while it is up. With nothing selected it reads
  "Tap a highlighted passage to see its versions."; with a passage selected: the level switcher
  (only when its group has more than one level), the versions (the original a page, the writer's a
  pencil, AI a sparkle, the current one bold with a checkmark; a tap makes one current; Delete from
  History on its context menu and as a VoiceOver action), and the "Type a replacement" field (its
  return button is "Add"). Done leaves History mode. Each row's VoiceOver label is the Mac's ("…, by
  you, version 2 of 3"), and every step, level change or new selection is announced with the Mac's
  "Sentence, version 2 of 3" (`UIAccessibility.post(.announcement)`).
- **Clear History** (Settings): the store's `clearAll()`, then `didClearAllNotification`; every
  controller on the store re-reads it, replacing its engine BEFORE leaving History mode (leaving
  saves).
## The selection row and comment field

`LineformiOS/Selection/` (`SelectionController`, `SelectionRow`, `CommentField`), drawn by
`SelectionBottomChrome`, an overlay on `DocumentScreen`. The spec is §5.5.

- **When it shows.** `SelectionController.settleDelay` (0.35 s) after a non-empty selection stops
  changing; it hides at once when the selection collapses. It needs an editable editor in a
  window, no marked text, and no AI request or review in progress. The app's own selections
  (`selectProgrammatically`: Search, Check Document Now, a position restore, the AI's collapse)
  never raise it. It hides on a switch to Read.
- **Order**, scrolling sideways: Ask AI (only while connected, titled with the AI's name: "Ask
  Claude"), Heading ▾, Bold, Italic, Strikethrough, Code, List ▾ (Bulleted, Numbered), Link,
  Blockquote, Replace With… (History's, the Mac's meaning: the selection becomes a passage and
  History mode opens on it with "Type a replacement"; only where History can keep the selection —
  see "History", Entry points), and Another Word (one word only, and only while connected).
- **One button, one undo step.** Each formatting button calls the editor's own command, which goes
  through `applyRuleEdit`. The row then adopts the resulting selection instead of hiding.
- **Placement.** Above the keyboard, or above the home indicator when it is down: bottom padding
  = `max(0, keyboard overlap − safe-area bottom) + 12` (`SelectionRowPlacement`), from the keyboard
  frame notifications. The overlap lives in its own `SelectionKeyboardTracker`, observed only by
  the bottom chrome: publishing it from the controller re-rendered the screen in the middle of an
  undo and broke the editor's undo grouping. The editor's insets are never touched. The row
  replaces the Menu, Aa and link buttons while it shows. The system edit menu is not changed: it
  floats at the selection, and the row sits at the bottom.
- **The comment field.** Ask AI swaps the row for a full-width card with no drag handle: the
  title and Cancel, the note (a plain `UITextView`, where Return inserts a newline; it grows to
  120 pt, then scrolls), the Action menu (`SelectionToolbarPresentation.actionGroups`, Custom
  first and the default) and Send. Send needs a note for Custom (`canSend`) and is off while an
  input method is composing, so Return during Japanese input only confirms the candidate. Cancel
  with the button or a swipe down of 60 pt or more; the selection comes back. Send runs the shared
  `AIActionController` on the range the row was shown for (`anchorRange`).
- **Any change closes the field** (the Mac's card closes on any click): an editor text change
  (`editorTextDidChange`, from `textViewDidChange`), a selection change, or an outside replacement
  (`editorTextWillBeReplaced`: a live reload, Open, Save As, Convert). It hides with nothing sent
  and no selection put back. Backstops: the field snapshots the text when it opens, and a
  selection's Send is refused (the field closed) if the text differs; a whole-document Send runs
  `WholeDocumentAIPolicy` again (above the confirmed count it asks again, the field kept; past the
  limit it refuses on the message card).

## AI actions and the review

`LineformiOS/AI/` (`LineformiOSTextView+AI.swift`, `AIReviewOverlay.swift`, `AIReviewCardsView.swift`),
wired by `SelectionController`. The controller is the shared `AIActionController`, made on first
use (nothing at launch); `SelectionController.wireAI` gives it the editor and History, and History
is ONE assignment, `aiHistory`: the document's `PhoneHistoryController`, set by `DocumentScreen`.

- **The surface.** `applyAIEdits` is ONE undo group on the editor's undo manager, each edit through
  `applyRuleEdit` (a localized `textStorage.replaceCharacters` with its registration, then the
  delegate's `textViewDidChange`, so the binding and autosave hear it), named
  `AIActionController.acceptOneActionName`. Never a whole-text replacement; an edit that splits a
  composed character or touches a line ending / BOM is skipped. `collapseSelectionForAI` sets the
  caret as the app's own selection.
- **Read-only review.** `refusesEditForAI` blocks every path while `isAIReviewActive`: the
  delegate's `shouldChangeTextIn` (typing, Return, dictation), `insertText` / `deleteBackward` /
  `setMarkedText` / `replace(_:withText:)` / `cut` / `paste` overrides, image paste and drop,
  `applyRuleEdit` (formatting, Read's checkbox and Reconnect via `applyReadEdit`, Search's Replace
  and Replace All). A refusal says the review's status again ("1 change suggested") through
  `SelectionController.editRefusedDuringReview`. `isAIReviewActive` and Mark's ranges follow the
  controller's state in `SelectionController.aiStateChanged`, which runs in `willSet`, before the
  controller's `didSet` collapse.
- **Leaving a review.** Every path collapses to `caretEnd` (the controller's `didSet`). A switch to
  Read ends a review (keeping what was accepted) and drops a request or marks
  (`displayModeDidChange`); an outside text replacement abandons (`editorTextWillBeReplaced`),
  applying and recording nothing. Read allows no AI: the row's Ask AI and Another Word are absent.
- **The overlay.** `AIReviewOverlayTextView`, a TextKit 1 `UITextView`, not editable or selectable,
  with its own EMPTY undo manager, laid over the editor (an overlay on `MarkdownEditor`: Write, or
  Preview's top pane; below the chrome) with the editor's text container inset, content inset,
  padding and page colour. Its storage is its own, so the strike, receded ink, review tint and
  re-inked runs are ordinary attributes there (the document's storage never sees them). It takes
  the editor's scroll position BY CHARACTER on make and hands it back on dismantle (the Mac's
  `topAnchor`); it scrolls on its own meanwhile. It takes the keyboard focus (the software keyboard
  goes down) and gives it back if the editor had it. Hardware `UIKeyCommand`s: Return accepts, Esc
  rejects, ← / → move. A typed hardware key is refused. A tap on a pending change selects it.
  VoiceOver: "Suggested changes", value = the composition, custom actions Accept / Reject Change,
  Accept All, Next / Previous Change (2+ pending), End Review.
- **A decision restyles only what changed.** With the same profile, `present` replaces the one
  span where the new composition's string differs from the one on screen and restyles (base,
  tokens, strike and tint) only the whole lines touched by that span and by every change whose
  look changed (accepted, rejected, made current or no longer current). Everything else keeps its
  attributes, moved with its text, so the layout before the span stays valid. A whole present
  (first show, a new profile) is unchanged. Restyling the whole composition cost about 680 ms per
  accept on 1 MB, most of it `revealCurrentChange` laying the restyled overlay out again;
  incrementally it is about 3 ms, attribute for attribute the same drawing.
- **Cards** (`AIReviewCardsView`), at the bottom above the keyboard or home indicator, placed by
  `SelectionBottomChrome` from the keyboard tracker; the Menu and Aa buttons step aside only while
  a request is running or a review is up (`SelectionController.showsBottomButtons`). A message or
  Mark's card sits above them (`DocumentScreen.bottomChromeClearance`), so both stay reachable. Running (spinner, progress text, Stop), message (✕, gone after 8 s), Mark (count, Done),
  review (`AIReviewCardPresentation.title`, Try Again, Reject, Accept, Next and Accept All for 2+
  pending, Done = end). No Esc / Return hints. The card's top is measured
  (`AIReviewCardTopKey`) so the overlay reveals the current change above it.
- **Mark's wash.** TextKit 1 on UIKit has no temporary attributes, so the wash is a `CAShapeLayer`
  filled with `HistoryPalette.markWash` (resolved for the view's traits), the editor's LOWEST
  sublayer (behind the text), from the layout manager's enclosing rects, redrawn in
  `layoutSubviews` like the spelling underlines. A real edit dismisses the marks.
- **The app's own selections.** `selectProgrammatically` (Search and Check Document Now via
  `LiveEditorCommands.selectRange`, `setDocumentText`'s restore, the AI collapse) marks the
  selection as the app's; `SelectionController.editorSelectionDidChange` never raises the row for
  it (`isSelectionProgrammatic`), and forgets it at the writer's next selection. The writer's own
  next touch on that selection (`hitTest` → `writerTouched(at:)`, within 22 pt of its rects) or a
  key (`pressesBegan`) also makes it theirs, and the row can rise for it.
- **Focus back after a review.** On dismantle the editor takes the focus again, which would scroll
  it to the caret (at the change's end); the handed-back position is held instead
  (`AIReviewOverlay.offsetHoldDelays`), unless the writer scrolls.

### Ask AI for the whole document

Menu ▸ Document ▸ Ask AI… (the Mac's Edit ▸ Ask AI… with nothing selected). The row closes the
sheet; the sheet's `onDismiss` then runs `SelectionController.askAIForWholeDocument`, because a
confirmation cannot be presented over a closing sheet. The shared `WholeDocumentAIPolicy` decides
first, on the prose that would be sent:

- up to 1,500 words, the comment field opens for the whole document;
- above that, a `UIAlertController` (`WholeDocumentConfirmationAlert`) asks "Send the whole
  document (N words) to …?", with Send and Cancel; Cancel is the `preferredAction`, as on the Mac.
  The pending count clears however the alert goes away (its `viewDidDisappear`);
- past `AILimits`, the refusal ("Select a part of the document — about 4,000 words at most.")
  shows on the message card. Nothing opens or is sent, and the Keychain is not read.

The row shows only for a document with text (`DocumentSection.hasText`). The field's range is the
whole text (`anchorRange`, `isWholeDocument`), nothing is highlighted, the card's quiet subtitle
says "Whole document" (`SelectionToolbarPresentation.wholeDocumentSubtitle`, as on the Mac), and
Cancel puts the caret back. Send runs `AIActionController.runWholeDocument`, which checks the
policy again before `resolvedConnection()`. The review is the same overlay and cards. Tests:
`WholeDocumentAITests`. Details for both apps: `editor-behavior.md`, "Whole-document AI".

## Check for Updates

Menu ▸ Settings ▸ **Check for Updates…** is the Mac's Lineform ▸ Check for Updates… on iPhone
(`PhoneUpdateCommand`, `LineformiOS/Integration/PhoneUpdateCheck.swift`). An App Store app cannot
update itself, so it only says whether a newer version is on the App Store and offers its page.

- **Only on a tap.** Nothing calls it at launch or on a timer. A tap while a check runs, or while its
  alert is up, is ignored (`isChecking`, reset on every path); the row shows a spinner meanwhile.
- **The iPhone's listing.** The package's `AppStoreUpdateChecker` asks the catalog of the platform it
  runs on (`AppStorePlatform.current`): the Mac `entity=macSoftware` (unchanged), the iPhone
  `entity=software`. The one listing serves both, but the lookup answers per platform, and the
  iPhone reads only an entry whose `kind` is "software". Checked by hand on 2026-11-23, before any
  iPhone build was on the store: every lookup form, `entity=software` included, answered with the
  Mac's `mac-software` entry. Read as the iPhone's, that would offer a Mac-only version and open the
  Mac page, so it is "couldn't check" instead. Every other rule is the Mac's (`app-integration.md`
  ▸ Check for Updates): the fixed bundle id, the privacy shape, hostile-input validation, only a
  strictly newer version offered, a failure never "up to date". Tests run over `StubURLProtocol`.
- **The alert** (`UIAlertController`, presented over the top controller, the Menu sheet): the
  package's `AppUpdatePresentation`, so the Mac's text and translations. For an update, Open App
  Store (the preferred action) and Not Now in Cancel's role; otherwise one OK. The App Store page
  opens (`UIApplication.open`) only on Open App Store. No iPhone wording names a Mac.

## Announcements

The Mac's in-app announcements (`app-integration.md` ▸ In-app announcements) on iPhone:
`PhoneAnnouncementStore` is the Mac's `AnnouncementStore` without AppKit, on the package's
`AnnouncementFeed` and `AnnouncementFetcher`, under the Mac's keys (per device).

- **The rules are the Mac's.** The In-app notifications switch gates the REQUEST
  (`checkIfNeeded(isEnabled:)` returns before the fetcher is touched); one check a day, stamped
  before fetching; the last good feed cached and restored in `init` (not while the switch is off);
  nil (learned nothing) leaves the card and the cache, [] retracts both; dismissed ids kept forever;
  a link opens and dismisses. Turning the switch off takes the card away at once
  (`follow(_:)`, a subscription to `AppSettings`, made when the screen appears; it applies the
  switch's current value too).
- **When it checks.** `LineformiOSApp` starts a check when the scene becomes active (launch
  included), throttled to once a day by the store. Never in the test host:
  `PhoneAnnouncementStore.checksOnSceneChange(to:isRunningUnderTests:)` is consulted at that call
  site, never inside `checkIfNeeded`, whose tests drive it with a spy fetcher.
- **The card** (`PhoneAnnouncementCard`): the Mac's card (sparkle glyph, title, body, an optional
  link, a ✕ with a 44 pt target) in the iPhone's floating-card chrome on the page colour, at most
  360 pt wide, at the bottom right above the Menu and Aa buttons. Never a full-width bar. Title,
  body and link label are remote input and render as verbatim `Text`, never Markdown. It shows only
  while those buttons do and nothing else holds the bottom (History's card, the selection row or
  comment field, an AI card, a notice, first run, a download). Its entrance is a fade-and-move that
  Reduce Motion turns into a fade. VoiceOver: "Announcement: %@" for the card, "Dismiss
  announcement" for the ✕, and the escape gesture dismisses (the Mac's Esc).

## Review prompt

The Mac's App Store review policy (`app-integration.md` ▸ App Store review prompt) on iPhone:
`PhoneReviewPromptStore` (`LineformiOS/Integration/PhoneReviewPrompt.swift`), under the Mac's keys.

- **Use is a write that reached disk.** `OpenDocument.onConfirmedWrite` fires after each coordinated
  write that succeeded (a new file, a save, a first-line rename's write); a save with nothing to
  write or a failed one does not count. Launches, reading and browsing never count.
- **Eligible** after four sessions with such a write, spanning at least seven days, plus a write in
  this session; asked at most once per marketing version, claimed just before
  `AppStore.requestReview(in:)` (the foreground `UIWindowScene`). StoreKit decides whether the
  sheet shows. No custom pre-prompt.
- **When.** Each write restarts a 4 s quiet period (`.task(id: activityRevision)`); returning to
  the foreground schedules again for an eligible store (never counted as use). The request goes
  only while the scene is active, nothing is presented over the page, and nothing of Lineform's is
  in the way: the Menu or Styling sheet, a picker, first run, History, the selection row or comment
  field, an AI card, an announcement, a notice or the open-failure alert, a download, an update
  check.
- **The test host.** The app's store is inert under XCTest (`recordsEngagement` false), so test runs
  that write documents never add up to a request. `LINEFORM_FORCE_REVIEW_PROMPT=1` is the Mac's
  Debug-only seam.

## App Intents

Shortcuts, Spotlight and Siri: the Mac's **New Lineform Note** (a `text` parameter) and **Open in
Lineform** (an `IntentFile`), with the same type names, titles, parameters and phrases
(`LineformiOS/Integration/PhoneAppIntents.swift`). The phrases come from the Mac's
`Lineform/AppShortcuts.xcstrings`, in the iPhone's Resources by reference; the intent strings are
in the iPhone catalog with the Mac's translations.

- **Through `OpenDocument`.** `PhoneIntentRouter` hands each intent to the screen's document. New
  Note is New Document (the current document is saved first; a failed save keeps it and shows its
  notice), then the text goes in with `edit`, so it autosaves like typing, named from its first
  line. Nothing is staged, unlike the Mac. Open is `openReportingFailure`: an unreadable file shows
  the screen's "That file couldn't be opened in Lineform." A file the intent hands over without a
  URL throws that message.
- **Cold launch.** The screen attaches its document after `prepare` (and the launch restore); an
  intent that arrives earlier waits and runs then, so a restore never lands over it.
- **Registration.** `AppIntents.framework` is LINKED in the iPhone target's Frameworks phase, the
  Mac's rule: without it no `Metadata.appintents` is emitted and the actions silently never
  register. `PhoneAppIntentsTests.testAppIntentsMetadataIsEmittedIntoTheApp` asserts the file is
  in the built app.

## Strings

iPhone strings live in `LineformiOS/Localizable.xcstrings`, in all six languages. Where the Mac
catalog already translates the same English text, the iPhone entry reuses that translation.
`LocalizationSourceSweepTests` scans `LineformiOS/` against this catalog, the same way it scans
`Lineform/` against the Mac catalog.
