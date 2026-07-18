# Inline local image rendering + Reconnect

**Date:** 2026-07-18
**Status:** Approved (direction), pending implementation
**Competitor-scan entry:** A

## Problem

Lineform renders `![alt](path)` as a quiet `🖼 alt` / `🖼 filename` placeholder — file-free and
network-free (Task 6 deferral). This is the one place Lineform visibly trails a reader like
Read.md and every notes app. A **local, file-referenced, network-free** image render (Read/Preview
only) is squarely on-brand: real files, portable, no cloud. Remote URLs stay placeholders to
preserve the "never hits the network" invariant.

The design must also handle the portability reality: a shared `.md` whose image path no longer
resolves on the recipient's machine. The chosen answer is **explicit, no path-guessing**: a
graceful placeholder that (a) auto-heals when the referenced file appears, and (b) offers a
**Reconnect** action to re-point the link.

## Decisions

- **Render local images in Read/Preview.** `![alt](path)` whose path resolves to an existing
  local **image file** (relative-to-document or absolute) renders the actual picture as a block
  attachment. **Remote `http(s)` URLs are never fetched** → placeholder.
- **Alignment = left, like mermaid.** Rendered images are **left-aligned** (the attachment sits
  at the left edge, exactly like mermaid diagrams — only block `$$` math is centered). A narrow
  portrait image hugs the left margin; it is not centered.
- **Image sizing = fit inside a box, aspect ratio preserved.** The image is scaled to fit within
  **(column width × max height)**: width up to the reading column, but a **maximum height cap** so
  a tall/portrait image can't blow up to a massive height (it scales down until its height fits,
  ending narrower than the column, left-aligned). Aspect ratio is always preserved (width→100% only
  drives height when height is within the cap). **Downscale only — never upscale** past the
  image's native pixel size, so a small icon stays its natural size rather than stretching to full
  width. **Height cap = `max(240, min(500, 0.70 × visibleViewportHeight))` points:** a hard
  **500pt ceiling** (the max at full window height on e.g. a 14" MacBook — so a tall image never
  dominates the page), the `0.70 × viewport` term only shrinking it further on smaller windows so
  an image never exceeds the screen, and a **240pt floor** for very short windows. Normal landscape
  images fill the column width and come out well under the cap; tall/portrait images cap at this
  height and sit narrower than the column, left-aligned (like mermaid).
- **Images are a block element, by design.** An image on its own line (text above and below) →
  rendered **block** image. An image sitting mid-sentence, next to text, is **never rendered** —
  it stays the `🖼` placeholder. This is intentional (keeps line-height/layout clean and the
  model simple), not a temporary limitation.
- **Missing-local or remote → placeholder + Reconnect.** The placeholder shows `🖼 label` and a
  quiet **Reconnect** pill (translucent, theme-aware, `arrow.counterclockwise` glyph — same
  treatment as the code-block copy pill). Clicking it opens an image picker and rewrites the
  link.
- **Vertical spacing:** a rendered block image gets **a bit MORE breathing room above and below
  than a normal text block**. It starts from the reading profile's block-spacing
  (`bodyBlockSpacingAttributes`) and adds a small extra image margin **with a minimum floor**, so
  the image never crowds the surrounding paragraphs **even when the user has line-height set
  tight** (block-spacing derived purely from line-height would collapse at tight settings — the
  floor prevents that). Defined once as `imageBlockSpacing = max(floor, blockSpacing + extra)`.
  The same spacing applies to the placeholder form, so layout doesn't jump when an image resolves
  or falls back.
- **Auto-heal (free):** Read/Preview already re-render on document change and external reload, so
  when a referenced file later appears (dropped in, iCloud-synced) it renders on the next redraw
  — no manual refresh.
- **No copying, no bloat.** Images are rendered from disk, downscaled to the column width, and
  cached as **memory-only** rasters (cost-limited `NSCache`, like the diagram cache). The image
  file is never copied and **nothing is written into the `.md`** except when the user explicitly
  Reconnects (which edits the link path).
