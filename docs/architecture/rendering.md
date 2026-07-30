# Read/Preview rendering

The block-grouping layer and every construct rendered on top of it: mermaid, math, code, callouts, images.

Extracted from `CLAUDE.md` so the always-loaded file stays scannable. Content is verbatim —
these are the same load-bearing notes, not a summary. Read this file before changing anything
in this area.

- Inline emphasis rules (`Lineform/Preview/MarkdownInlineSyntax.swift`, 2026-07-26): the one definition of bold/italic/code/strikethrough/link/image, read by `MarkdownPreviewRenderer` (screen, PDF, RTF), `MarkdownHTMLRenderer` (export), `SpeechTextExtractor` (read-aloud), and `MarkdownPlainTextConverter` (Convert to Plain Text). Two rules are load-bearing and were both real defects. **Underscore emphasis never fires inside a word:** the original `_([^_\n]+)_` turned `make_test_file` into "make" + italic "test" + "file" — underscores eaten, word mangled — on screen, in every export, and spoken aloud; `snake_case` in prose about code hits it constantly, which matters because this app is pitched for reading agent-written notes. `(?<![\w\\])_([^_\n]+)_(?![\w])` is CommonMark's intraword rule, and `\w` covering `_` also protects a Python `__init__`. **Asterisk emphasis never fires when flanked by whitespace:** `*italic*` was added at the same time (it is the more common spelling in pasted Markdown), and without `[^*\s\n]` at both ends of the content `2 * 3 * 4` would italicise the 3. `**bold**` still wins over `*italic*` because it matches one character earlier and the earliest match takes the line. `__bold__` is deliberately NOT supported: every `__x__` in prose is more likely a dunder than bold, and adding it would re-create the mangling this fixed. Two consequences to preserve: `MarkdownFormattingCommand.italic` picks its marker from context (`*` when the selection touches a word character, else `_`) because `_` cannot emphasise part of a word — wrapping a mid-word selection in underscores would emit markup the app then renders literally; and the Quick Look appex mirrors these patterns by hand (`QuickLookMarkdownRenderer.inlinePatterns`, separate target, cannot import the shared file) — it had the underscore rule right before the app did, and its `__bold__` and unguarded-asterisk rules were removed to match. **The appex must also carry an `.image` pattern, ordered before `.link`** (2026-07-27): an image's `[alt](path)` is indistinguishable from a link to the link pattern, so with no image rule the link pattern claimed it and left the `!` behind as literal text — Finder previewed `![a picture](photo.png)` as "!a picture", underlined and accent-coloured as a link, for a line the app draws as a picture. The appex renders an image as its alt text (it has no access to the document's folder and never fetches a remote URL), so the markers are consumed and nothing is styled as a link. Guarded by tests in `MarkdownPreviewRendererTests`, `MarkdownHTMLRendererTests`, `SpeechTextExtractorTests`, `MarkdownFormattingCommandTests`, `QuickLookMarkdownRendererTests`, and `RobustnessProbeTests` (which asserts the appex and the app agree on the emphasis hazards directly, rather than leaving both sides correct by inspection).

- **Line endings / CRLF (2026-07-26).** `markdownSourceLines(in:)` (`Lineform/Preview/MarkdownBlockGrouping.swift`) is the ONE place Markdown source becomes lines for the block grouper, and it is what every renderer must use — `MarkdownPreviewRenderer`, `MarkdownHTMLRenderer`, `SpeechTextExtractor`, and `ImageExportPreflight` all go through it. It returns CR-stripped line text alongside each line's range in the ORIGINAL text, and that split is load-bearing in both directions. **Stripping the `\r` is what makes a Windows-authored file render at all:** every detector in this file compares against `\n`-shaped text — `trimmingCharacters(in: .whitespaces)` does NOT strip `\r` (that is `.whitespacesAndNewlines`), and neither do the table, list, and checkbox regexes — so a closing ` ``` ` read as ` ```\r `, no code fence ever closed, and the entire document after the first fence collapsed into one code block, taking every table, rule, and callout with it. **Keeping the raw lengths in `ranges` is what keeps the source offsets honest:** the stripped `\r` still occupies a UTF-16 unit in the file, so recomputing offsets from the stripped line lengths drifts by one per line and misaims checkbox toggling, image Reconnect, code copy, and the cross-mode scroll restore. `markdownBlocks(in:lineRanges:)` takes those ranges; the `lineRanges`-less overload keeps the old `\n`-joined assumption so existing tests stay byte-identical. Do NOT "fix" CRLF by normalising the document text on load — that rewrites the user's file and produces a whole-file Git diff, which is the opposite of the real-files thesis. The Quick Look appex mirrors the strip by hand (it cannot import this file) and needs no ranges. Guarded by `MarkdownRobustnessTests`.

- Read-mode Markdown rendering (block-grouping layer): Read and Preview render a single-pass **block grouping** of the document (`Lineform/Preview/MarkdownBlockGrouping.swift`: `markdownBlocks(in:)` → typed `MarkdownBlock`s) that `MarkdownPreviewRenderer` renders block-by-block. Existing constructs (headings, fenced code, mermaid, math, inline bold/italic/code/link) are rendered by the **unchanged** per-line emission (`appendLines`) so their output is byte-identical; the block layer is the seam new constructs hang off. The single split also retired the old double-split (was "Task 4"). Constructs rendered (Task 6, Wave 1, 2026-07-04): **strikethrough** `~~x~~` (inline token; Format ▸ Strikethrough ⌘⇧X), **horizontal rule** `---`/`***`/`___` (`HorizontalRuleAttachment`, a self-sizing cell; front-matter + setext guards so a `---` opening front matter or underlining a paragraph is NOT a divider), **blockquote** `>`/nested `>>` (indent + de-emphasis, markers hidden; Format ▸ Blockquote — the drawn left bar is a deferred visual refinement), **lists** bulleted `•` + numbered (sequential renumber, nesting, hanging indent; Format ▸ Numbered List ⌘⇧7 / Bulleted List ⌘⇧8), and an **image placeholder** for `![alt](url)` (renders `🖼 alt`, or `🖼 <filename>` when there's no alt — deliberately **file-free and network-free**, never opens the file or hits the network; real image rendering is deferred by design). Each construct also teaches its syntax in the **Info sidebar tab** (see the Info-sidebar-tab bullet) and adds a Format-menu affordance where standard. **Task checkboxes** (Wave 2, 2026-07-04): `- [ ]`/`- [x]` render a ☐/☑ Unicode glyph carrying the source `NSRange` of the marker (`.checkboxSourceRange` attribute); clicking the glyph in Read/Split (`MarkdownPreviewTextView.mouseDown`, glyph-rect hit-test → `onCheckboxToggle`) mutates `document.text` through the binding (`CheckboxToggle.toggledText`, which verifies the 3 chars so a stale range is a no-op) — a normal edit, so dirty-tracking, autosave, and single-⌘Z undo all apply. **Tables** (Wave 3, 2026-07-04): GFM pipe tables render as a **native `NSTextTable`** (`MarkdownTableParser` + `MarkdownPreviewRenderer.appendTable`) — live selectable text, per-column alignment from the delimiter colons, distinguished header, quiet theme-derived gridlines, responsive column layout with cell-text wrapping; cells render at **90% of the reading font** (`tableTextScale`, relative so it still scales with the user's size). Detection is gated on GFM's header==delimiter column-count rule. The embedded **self-scrolling** table panel from the original audit was **deferred by decision** in favor of native tables (live text/selection/copy, PDF-ready, low-risk); the trade-off is that a genuinely-too-wide table wraps/shatters rather than side-scrolling — mitigated (not solved) by the new **"Full" Column Width** stop (the reading Column Width slider's top fills to the margins on any window size; `ReadingProfile.isFullWidthColumn` → unbounded `textColumnMaxWidth`). See `docs/superpowers/specs/2026-07-04-read-mode-rendering-design.md` and `docs/audits/2026-07-04-audit-decisions.md`. Task 6's remaining deferrals: the self-scroll table panel and the blockquote left vertical bar (both need on-screen iteration). **Reflow scroll anchoring (2026-07-17)**: `MarkdownPreviewTextView.setFrameSize` pins the top visible character to its viewport offset across any width change (capture before `super`, restore after the block-attachment refit), so opening/closing the sidebar or reading drawer — which narrows the column and rewraps Read/Preview text — no longer shifts the passage being read (Write mode already had this via `LineformTextView`'s visual-anchor machinery; Read mode had none). Guarded by `testNarrowingPreviewKeepsTopVisibleTextAnchoredWhileRewrapping` (default plan); the hosted reflow drawer tests now assert the tracked character's window Y, not a fixed raw scroll origin (a fixed origin is exactly the text-shifts bug). Write mode's equivalent bug was the MANUAL WINDOW RESIZE path: `LineformEditorClipView`'s 0.45s transition lock (28d6a77) pinned the raw scroll origin and swallowed `restoreVisualLayoutAnchor` while continuous width changes kept re-engaging it — fixed by `setBoundsOriginBypassingVerticalLock` (the anchor restore lands AND re-points the lock at the corrected origin; ordinary scroll adjustments stay pinned), guarded by `testNarrowingEditorScrollViewKeepsTopVisibleTextAnchoredWhileRewrapping`. `EditorLayout.minimumContentWidth` was also reduced 300 → 220 (2026-07-17) so opening the sidebar on a small window no longer forces the window wider. **Live-drag anchor drift (the real user-felt jump, fixed 2026-07-17 via AX-driven live-drag reproduction + trace):** a NESTED `preserveVisibleLayoutAnchorDuring` pass (the text view's `setFrameSize` running inside the scroll view's own preservation) used to degrade to origin-only mode, schedule a DEFERRED restore of the pre-rewrap origin, and clear the outer pass's pending anchor — during a genuine `inLiveResize` drag those deferred restores fired a runloop later and overwrote the anchor's correct restore (stepped/AX `setSize` resizes never showed it, which is why offscreen and hosted stepped-resize tests passed while a real drag jumped). Nested passes now only re-pin the origin for interim stability and never schedule deferred restores nor clear the outer anchor; the strengthened `testNarrowingEditorScrollViewKeepsTopVisibleTextAnchoredWhileRewrapping` pumps the run loop after the resize so the deferred-clobber can't return. Narrow-window toolbar: below `EditorToolbarCompactPresentation.compactModeControlThreshold` (**840** — measured with the real toolbar: Aa falls into the » overflow at a 780pt window, the segmented mode control at 760pt) the principal control swaps to `EditorModeCompactMenu` via `EditorModePrincipalControl`, which owns the width observation in its own small view so a threshold crossing re-renders ONLY the toolbar control — putting that state on `EditorContainerView` re-rendered the whole editor mid-drag and visibly disturbed scroll anchoring (do not move it back). The detail column also declares `navigationSplitViewColumnWidth(min: EditorLayout.minimumContentWidth …)`; KNOWN LIMITATION: with the sidebar open, SwiftUI still enforces an internal detail minimum (~496pt, measured via AX), so the window floor with sidebar visible remains ~756pt — sidebar-hidden windows shrink to ~300pt and the toolbar stays complete (no ») down to ~500pt. An inspector window PRE-EXPANSION was tried and REVERTED (the window grew then snapped back — worse than the jerk it targeted); the drawer now presents natively. **Top-of-document pin (2026-07-17):** both anchors (`VisualLayoutAnchor.capturedAtTop` in Write, `ReflowAnchor.capturedAtTop` in Read/Preview) restore the origin to exactly 0 when the view was at the top at capture time — character-anchoring quantizes to the top-edge character and wobbled ±1 line per live-resize frame, which at the top of the page read as the text bouncing up and settling back during a window drag; guarded by `testNarrowingEditorScrollViewAtTopStaysPinnedToTop` and `testNarrowingPreviewAtTopStaysPinnedToTop`. **RESOLVED (2026-07-17, trace-driven): the "text jumps up" was AppKit's own end-of-live-resize snap.** With the user's exact repro (sidebar CLOSED, scrolled to the TOP of the page) a temporary `ResizeTrace` file log around a real synthetic drag showed the scroll origin stays fixed for the ENTIRE drag (fixes 1–6 work), and then — ~1 ms into `super.viewDidEndLiveResize()` — AppKit's own end-of-live-resize revalidation snaps the clip origin to the top of the topmost line fragment: at the document top that's exactly the top text inset (origin 0 → 32; the heading ends up flush under the toolbar and can STAY there), mid-document it snaps to the nearest line boundary (origin 300 → 272). The snap bypasses `setBoundsOrigin` entirely (AppKit-internal, detected only via the post-hoc `reflectScrolledClipView`), so the clip view's 0.45 s lock never sees it; and it fires only on a genuine HID drag — stepped/offscreen/hosted resizes never trigger it, which is why every automated anchor test was green while the user kept seeing the jump. No automated test can reproduce it (AppKit-internal, live-drag-only); verification is the synthetic-drag + trace recipe in the agent memory note 'ax-driving-and-live-resize-debugging'. Fix (7): `LineformTextView.viewDidEndLiveResize` and `MarkdownPreviewTextView.viewDidEndLiveResize` capture the clip origin before `super` and re-assert it after `super` (via `setBoundsOriginBypassingVerticalLock` in Write mode), clamped to the still-scrollable range so legitimate bottom overscroll correction (content shorter than the viewport after a widen) survives. Verified with synthetic real drags + trace + screenshots: at the top, origin 0 stays 0 through every drag end (`afterSuper origin=32 → restoring → 0.00` each time); mid-document (300 → 272) and Read mode pinned likewise. The toolbar-height follow-up from the old open issue (search collapse ~950, Aa hide 840) was also checked via a `svTopInWindow` trace — the toolbar height is constant through drags; it was never the cause of THIS jump.