- **By design (not rendered):** an image next to text (mid-sentence) — images are block-only.
- **Deferred (v1 out of scope):** paste/drag an image to auto-*create* a file + insert a relative
  link (a separate convenience with its own naming/undo/portability design); real images in
  PDF/RTF export (export keeps the placeholder for now).

## Architecture

### 1. Path resolution — `Lineform/Preview/ImageResolver.swift` (pure where possible, tested)

```swift
enum ImageReferenceKind { case localFile(URL), remote, unresolved }

enum ImageResolver {
    /// Classify an image path from the document.
    /// - `http`/`https`/`data:` → .remote (never fetched)
    /// - absolute file path that exists + is an image UTI → .localFile
    /// - relative path resolved against `documentDirectory` that exists + is an image → .localFile
    /// - otherwise → .unresolved
    static func resolve(path: String, documentDirectory: URL?) -> ImageReferenceKind
}
```

Image UTIs restricted to common types (png, jpeg, gif, heic, tiff, bmp, webp). Existence/type
checks touch the filesystem only (never the network). `documentDirectory` is the open file's
parent; nil for untitled documents (→ relative paths unresolved).

**Sandbox note (documented, not hidden):** resolution only *loads* files inside an already-granted
scope — the workspace security-scoped root held by `OutlineFileBrowserStore`, or a file the user
picked via Reconnect's `NSOpenPanel` (which grants access through Powerbox). A local image outside
any granted scope resolves as a path but fails to load → placeholder + Reconnect. This is expected
sandbox behavior; Reconnect is the escape hatch.

### 2. Block routing — `MarkdownBlockGrouping.swift`

Add a block case for an own-line image:

```swift
case image(alt: String, path: String, sourceRange: NSRange)
```

A line that is solely `![alt](path)` (ignoring surrounding whitespace) becomes `.image`.
Images embedded within other text keep flowing through the inline path as the existing
`🖼` placeholder token (unchanged). All other routing unchanged.

### 3. Rendering — `MarkdownPreviewRenderer.appendImageBlock(...)`

New method (sibling of `appendMermaidBlock`):

- `ImageResolver.resolve(...)`:
  - **.localFile(url):** load and **fit within (column width × max height)** — aspect preserved,
    **downscale-only** (see sizing decision) — via an `ImageAttachmentProvider` (memory `NSCache`
    keyed by url + modification date + the fit box, cost-limited by `RasterImageCost`,
    dimension-capped). Emit a `BlockRenderedAttachment` so it participates in the existing
    resize-refit path (re-fits to the new box on window resize, no re-render). The max-height cap
    is respected on refit too, so widening the window never produces a runaway-tall image. The
    attachment is appended **left-aligned** (no centering paragraph style — identical to how
    mermaid is emitted; only block math centers). Attach the alt text as the VoiceOver
    `accessibilityDescription`.
  - **.remote / .unresolved:** emit the placeholder run — `🖼 label` styled as today — tagged with
    the image's **source `NSRange`** via a `.imageSourceRange` attribute (mirroring
    `.checkboxSourceRange`), plus a marker that a Reconnect pill should be drawn for this block.

Both the image and the placeholder are emitted with an **`imageBlockSpacing`** derived from the
reading profile's block-spacing plus a small extra margin and clamped to a minimum floor
(`max(floor, blockSpacing + extra)`) — so a block image carries a bit more breathing room than a
text block and holds that separation even when the reader's line-height is set tight (a pure
line-height-derived spacing would collapse there). The same value is used for the placeholder so
the layout doesn't shift when it resolves ↔ falls back.

The renderer gains a `documentDirectory: URL?` parameter (threaded from the preview view /
`EditorContainerView`), used only for local resolution — the network is still never touched.

### 4. Reconnect interaction — `MarkdownPreviewTextView`

Reuses the existing hover / rect hit-test machinery (the checkbox `mouseDown` precedent):

- On hover over a placeholder block that carries `.imageSourceRange`, draw the **Reconnect pill**
  in its trailing area (translucent, `usesDarkChrome`-aware, `arrow.counterclockwise` + "Reconnect").
- On click → present an `NSOpenPanel` restricted to image UTIs. On selection:
  - Compute the new link path: **relative** if the picked file is within/under the document's
    directory, else **absolute**.
  - Rewrite `![alt](oldpath)` → `![alt](newpath)` in `document.text` through the same binding path
    the checkbox toggle uses (`onImageReconnect` → mutate text at `sourceRange`; a normal edit →
    dirty-tracking, autosave, single-⌘Z undo). Verify the range still spans the original image
    syntax before writing (stale-range safety, like `CheckboxToggle.toggledText`).
- Re-render resolves the new path → the image renders.

### 5. `ImageAttachmentProvider` — `Lineform/Preview/ImageRendering.swift`

Isolated loader/cache behind a protocol (testable without real files), mirroring
`MermaidImageProvider`:

```swift
protocol ImageAttachmentProviding {
    /// NSImage for a resolved local image URL, scaled to FIT within `maxSize`
    /// (aspect ratio preserved, downscale-only — never upscaled past native size), cached;
    /// nil on failure. `maxSize` = (column width, max image height).
    func image(at url: URL, maxSize: CGSize, scale: CGFloat) -> NSImage?
}
```

Sizing helpers (pure, tested):
- `ImageFit.maxHeight(visibleViewportHeight:) -> CGFloat` = `max(240, min(500, 0.70 × viewport))`
  — the 500pt ceiling / viewport-shrink / 240pt floor rule.
- `ImageFit.size(for native: CGSize, in maxSize: CGSize) -> CGSize` returns the fitted size —
  scales `native` down so both `width ≤ maxSize.width` and `height ≤ maxSize.height` while
  preserving aspect ratio, and returns `native` unchanged when it already fits (no upscaling).
  `maxSize = (columnWidth, ImageFit.maxHeight(visibleViewportHeight:))`.

Failure (unreadable/corrupt/out-of-scope) → nil → caller emits placeholder + Reconnect. No logging,
no network, no report affordance (a missing local file is the user's own, not a library bug).

## Testing

- **Unit (default plan):**
  - `ImageResolver.resolve` — remote schemes → .remote; existing absolute image → .localFile;
    relative resolved against a temp document dir → .localFile; missing/non-image/no-dir →
    .unresolved.
  - `ImageFit.maxHeight` — 500 ceiling at large viewport, `0.70×viewport` on smaller windows,
    240 floor at very short viewports.
  - `ImageFit.size` — landscape fits to column width (well under cap); tall portrait caps at
    `maxHeight` and returns width < column; a small image returns native size (no upscale).
  - Link-rewrite helper — relative vs absolute path choice, preserves alt text, stale-range → no-op.
  - `MarkdownBlockGrouping` — own-line image → `.image`; inline image stays placeholder token;
    other routing byte-identical.
  - `ImageAttachmentProvider` cache keying (url + mtime + width) and failure → nil, via a fake.
- **Manual:** render a local image (relative + absolute); resize the window (attachment refits);
  break a path and confirm placeholder + Reconnect; Reconnect to a file under the doc dir (writes
  relative) and outside it (writes absolute); drop the missing file back and confirm auto-heal on
  re-render; confirm remote URL stays a placeholder and never hits the network.

## Out of scope (v1)

- Paste/drag-to-create-file (the separate import convenience).
- Inline (mid-paragraph) image rendering — images are block-only by design, not deferred.
- Real images in PDF/RTF export (placeholder retained; a clean follow-up).
- Image resizing/alignment attributes, captions, lightbox.

## Risk

Medium (the largest of the batch). It reads local files (a deliberate, bounded departure from the
current file-free renderer) and adds a hover-interactive placeholder. Contained by: no network
ever, memory-only downscaled cache (no document/export size impact), the sandbox behavior
documented + Reconnect as the escape hatch, and reuse of the existing block-attachment/refit and
checkbox-hit-test machinery rather than new subsystems.