- Mermaid rendering: ```mermaid fenced blocks render as native diagrams in Read and Preview modes (Write shows source), via the `BeautifulMermaid` SPM package (`lukilabs/beautiful-mermaid-swift`, MIT, pinned 1.0.4, native — no WebView). **Type routing (`MermaidTypeClassifier`, `Lineform/Preview/MermaidRendering.swift`, 2026-07-18):** the seam classifies the block's declared type BEFORE calling the library, because BeautifulMermaid's parser DEFAULTS every unrecognized type to flowchart — so `pie`/`gantt`/`mindmap`/etc. would otherwise be mis-drawn as a garbage flowchart instead of degrading. `flowchart`/`graph`/`stateDiagram`/`sequenceDiagram`/`classDiagram`/`erDiagram`/`xychart` (bar/line) route to BeautifulMermaid; **`pie` renders natively in Lineform** (`MermaidPieChart` — a pure parser + a monochrome Core Graphics drawer that reuses the two-color page/ink theme, cache, and cost model; a legend carries labels/values/percent, no new hues, drawn as a concrete Retina raster so no `uprightForMacOS` flip is needed); **any other type → `MermaidRenderOutcome.unsupported` → the clean captioned "Mermaid diagram (source)" fallback with NO log** (it is not a bug, just an unrendered-but-valid diagram). The supported-prefix list is coupled to the pinned library version — re-check it if the pin is bumped (same discipline as the orientation flip). Canvas/ink are chosen in `MarkdownPreviewRenderer.appendMermaidBlock` (colors from `DiagramPalette`, `Lineform/Preview/DiagramCardStyle.swift`): **light themes** draw on a **transparent** canvas (no box; the fixed dark ink `DiagramPalette.ink(isDark:false)` gives crisp node borders on the light page) — fixed, so switching among light themes redraws nothing; **dark themes** set the canvas to the theme's OWN page color (`theme.backgroundColor`/`theme.textColor`) so it still reads as no box (it matches the page) but Mermaid's node boxes get a visible fill/outline — a transparent canvas can't, because Mermaid derives the node fill FROM the canvas (verified — you cannot darken only the node boxes while keeping the canvas transparent). Dark is therefore per-theme (switching between the two dark themes re-renders), kept cheap by the memory cache. Width-constrained and **refit to the window on resize** (`setFrameSize`/`viewDidEndLiveResize` → `BlockAttachmentRefit`, scaling the existing raster with no re-render, deferred a runloop tick during a live drag; only `BlockRenderedAttachment`-subclass attachments are refit, so inline math's baseline is never disturbed). Cached in a **memory-sized** `NSCache` (`totalCostLimit` via `RasterImageCost`, not a flat count — `DiagramCacheBudget`), size-guarded (>20,000 chars → fallback). BeautifulMermaid 1.0.4 draws its macOS raster into a bottom-left-origin `CGContext` while assuming a top-left origin, so every diagram comes back vertically mirrored; `MermaidImageOrientation.uprightForMacOS` flips the finished raster upright at the seam. This correction is unconditional — **if the pin is ever bumped, re-check orientation and remove the flip if upstream fixes the y-origin, or diagrams will render upside down again.** On any parse/render failure it falls back to a captioned "Mermaid diagram (source)" block and records a **local, anonymous** entry in `~/Library/Application Support/Lineform/DiagramLog/` (source snippet + error + app version + count + last-seen; no file names/paths). This log is a silent backing store only — **there is no way to send it**, since diagram reporting was removed on 2026-07-29 so that nothing in Lineform transmits document content off the device — and it is deliberately **not** surfaced in any menu (the former Export/Clear Diagram Log menu items were removed as user-facing plumbing with no writer value). The library is isolated behind `MermaidImageProvider`; failures are always safe.

- Math / LaTeX rendering: inline `$…$` and block `$$…$$` LaTeX render as native typeset equations in Read and Preview modes (Write shows source), via the `SwiftMath` SPM package (`mgriebling/SwiftMath`, MIT, pinned 1.7.3, native — no WebView/JavaScript/KaTeX). Isolated behind `MathImageProvider` (`Lineform/Preview/MathRendering.swift`), mirroring `MermaidImageProvider`: renders each equation to a raster `NSImage` (via SwiftMath's `MathImage.asImage()`) in a **memory-sized** `NSCache` (`MathCacheBudget`, keyed by latex+style+fg+scale+pointSize), size-guarded (>20,000 chars → fallback). **Block** `$$` math renders **transparent** (no background — equations are glyphs and need none) with a fixed light/dark ink (`DiagramPalette.ink(isDark:)`), so it matches every theme's page with no box and never re-renders on a theme switch; **inline** `$…$` math stays fully theme-aware. Delimiters follow pandoc/GitHub `$` rules so prose dollar amounts ("it costs $5 to $10") stay literal — the opener may precede a digit; only the closing side guards against prose. Inline math is a **first-class token in the existing inline tokenizer** (`inlineWithMath`/`inlineSpans`), so it loses to an earlier code span or emphasis run by position (```` `$x$` ```` stays literal code; math is never detected inside another inline token) and is baseline-aligned by offsetting the attachment `-descent` (from `MathImage`'s ascent/descent). Unlike Mermaid, SwiftMath's macOS path draws upright in the flipped on-screen text view with no flip needed — BUT its `NSImage` (a `drawingHandler` rep) flips in a non-flipped graphics context such as the **PDF/print** context, so `MathImageProvider` rewraps it as a **CGImage-backed** `NSImage` (`MathImageOrientation.cgImageBacked`) — orientation-stable across screen and print (block math was upside down in exported PDFs before this). This preserves Retina resolution (verified) and needs no flip; re-check if the pin is bumped. On any parse/typeset failure it falls back to a captioned "Math (source)" block (or inline-code-styled source), with **no logging, no report affordance, and no network** — math failures are the user's own LaTeX, not a library bug worth collecting. Math regions are protected from Writing Tools like fenced code (`MarkdownWritingToolsProtection.mathRanges`). SwiftMath bundles libre math fonts (GUST Font License + SIL OFL); see `Lineform/Resources/FontLicenseReview.md`. The raw LaTeX is attached as the image's VoiceOver `accessibilityDescription` (a known limitation: VoiceOver reads source, not spoken math — see `docs/superpowers/specs/2026-07-02-math-latex-support-design.md`).

- Code block syntax highlighting + copy button (2026-07-18): fenced code blocks in Read/Preview colorize via a native, dependency-free tokenizer (`CodeSyntaxHighlighter`, `Lineform/Preview/CodeHighlighting.swift`) covering Swift, JavaScript/TypeScript, Python, JSON, Bash/shell, HTML, CSS — an unrecognized or absent language tag stays plain monospace (today's look) but still gets the copy button. A muted, theme-derived `CodeSyntaxPalette` (`DiagramCardStyle.swift`, ~4–5 token roles: keyword/string/comment/number/type, no rainbow). `.fencedCode` is its own `MarkdownBlockGrouping` block case, routed to `MarkdownPreviewRenderer.appendCodeBlock`; a `highlightsCode` flag is `true` on-screen and **`false` from `DocumentExportRenderer`**, so exported/printed code stays monochrome dark-ink (a deliberate no-color-in-PDFs decision). Purely additive text-color attributes — no rasters, no cache, nothing written to the `.md` or export. **Write mode is unchanged** (the scoped, line-local `MarkdownSyntaxHighlighter` is untouched). A hover **Copy** pill (same translucent theme-aware treatment as the image Reconnect pill) sits top-right of the block, copying the raw source via the block's stored `.codeBlockSourceRange` — read-only, no document mutation. Line numbers and diff/fold highlighting are deliberately out of scope. See `docs/superpowers/specs/2026-07-18-code-block-highlighting-copy-design.md`.

- Callouts / admonitions (2026-07-18): GitHub-style `> [!NOTE]` / `[!TIP]` / `[!IMPORTANT]` / `[!WARNING]` / `[!CAUTION]` blockquotes (case-insensitive, optional custom title `> [!NOTE] Remember this`) render as a monochrome title row — a per-type SF Symbol + title, **bold weight** (the code comment in `MarkdownPreviewRenderer.appendCallout` says "medium weight"; it actually applies `.boldFontMask`), in the ink tone, **not a per-type color** — over the existing blockquote body styling. Detection (`MarkdownCallout.parse`) and the `.callout` block case live in `MarkdownBlockGrouping.swift`; an unrecognized type degrades gracefully to an ordinary blockquote. The shared indent/de-emphasis loop was extracted out of `appendBlockquote` into `appendQuoteLines`, reused by both, so blockquote output stays byte-identical. Renders in Read/Preview **and** PDF/RTF export (pure text + a small tinted SF Symbol, no color concern). Info sidebar tab gets a syntax row. See `docs/superpowers/specs/2026-07-18-callouts-admonitions-design.md`.

- Inline local image rendering + Reconnect (2026-07-18): `![alt](path)` sitting **alone on its own line** with a path that resolves to an existing **local** image file (relative-to-document or absolute; common bitmap UTIs) renders the actual picture, **left-aligned like mermaid** (only block math centers), in Read/Preview. **Remote `http(s)`/`data:` URLs are never fetched** — always a placeholder — preserving the app's network-free invariant. An image mid-sentence (not alone on its line) stays the `🖼` placeholder token by design, not a limitation. Sizing fits inside (column width × a height cap) with aspect ratio preserved and **downscale-only** (never upscales past native size); the height cap is `max(240, min(500, 0.70 × visible viewport height))` points (`ImageFit.maxHeight`), so a tall/portrait image narrows rather than dominating the page, and refits on window resize like other block attachments. A missing-local or remote reference shows the placeholder plus a hover **Reconnect** pill (translucent, `arrow.counterclockwise`, same treatment as the code copy pill); clicking opens an `NSOpenPanel` and rewrites the `![alt](path)` link in `document.text` (relative if the picked file is under the document's directory, else absolute) through the same stale-range-safe binding path as checkbox toggling — a normal edit, so dirty-tracking/autosave/undo apply. Resolution only loads files inside an already-granted sandbox scope (the workspace root, or whatever Reconnect's open panel grants); out-of-scope local paths fail to load and fall back to the placeholder — Reconnect is the escape hatch. Auto-heals on the next re-render once a missing file reappears (e.g. iCloud sync) — no manual refresh needed. Images are loaded from disk, downscaled, and kept only in a memory-cost-limited `NSCache` (`ImageAttachmentProvider`, mirroring `MermaidImageProvider`) — never copied, never written into the `.md` except via an explicit Reconnect. **Styled PDF and Print (⌘P) now render resolvable local images**: `documentDirectory` + a real `ImageAttachmentProvider` are threaded into the Styled export path (`DocumentExportRenderer`), and a consolidated `NSOpenPanel` grant prompt (`ImageExportPreflight` + `EditorContainerView.withImageAccessGrantsIfNeeded`) covers images outside the app's sandbox scope before rendering. The prompt is deliberately **honest**: `ImageExportPreflight` scans the renderer's OWN block partition (`markdownBlocks(in:)` `.image` cases) so it flags **only own-line images that would actually render** — never a mid-sentence/fenced image (which stays a placeholder anyway), and never a reference a grant can't fix (remote URLs, or a relative path in an untitled doc with no `documentDirectory` to resolve against). One panel per export (Styled + Print only), Cancel = export with placeholders. **Normal PDF stays raw source and RTF stays `imagesAsText`** — both keep the `🖼` placeholder/caption text, unchanged. See `docs/superpowers/specs/2026-07-18-inline-local-image-rendering-design.md` and `docs/superpowers/specs/2026-07-18-pdf-image-export-design.md`. **Placeholder color:** the `🖼 label` run (both the inline `.image` token and the own-line `appendImagePlaceholder` fallback) renders in `NSColor.linkColor`, so an unresolved image reference reads as a reference, not dim body text. **Drag-to-place indicator:** the drop guide (`LineformTextView+ImageInsertion.updateDropIndicator`) is a **dashed** accent line (`CAShapeLayer`, `lineDashPattern [6,4]`, `controlAccentColor`), reading as a placement hint rather than a divider. **Drop-below-last-line (load-bearing):** an on-line drop snaps to the START of the drop line, but a drop in the empty area BELOW the last line must append at end-of-document — otherwise the line-start snap places the new image ABOVE a trailing image and you can never drop under the last one. `isImageDropBelowLastLine` detects this geometrically (`point.y >= usedRect(for:).maxY + textContainerOrigin.y`) and routes to `ImageInsertionText.appendingAtEnd` (leading newline only when the doc isn't already newline-terminated); the on-line path uses `ImageInsertionText.insertingOnLine`. Placement rules are the pure, tested `ImageInsertionText` helper; both paths apply through `shouldChangeText → replaceCharacters → didChangeText` (one undo step, binding synced).

## Byte-order marks (2026-07-27)

A UTF-8 BOM is what Windows Notepad writes at the head of a `.md`. It is an invisible character
sitting before the first character of line 1, so every prefix test in the app failed on it: a
BOM'd file's first heading was not a heading, its front matter opened nothing (and was therefore
protected from neither Writing Tools nor the spell checker), and its first code fence never opened,
so the outline listed headings from inside code and dropped the real ones after it.

It is handled exactly the way the CRLF `\r` is, and for the same reason — it is a property of the
file's *encoding*, not of its content:

- `markdownSourceLines(in:)` strips it from line 1 only. Unlike the `\r`, which trails, it sits
  *before* the line's text, so the reported range starts one unit LATER rather than merely being
  one longer. Every consumer reads `location` as "where this line's text begins"; counting the BOM
  there aimed the outline's scroll-to-heading one unit short.
- `markdownLineTrimCharacters` contains it, which covers the raw-text passes that cannot use the
  splitter (the fence and math scans in `MarkdownWritingToolsProtection`, the highlighter's block
  spacing). `isWhitespace`'s ASCII fast path falls through to the real set for it, so the scoped
  walk and the whole-document pass stay in agreement for free.
- `MarkdownHeadingParser`, `MarkdownHeadingEditing.classify`, and `LinePrefix` skip it explicitly.
  These are the paired definitions: had only the reader learned about the BOM, ⌘1 on a BOM'd
  heading would have stacked a second marker — the bug this repo has now paid for three times.
  `MarkdownHeadingEditing` carries it in `indent`, which is what re-emits it *ahead* of the new
  marker instead of after it.
- `MarkdownWritingToolsProtection.frontMatterRange` allows it before the opening `---`, and still
  returns a range starting at 0: the mark belongs to the block it precedes.

The document text is never rewritten to remove it. The byte survives every edit and every save.

## Backslash escapes (2026-07-27)

`MarkdownInlineSyntax` had `(?<!\\)` on the asterisk-italic pattern alone, and nothing anywhere
removed the backslash. The result was wrong in both directions at once:

- `` \`not code\` `` still opened a code span, so the backticks were EATEN and stray backslashes
  were left in their place.
- `\[not a link\](x)` still matched the link pattern, for the same reason.
- `\*not italic\*` correctly declined to open emphasis — and then drew the backslashes, so the
  only way to write a literal `*` looked broken.

Every opener now carries `(?<!\\)`, and `MarkdownInlineSyntax.unescape(_:)` drops the backslash.
The two halves are one feature: the lookbehind without the unescape is the third bullet, and the
unescape without the lookbehind is the first two.

`unescape` is applied ONLY to the plain runs between tokens, in all four emitters — preview,
HTML export, read-aloud, and Convert to Plain Text. A code span's contents are literal by
definition (CommonMark does not process escapes inside one) and a link or image DESTINATION is
emitted one-to-one and must never be rewritten. In HTML export it runs BEFORE the `&`/`<`
substitution: the backslash is Markdown syntax, the entity is the output format.

The Quick Look appex had been doing both correctly since it was written — it has its own
`unescapeInline`. Finder was rendering these lines right while the app was not, which is what the
app-versus-appex comparison in `InteropProbeTests` exists to catch.

## Nested emphasis in link text — the known divergence (2026-07-27)

The app's inline pass is FLAT: one earliest-match scan per line, with no recursion into a token's
contents. So `[**bold** link](url)` draws its inner markers literally. The appex recurses and
shows "bold link".

This is deliberately left alone. Making them agree means giving the app a recursive inline model,
and that model would have to be built three times over — preview, HTML export, and read-aloud all
walk their own copy of the scan. That is a redesign, not a fix. It is pinned by
`testNestedEmphasisInLinkTextIsTheKnownDivergence` so it cannot silently widen into other
constructs.

## Image destinations (2026-07-27)

`MarkdownInlineSyntax.image` reads a destination as `[^\)\n]+`, so a bare `)` ends it. Reconnect
wrote the picked file's path in verbatim, and `photo (1).png` — what every browser download is
named — produced `![](photo (1).png)`: a link the app had just written and could no longer parse,
leaving the placeholder permanently broken.

Two halves, again:

- `ImageLinkRewrite.markdownDestination(for:)` escapes only the characters that END a destination
  — `(`, `)`, and the newlines. Spaces are deliberately left alone: they parse fine and stay
  readable in the source. Drag/drop and paste were already safe (`sanitizedFileBase` reduces the
  written filename to clean ASCII), but the app-container fallback path was not, and now uses the
  same helper.
- `ImageResolver.resolve` tries the LITERAL path first and then its percent-decoded form. This is
  not only for what Reconnect writes: `%20` for a space is what every other editor emits, so a
  document authored elsewhere was showing a broken-image placeholder for a file sitting right
  beside it. Literal stays first so a filename that genuinely contains a `%` escape is never
  decoded out from under the writer.

HTML export is untouched by this — it still emits the destination exactly as the document holds it.

## Diagrams and math (audited 2026-07-27)

**A pie slice value could crash the app.** `MermaidPieChart.parse` accepted any `Double > 0`,
including `inf`, `1e400`, and 20-digit integers. `MermaidPieRenderer.formatValue` is
`v == v.rounded() ? String(Int(v)) : …`, and every finite Double at or above 2^52 is its own
`.rounded()` — so any value above `Double(Int.max)` took the `Int(v)` branch and TRAPPED. An infinite
value additionally made the total infinite, so `fraction` was NaN and the percent's
`Int((nan * 100).rounded())` trapped too. The first trap site is `legendMaxWidth`, during size
computation, before a pixel is drawn, and the blast radius includes Export As and Print, not just
Read/Split. The parser now requires `isFinite` and a `maximumSliceValue` bound, and the renderer's
conversions were independently made total: the parser is the correctness gate, the renderer must not
trap on whatever a future caller hands it. Same shape as the ordered-list `Int.max` crash.

**Front-matter diagrams were reported to the user as app bugs.** `MermaidTypeClassifier` skipped a
leading `---`/`---` block to find the diagram type; BeautifulMermaid 1.0.4 does not — it reads
`"---"` as line one and throws `invalidHeader("---")`. So the standard Mermaid front-matter shape
that most generators emit was classified `.supported`, failed, and took the `.failed` path: the
captioned fallback, plus up to 2,000 characters of the user's diagram
written to `~/Library/Application Support/Lineform/DiagramLog/log.json` — the path this document
reserves for genuine library bugs, not for valid-but-unrenderable input. Every BeautifulMermaid-routed
type was affected. The pre-scan existed twice (classifier and `MermaidPieChart`) and at neither of the
places that mattered; it is now one `MermaidSource` type, and the front matter is stripped at the seam
before `MermaidRenderer.renderImage`.

**The 20,000-character size guard bounded nothing.** BeautifulMermaid's cost grows with node count
and its raster area roughly quadratically with layout width, so a 3.1 KB / 200-node flowchart — one
seventh of the character cap — rendered for ~1 s on the MAIN THREAD into a ~392 MB bitmap that
instantly exceeded the whole `DiagramCacheBudget` and was evicted, meaning every keystroke in Split
mode paid the full cost again: the cache gave zero protection precisely to the diagrams that needed
it. At 600 nodes it was 22.8 s and multi-gigabyte. `MermaidBlockPolicy` now also caps significant
lines. Separately, `MermaidImageOrientation.uprightForMacOS` returns nil instead of the input when its
context allocation fails — returning the un-flipped raster would draw the diagram MIRRORED, which is
the one thing that type exists to prevent.

**The code-block copy pill truncated CRLF documents.** `appendCodeBlock` took the copy range's
LOCATION from `lineRanges` (measured against the original text) but its LENGTH from the rendered
body, which is joined from CR-STRIPPED lines. On a CRLF file the range was short by one unit per body
line, so the pasteboard got the code with its last (bodyLines − 1) characters chopped off, silently —
`copyCodeBlockToPasteboard` only bounds-checks, and a short range always passes. Both endpoints now
come from `lineRanges`. This is exactly the drift the `markdownSourceLines` invariant warns about,
and that invariant already names copy as a consumer.

**`MathDelimiters.inlineSpans` was quadratic.** Each unmatched `$` rescanned the rest of the line for
a closer. It now memoizes the two "no closer remains" outcomes, which is sound because every
close-scan starts at `open + 1` where `chars[open]` is `$` — never mid-backslash-run — so all scans
visit the same canonical positions and a later one covers a strict suffix of an earlier one. Note for
the record: the audit reported this as being on the live spell-check path. It is not — spell checking
goes through `MarkdownSpellCheckRegions`, which never touches `MathDelimiters`. The real consumers
are `MarkdownWritingToolsProtection` and the preview renderer.

## What adversarial verification found in the same-day fixes (2026-07-27)

The six areas fixed by the day's sequential review runs were later handed to adversaries that had
not written them. **Not one held up.** 24 further gaps, twelve of them cases where the fix passed the
test written beside it and failed the neighbouring case. The two worst are recorded here because
they are the clearest evidence that a green suite is not evidence a fix is done.

**Convert to Plain Text began corrupting code.** The escape sweep added
`MarkdownInlineSyntax.unescape(text)` to the END of the converter — after the fence lines and
code-span backticks had already been stripped, so there was no structure left to honour that
function's own contract ("applied ONLY to the plain runs between tokens; a code span's contents are
literal"). Every doubled backslash in a fenced block was halved and autosaved to the user's `.md`:
`re.compile(r"\\d+\\.\\d")` became `re.compile(r"\d+\.\d")`, and `printf("a\\tb\\n")` became a
literal tab escape. The converter now tracks fences with `MermaidFence` and emits their bodies
verbatim, and applies the strips and the unescape only to the runs BETWEEN code spans. The suite's
only converter fuzz test asserts the UNDO record round-trips — it stores the original markdown, so
it passes no matter what the conversion does to the file.

**The same converter could delete a line.** Its link and image patterns did not exclude `\n`, and it
ran over the whole joined document, so an unclosed `](` on one line paired with any `)` on a later
one: `See [the docs](https://example.com/a` / `Smiley :-)` / `Next paragraph` lost the middle line
entirely. `MarkdownInlineSyntax` uses `[^\]\n]` and `[^)\n]+` for exactly this reason, and the
commit's own comment claimed these "mirror MarkdownInlineSyntax".

**`ImageLinkRewrite` escaped parens but not `%`.** `String.removingPercentEncoding` is
all-or-nothing: one stray `%` that is not a valid escape makes it return nil for the WHOLE string, so
`ImageResolver` never got a decoded candidate and `Q3 100% final (2).png` stayed permanently
unresolved — the precise round-trip failure the fix was written to close, reached through a different
character. A leading or trailing space fails the same way, because the resolver trims before looking
up. Both are escaped now.

**The BOM sweep was incomplete in three places, and widening it created a new divergence.**
`MarkdownTableEditing` reads RAW text, so a BOM'd file whose first line is a table header became a
table to the renderer and not to Tab/Reformat — Reformat a silent no-op and Tab inserting a literal
tab into the row. `MarkdownRangeAnalyzer` had no BOM handling at all, so line 1 of a BOM'd file got no
heading or list colouring — a gap the sweep WIDENED, since the outline and renderer now do see that
heading. And `MarkdownOutlineParser` was given the wider `markdownLineTrimCharacters` while
`markdownBlocks` still trims with `.whitespaces`: on a MID-document BOM (what `cat a.md b.md`
produces) the outline opened a fence the renderer does not, listing a heading that Read mode draws
inside code. The outline now trims exactly as the renderer does.

**The Quick Look appex drifted on six separate rules** — the unescape table (no `\!`, no `\\`), an
empty link/image destination, the fence run-length and trailing-content rules, an unterminated fence
swallowing the rest of the document, the BOM, and the nine-digit ordered-marker cap. It is a
hand-copy that cannot import the app's rules, which is exactly why every claim that it "now agrees"
has to be asserted by a test rather than believed.
