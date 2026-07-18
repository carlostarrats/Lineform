# Inline Local Image Rendering + Reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render `![alt](path)` that points at an existing **local image file** as an actual picture (block attachment) in Read/Preview modes — left-aligned, fit inside a (column-width × max-height) box, downscale-only, memory-cached, network-free. Missing-local / remote references stay a quiet `🖼 label` placeholder that (a) auto-heals on re-render when the file appears and (b) offers a **Reconnect** pill that repoints the link. Nothing is ever written into the `.md` except on an explicit Reconnect.

**Architecture:** A pure classifier (`ImageResolver`) decides local-file / remote / unresolved. Pure sizing helpers (`ImageFit`) compute the fit box and fitted size. A new `.image` block case in `MarkdownBlockGrouping` routes own-line images; inline (mid-text) images keep flowing through the existing `imageToken` placeholder. A protocol-isolated `ImageAttachmentProvider` loads + downscales + memory-caches the raster, mirroring `MermaidImageProvider`. `MarkdownPreviewRenderer.appendImageBlock` emits either a left-aligned `BlockRenderedAttachment` (so it joins the existing resize-refit path) or the placeholder run tagged with `.imageSourceRange` + a Reconnect marker. The Reconnect pill reuses `MarkdownPreviewTextView`'s checkbox `mouseDown` hit-test machinery → `NSOpenPanel` → a pure link-rewrite helper mutating `document.text` through the same binding path as the checkbox toggle. The renderer gains a `documentDirectory: URL?` parameter threaded from `EditorContainerView.currentFileURL` through `DebouncedMarkdownPreviewView` → `MarkdownPreviewViewRepresentable`.

**Tech Stack:** Swift, AppKit, TextKit, XCTest

## Global Constraints
- Local files ONLY — remote http(s)/data URLs are NEVER fetched (→ placeholder). No network, ever.
- Images are BLOCK-only (own line, ignoring surrounding whitespace); inline-in-text images stay the `🖼` placeholder by design (unchanged `imageToken`).
- Alignment LEFT (like mermaid — no centering paragraph style; only block `$$` math centers).
- Sizing: fit inside `(columnWidth × maxHeight)`, aspect preserved, DOWNSCALE-only (never upscaled past native pixel size). `maxHeight = max(240, min(500, 0.70 × visibleViewportHeight))`.
- Vertical spacing: `imageBlockSpacing = max(floor, blockSpacing + extra)` so images don't crowd text even at tight line-height; the SAME spacing is used for the placeholder so layout never jumps on resolve ↔ fallback.
- No copying, no bloat: memory-only downscaled `NSCache` (cost-limited by `RasterImageCost`, mirroring `DiagramCacheBudget`); the `.md` is edited only on explicit Reconnect.
- Read/Preview only; PDF/RTF export keeps the placeholder (v1 — `DocumentExportRenderer` renders with no `documentDirectory`, so images stay `.unresolved` there by construction).
- Sandbox: resolution only *loads* files inside an already-granted scope (the workspace security-scoped root held by `OutlineFileBrowserStore`, or a Reconnect-picked file via Powerbox). A local image outside any granted scope resolves as a path but fails to load → placeholder + Reconnect (documented, expected).
- Reuse existing machinery — `BlockRenderedAttachment` / `BlockAttachmentRefit` for refit, the checkbox `mouseDown` hit-test + `CheckboxToggle` stale-range discipline for Reconnect — rather than new subsystems.
- Attach the alt text as the attachment's VoiceOver `accessibilityDescription`.
- The renderer's existing byte-identical output for every OTHER construct must not change (guarded by the existing `MarkdownPreviewRendererTests` / `MarkdownBlockGroupingTests`).

**pbxproj note (this project hand-edits `project.pbxproj`):** objectVersion 56, no synced groups. Every NEW `.swift` file — product source AND test — must be registered by editing **four** pbxproj sections (PBXBuildFile, PBXFileReference, the group's `children`, and the target's Sources build phase) with a fresh sequential `1F0000xx…` ID pair, following the exact pattern of `MarkdownBlockGroupingTests.swift` (see lines 41 / 198 / 526 / 837). Product files go in the app target's Sources phase + the `Lineform/Preview` group; test files go in the `LineformTests` target's Sources phase + the `LineformTests` group. After adding a file, do a plain `xcodebuild build` once to confirm the project still parses before running tests.

---

## Task 1 — `ImageResolver` (pure path classification) + tests

Classify an image path from the document into local-file / remote / unresolved. No block/render coupling yet.

**Files:**
- NEW `Lineform/Preview/ImageResolver.swift` (product; register in pbxproj — app target Sources + `Lineform/Preview` group).
- NEW `LineformTests/ImageResolverTests.swift` (register in pbxproj — LineformTests target Sources + `LineformTests` group).

**Interfaces:**
- Produces:
  ```swift
  enum ImageReferenceKind: Equatable { case localFile(URL), remote, unresolved }

  enum ImageResolver {
      /// Classify an image path from the document.
      /// - `http`/`https`/`data:` (any case) → .remote (never fetched)
      /// - absolute file path that exists AND is an image UTI → .localFile(url)
      /// - relative path resolved against `documentDirectory` that exists AND is an image → .localFile(url)
      /// - otherwise (missing, non-image, or relative with nil documentDirectory) → .unresolved
      static func resolve(path: String, documentDirectory: URL?) -> ImageReferenceKind
  }
  ```
- Consumes: `Foundation`, `UniformTypeIdentifiers` (image-UTI check).

**Implementation notes:**
- Trim the path; percent-decode a leading `file://` URL to a filesystem path if present.
- Remote detection: lowercase-prefix `http://`, `https://`, or `data:` → `.remote`. (Never touches the network — a pure string test.)
- Restrict image UTIs to the common set: `png`, `jpeg`, `gif`, `heic`, `heif`, `tiff`, `bmp`, `webp`. Resolve the candidate `URL`, then require BOTH: the file exists (`FileManager.default.fileExists`) AND its type conforms to `UTType.image` (via `UTType(filenameExtension:)?.conforms(to: .image)` OR membership in the explicit extension allow-list — use the explicit allow-list as the primary gate so behavior is deterministic in tests regardless of the host's UTI database).
- Absolute vs relative: a path beginning with `/` (or a decoded `file://`) is absolute; otherwise resolve against `documentDirectory` (`documentDirectory.appendingPathComponent(path)`), standardized. `documentDirectory == nil` + relative → `.unresolved`.

**TDD steps:**
- [ ] Write `ImageResolverTests` with failing cases (create real temp files with `FileManager` in a temp dir; write a tiny valid PNG header or just an empty file with a `.png` extension — since the allow-list gates on extension, an empty `.png` still classifies as image; a `.txt` does not):
  - `testHttpUrlIsRemote` — `resolve(path: "http://example.com/a.png", documentDirectory: nil) == .remote`.
  - `testHttpsUrlIsRemote` — `https://…` → `.remote`.
  - `testDataUrlIsRemote` — `data:image/png;base64,AAAA` → `.remote`.
  - `testAbsoluteExistingImageIsLocalFile` — write `<tmp>/pic.png`; `resolve(path: "<tmp>/pic.png", documentDirectory: nil)` == `.localFile(<tmp>/pic.png)` (compare `standardizedFileURL`).
  - `testRelativeImageResolvesAgainstDocumentDirectory` — write `<tmp>/img/pic.png`; `resolve(path: "img/pic.png", documentDirectory: <tmp>)` == `.localFile(<tmp>/img/pic.png)`.
  - `testMissingFileIsUnresolved` — `resolve(path: "nope.png", documentDirectory: <tmp>)` == `.unresolved`.
  - `testNonImageExtensionIsUnresolved` — write `<tmp>/notes.txt`; absolute path → `.unresolved`.
  - `testRelativePathWithNilDirectoryIsUnresolved` — `resolve(path: "pic.png", documentDirectory: nil)` == `.unresolved`.
- [ ] Run to fail (compile error — type doesn't exist yet):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/ImageResolverTests`
- [ ] Implement `ImageResolver.swift` (minimal, real Swift as specced above). Register both files in pbxproj (4 sections each). `xcodebuild build` once to confirm the project parses.
- [ ] Run to pass (same command). Expect: all 8 tests pass.
- [ ] Commit: `Image rendering: ImageResolver path classification (local/remote/unresolved)`.

---

## Task 2 — `ImageFit` sizing helpers (pure) + tests

Compute the height cap and the fitted size. No AppKit image loading yet.

**Files:**
- NEW `Lineform/Preview/ImageFit.swift` (product; pbxproj — app target + `Lineform/Preview` group). (May alternatively live in `ImageResolver.swift`; a separate file keeps the sizing math independently testable — prefer separate.)
- NEW `LineformTests/ImageFitTests.swift` (pbxproj — LineformTests).

**Interfaces:**
- Produces:
  ```swift
  enum ImageFit {
      /// Max block-image HEIGHT in points: hard 500pt ceiling, 0.70×viewport shrink on smaller
      /// windows, 240pt floor for very short windows.
      static func maxHeight(visibleViewportHeight: CGFloat) -> CGFloat   // = max(240, min(500, 0.70 * viewport))

      /// Fitted size for `native` scaled DOWN to fit within `maxSize` (both width ≤ and height ≤),
      /// aspect ratio preserved; returns `native` unchanged when it already fits (NEVER upscales).
      /// `maxSize = (columnWidth, ImageFit.maxHeight(...))`.
      static func size(for native: CGSize, in maxSize: CGSize) -> CGSize
  }
  ```
- Consumes: `CoreGraphics`.

**Implementation notes:**
- `maxHeight`: `max(240, min(500, 0.70 * visibleViewportHeight))`. Guard non-positive viewport → returns 240 (floor) since `0.70*0 = 0 → min(500,0)=0 → max(240,0)=240`.
- `size`: if `native.width <= 0 || native.height <= 0` return `native`. Compute `scale = min(1, maxSize.width/native.width, maxSize.height/native.height)`; the `min(1, …)` clamp is the downscale-only guard. Return `CGSize(native.width*scale, native.height*scale)`.

**TDD steps:**
- [ ] Write `ImageFitTests` failing cases:
  - `testMaxHeightCeilingAtLargeViewport` — `maxHeight(visibleViewportHeight: 1200)` == 500 (0.70×1200=840, capped at 500).
  - `testMaxHeightShrinksOnSmallerWindow` — `maxHeight(visibleViewportHeight: 600)` == 420 (0.70×600).
  - `testMaxHeightFloorAtVeryShortViewport` — `maxHeight(visibleViewportHeight: 200)` == 240.
  - `testLandscapeFitsToColumnWidthWellUnderCap` — `size(for: CGSize(1600, 900), in: CGSize(700, 500))` scales by 700/1600 → `CGSize(700, 393.75)`; assert width == 700 and height < 500 (use `XCTAssertEqual(_, accuracy:)`).
  - `testTallPortraitCapsAtMaxHeightAndIsNarrowerThanColumn` — `size(for: CGSize(600, 1200), in: CGSize(700, 500))` scales by 500/1200 → width 250 (< 700), height 500.
  - `testSmallImageReturnsNativeSizeNoUpscale` — `size(for: CGSize(120, 80), in: CGSize(700, 500))` == `CGSize(120, 80)`.
- [ ] Run to fail:
  `xcodebuild test … -only-testing:LineformTests/ImageFitTests`
- [ ] Implement `ImageFit.swift`. Register in pbxproj. `xcodebuild build`.
- [ ] Run to pass. Expect: 6 tests pass.
- [ ] Commit: `Image rendering: ImageFit height-cap + downscale-only fit math`.

---

## Task 3 — `.image` block routing in `MarkdownBlockGrouping` + tests

Own-line images become an `.image` block; inline images stay the placeholder token; every other routing byte-identical.

**Files:**
- `Lineform/Preview/MarkdownBlockGrouping.swift` — add the `.image` case to `MarkdownBlock` (after `.table`, line ~35) and a detection branch in `markdownBlocks(in:)` (line ~264 loop). Add a small pure helper for own-line image detection.
- `LineformTests/MarkdownBlockGroupingTests.swift` — add tests (existing file; no new pbxproj file).

**Interfaces:**
- Produces (new enum case + helper):
  ```swift
  // MarkdownBlock:
  case image(alt: String, path: String, sourceRange: NSRange)

  /// Pure detection: a line whose ENTIRE trimmed content is a single `![alt](path)` image.
  /// Returns (alt, path) or nil. Mid-text images (text before/after) return nil.
  enum MarkdownImageLine {
      static func wholeLineImage(_ line: String) -> (alt: String, path: String)?
  }
  ```
- Consumes: existing `lineStartOffsets` machinery in `markdownBlocks(in:)` to compute the UTF-16 `sourceRange` of the image on its line (mirror how the checkbox marker range is computed: `sourceRange = NSRange(location: lineStartOffsets[index], length: (lines[index] as NSString).length)` — span the whole line, since Reconnect rewrites the entire `![…](…)` and the line is solely the image).

**Implementation notes:**
- `MarkdownImageLine.wholeLineImage`: trim the line; anchor-match `^!\[([^\]\n]*)\]\(([^\)\n]+)\)$` against the TRIMMED line (reuse the same character classes as `MarkdownPreviewRenderer.imageRegex`, but anchored with `^…$`). Return `(alt, path)` on a full-line match, else nil.
- Detection branch placement in `markdownBlocks(in:)`: add it inside the `while` loop, guarded by `!inFence`, positioned AFTER the table/HR/blockquote/list checks but BEFORE the `.lines` fallthrough (an image line matches none of those, so order among them is safe; place it as the last special-block check for minimal disruption). On match: `flushLines(upTo: index)`, append `.image(alt:path:sourceRange:)`, `index += 1`, `continue`.
- The `sourceRange` spans the whole source line (whitespace included) — the Reconnect rewrite re-verifies the `![…](…)` substring inside it (Task 6), so a leading/trailing space in the source is tolerated.
- Do NOT touch the inline path: `imageToken` in `MarkdownPreviewRenderer` still handles mid-text images unchanged, because a line with surrounding text never becomes `.image` and flows through `.lines` → `appendLines` → `inlineWithMath`/`inlineMarkdown` → `imageToken`.

**TDD steps:**
- [ ] Add failing tests to `MarkdownBlockGroupingTests`:
  - `testOwnLineImageBecomesImageBlock` — `markdownBlocks(in: ["![cat](cat.png)"])` == `[.image(alt: "cat", path: "cat.png", sourceRange: NSRange(location: 0, length: 15))]`.
  - `testImageBlockBracketedByLinesRuns` — `["intro", "![cat](cat.png)", "outro"]` == `[.lines(0..<1), .image(alt: "cat", path: "cat.png", sourceRange: NSRange(location: 6, length: 15)), .lines(2..<3)]` (offset 6 = "intro\n").
  - `testImageWithSurroundingWhitespaceStillOwnLine` — `["  ![a](a.png)  "]` → `.image(alt: "a", path: "a.png", sourceRange: <whole line>)`.
  - `testEmptyAltOwnLineImageBecomesImageBlock` — `["![](pic.jpg)"]` → `.image(alt: "", path: "pic.jpg", …)`.
  - `testMidTextImageStaysInLinesRun` — `["see ![cat](cat.png) here"]` == `[.lines(0..<1)]` (inline; NOT `.image`).
  - `testImageInsideFencedCodeIsNotImageBlock` — `["```", "![cat](cat.png)", "```"]` == `[.lines(0..<3)]`.
  - Add a `MarkdownImageLine` direct test: `testWholeLineImageParsesAltAndPath` and `testWholeLineImageRejectsMidText`.
  - **Regression:** confirm an existing test like `testPlainLinesAreOneLinesBlock` still passes (the whole suite is run below).
- [ ] Run to fail:
  `xcodebuild test … -only-testing:LineformTests/MarkdownBlockGroupingTests`
- [ ] Implement the enum case + `MarkdownImageLine` + the detection branch. (No new files → no pbxproj change.)
- [ ] Run to pass. Expect: all `MarkdownBlockGroupingTests` pass (existing + new).
- [ ] Commit: `Image rendering: own-line image → .image block routing (inline stays placeholder)`.

---

## Task 4 — `ImageAttachmentProvider` (load + downscale + memory cache) behind a protocol + fake tests

Isolate the disk-loading raster behind a protocol so the renderer and tests never touch real files unless they want to. Mirror `MermaidImageProvider` + `DiagramCacheBudget` + `RasterImageCost`.

**Files:**
- NEW `Lineform/Preview/ImageRendering.swift` (product; pbxproj — app target + `Lineform/Preview` group).
- NEW `LineformTests/ImageAttachmentProviderTests.swift` (pbxproj — LineformTests).
- `Lineform/Preview/DiagramCardStyle.swift` — add an `ImageCacheBudget` enum sibling of `DiagramCacheBudget`/`MathCacheBudget` (small edit; existing file, no pbxproj change).

**Interfaces:**
- Produces:
  ```swift
  protocol ImageAttachmentProviding {
      /// NSImage for a resolved local image URL, scaled to FIT within `maxSize`
      /// (aspect preserved, downscale-only — never upscaled past native size), cached.
      /// nil on failure (unreadable / corrupt / out-of-scope). `maxSize = (columnWidth, maxImageHeight)`.
      func image(at url: URL, maxSize: CGSize, scale: CGFloat) -> NSImage?
  }

  final class ImageAttachmentProvider: ImageAttachmentProviding { … }        // real, NSCache-backed

  /// Cache key: url path + modification date + fitted box + scale (mirrors MermaidCacheKey).
  enum ImageAttachmentCacheKey {
      static func key(url: URL, modificationDate: Date?, maxSize: CGSize, scale: CGFloat) -> String
  }
  ```
  ```swift
  // DiagramCardStyle.swift
  enum ImageCacheBudget {
      static let countLimit = 256
      static let totalCostLimitBytes = 128 * 1024 * 1024   // 128 MB ceiling
  }
  ```
- Consumes: `AppKit` (`NSImage`, downscale draw), `RasterImageCost`, `ImageFit.size`.

**Implementation notes:**
- Real provider: `NSCache<NSString, NSImage>` with `countLimit = ImageCacheBudget.countLimit`, `totalCostLimit = ImageCacheBudget.totalCostLimitBytes`. Also a small `failureCache: NSCache<NSString, NSNumber>` so an unreadable/out-of-scope URL isn't re-probed every preview pass (mirrors `MermaidImageProvider.failureCache`); DO cache-key the failure by url+mtime so a later auto-heal (file appears) uses a fresh key and retries.
- `image(at:maxSize:scale:)`:
  1. Compute the cache key (url + modification date via `FileManager.default.attributesOfItem(atPath:)[.modificationDate]` + maxSize + scale).
  2. Cache hit → return it; failure-cache hit → return nil.
  3. Load: `NSImage(contentsOf: url)`; nil → record failure, return nil. (This is the sandbox-scope failure point: an out-of-scope file loads nil → placeholder + Reconnect.)
  4. `let fitted = ImageFit.size(for: source.size, in: maxSize)`; draw the source into a new `NSImage(size: fitted)` at Retina `scale` (downscaled raster, so the cache holds the SMALL bitmap, not the original — no bloat). Set `accessibilityDescription` is done by the caller (renderer), not here.
  5. `cache.setObject(downscaled, forKey: key, cost: RasterImageCost.bytes(for: downscaled))`; return it.
- Add a `DisabledImageAttachmentProvider` (always returns nil) mirroring `DisabledMermaidImageProvider`, for the renderer's back-compat `render(_:profile:)` convenience and tests that don't want image loading.

**TDD steps (unit-test the cache keying + failure→nil via a FAKE, plus the real provider against a temp file):**
- [ ] Write `ImageAttachmentProviderTests`:
  - `testCacheKeyIncludesUrlModificationDateAndBox` — `ImageAttachmentCacheKey.key` differs when url differs, when modificationDate differs, and when maxSize width differs; is stable for identical inputs. (Pure string assertions — no files.)
  - `testMissingFileReturnsNil` — real `ImageAttachmentProvider().image(at: <tmp>/nope.png, maxSize: CGSize(700,500), scale: 2)` == nil.
  - `testCorruptImageReturnsNil` — write `<tmp>/bad.png` containing `"not an image"`; `image(at:…)` == nil (NSImage(contentsOf:) fails).
  - `testValidImageLoadsAndDownscalesWithinBox` — write a real 400×200 PNG to `<tmp>` (build it with an `NSImage`/`NSBitmapImageRep` in the test), then `image(at:…, maxSize: CGSize(100, 500), scale: 1)` returns non-nil with `size` fitted to width ≤ 100 (assert `result.size.width <= 100.5`). This exercises the downscale-only path.
  - `testSmallImageIsNotUpscaled` — write a 40×40 PNG; `image(at:…, maxSize: CGSize(700,500), scale:1).size` ≈ 40×40.
  - (Optional fake) `testProviderProtocolIsInjectable` — a `FakeImageAttachmentProvider` conforming to `ImageAttachmentProviding` returns a canned image, proving the seam is protocol-injectable for Task 5.
- [ ] Run to fail:
  `xcodebuild test … -only-testing:LineformTests/ImageAttachmentProviderTests`
- [ ] Implement `ImageRendering.swift` + `ImageCacheBudget` in `DiagramCardStyle.swift`. Register the two new files in pbxproj. `xcodebuild build`.
- [ ] Run to pass. Expect: all tests pass.
- [ ] Commit: `Image rendering: ImageAttachmentProvider (downscale + memory cache, protocol-isolated)`.

---

## Task 5 — `appendImageBlock` renderer method + `documentDirectory` threading (render is manual-verified)

Emit either a left-aligned `BlockRenderedAttachment` for a resolved local image, or the placeholder run tagged `.imageSourceRange` + a Reconnect marker. Thread `documentDirectory` from the container to the renderer.

**Files:**
- `Lineform/Preview/MarkdownPreviewRenderer.swift` — new `appendImageBlock(...)` (sibling of `appendMermaidBlock` ~line 466 / `appendMathBlock` ~line 550); new `.image` case in the block dispatch `switch` (~line 77); new `documentDirectory: URL?` parameter on `render(...)` (default nil) and on the back-compat `render(_:profile:)` convenience (passes nil); add the `imageProvider: ImageAttachmentProviding` parameter to `render(...)` (default `DisabledImageAttachmentProvider()` in the convenience); add `imageBlockSpacing(...)` helper.
- `Lineform/Preview/MarkdownPreviewRenderer.swift` — add the `.imageSourceRange` + `.imageReconnect` `NSAttributedString.Key`s next to `.checkboxSourceRange` (top of file).
- `Lineform/Preview/MarkdownPreviewTextView.swift` (in `MarkdownPreviewViewRepresentable.swift`) — pass a real `ImageAttachmentProvider()` + `documentDirectory` into `render(...)` inside `apply(text:profile:)`; add `documentDirectory` storage + `apply(text:profile:documentDirectory:)`.
- `Lineform/Preview/MarkdownPreviewViewRepresentable.swift` — add `var documentDirectory: URL?` to the representable; forward it in `makeNSView`/`updateNSView`.
- `Lineform/Preview/DebouncedMarkdownPreviewView.swift` — add `var documentDirectory: URL?`; forward it.
- `Lineform/Editor/EditorContainerView.swift` — pass `documentDirectory: currentFileURL?.deletingLastPathComponent()` into both `DebouncedMarkdownPreviewView` call sites (read + split, ~lines 939 / 952).
- `LineformTests/MarkdownPreviewRendererTests.swift` — add renderer-level tests (existing file).

**Interfaces:**
- Consumes: `ImageResolver.resolve(path:documentDirectory:)`, `ImageFit.maxHeight`/`.size` (indirectly via provider), `ImageAttachmentProviding.image(at:maxSize:scale:)`, `BlockRenderedAttachment`, existing `bodyBlockSpacingAttributes` / `blockSpacingAttributes`.
- Produces:
  ```swift
  // new NSAttributedString.Key values
  static let imageSourceRange = NSAttributedString.Key("lineform.imageSourceRange")   // NSValue(range:)
  static let imageReconnect   = NSAttributedString.Key("lineform.imageReconnect")     // NSNumber(true) marker on the placeholder run

  private func appendImageBlock(
      alt: String,
      path: String,
      sourceRange: NSRange,
      to output: NSMutableAttributedString,
      profile: ReadingProfile,
      theme: Theme,
      columnWidth: CGFloat,
      documentDirectory: URL?,
      imageProvider: ImageAttachmentProviding,
      bodyAttributes: [NSAttributedString.Key: Any]
  )

  private func imageBlockSpacing(
      _ base: [NSAttributedString.Key: Any],
      profile: ReadingProfile
  ) -> [NSAttributedString.Key: Any]   // paragraphStyle with paragraphSpacing/Before = max(floor, blockSpacing + extra)
  ```

**Implementation notes:**
- Dispatch: `case .image(let alt, let path, let sourceRange): appendImageBlock(...); appendBlockSeparator(afterLine: <lineIndex of image>, ...)`. The `.image` case needs the source LINE index for the trailing-newline rule — carry it in the enum OR recompute. Simplest: the grouping already knows the line index; the block `.image` currently carries `sourceRange` (whole line). Since `appendBlockSeparator` needs the LINE index, add it to the case: change to `case image(alt:path:sourceRange:lineIndex:)` and update Task 3 tests accordingly, OR pass `sourceRange`-derived info. **Decision: add `lineIndex: Int` to the `.image` case** (adjust Task 3 tests to include it) so the separator matches mermaid/table exactly (`appendBlockSeparator(afterLine: lineIndex, to: output, totalLines: lines.count, attributes: bodyAttributes)`).
- Resolution + emit:
  - `switch ImageResolver.resolve(path: path, documentDirectory: documentDirectory)`:
    - `.localFile(let url)`: viewport-derived box → `let maxHeight = ImageFit.maxHeight(visibleViewportHeight: <viewport>)`. The renderer has no live view; use a sensible fixed viewport fallback here (`maxHeight` uses the 500 ceiling most of the time) — pass the **column width** and a `maxHeight` computed from `NSScreen.main?.visibleFrame.height ?? 900` (documented approximation; the on-resize refit re-fits width via `BlockAttachmentRefit`, and the height cap is enforced by the provider's fitted raster). `let scale = NSScreen.main?.backingScaleFactor ?? 2`. `guard let image = imageProvider.image(at: url, maxSize: CGSize(width: columnWidth, height: maxHeight), scale: scale) else { <emit placeholder as in .unresolved> }`. On success: `image.accessibilityDescription = alt.isEmpty ? "Image" : alt`; build a `BlockRenderedAttachment` exactly like mermaid (natural size → width `min(natural.width, columnWidth)`, height scaled preserving aspect); append `NSAttributedString(attachment:)` with `imageBlockSpacing` on the PARAGRAPH (see spacing note). Left-aligned = no centering paragraph style (identical to mermaid).
    - `.remote`, `.unresolved`, OR local-load-failure: emit the placeholder run — `"🖼 \(label)"` (label = alt, else filename via a helper mirroring the existing `imageFilename`, else "Image") styled like the current `imageToken` (foreground at 0.6 alpha) — with `.imageSourceRange = NSValue(range: sourceRange)` and `.imageReconnect = NSNumber(value: true)` on the run, and `imageBlockSpacing` applied so it matches the rendered form's spacing (no layout jump on resolve ↔ fallback).
- `imageBlockSpacing`: start from `blockSpacingAttributes(base, profile:)`'s paragraph style; add an extra image margin and clamp: `paragraphSpacing = max(floor, existingSpacing + extra)` and `paragraphSpacingBefore` likewise. Pick `floor = 12`, `extra = 6` (dial-able constants named at the top of the method with a comment); document that the floor is what prevents collapse at tight line-height.
- **Export path unchanged:** `DocumentExportRenderer` calls `render(...)` with no `documentDirectory` (nil) and the disabled image provider (or simply omits both, taking the defaults), so images stay `.unresolved` → placeholder in PDF/print (v1 decision). Verify `DocumentExportRenderer` still compiles with the new defaulted params.
- Thread `documentDirectory`: `EditorContainerView` → `DebouncedMarkdownPreviewView(documentDirectory:)` → `MarkdownPreviewViewRepresentable(documentDirectory:)` → `textView.apply(text:profile:documentDirectory:)` → stored + passed into `render(...)`. In `apply`, changing `documentDirectory` must force a re-render (add it to the `guard text != renderedText || profile != renderedProfile` short-circuit → also compare `documentDirectory != renderedDocumentDirectory`).

**TDD steps (renderer output is unit-assertable via attributes; the on-screen picture is manual):**
- [ ] Add failing `MarkdownPreviewRendererTests`:
  - `testUnresolvedImageEmitsPlaceholderWithReconnectMarker` — render `"![cat](missing.png)"` with `documentDirectory: nil` (relative → unresolved) using the DEFAULT disabled provider; assert the output string contains `"🖼 cat"` and that an `.imageSourceRange` attribute AND an `.imageReconnect` attribute are present somewhere in the output (enumerate attributes).
  - `testRemoteImageStaysPlaceholder` — render `"![c](https://x/y.png)"`; assert `"🖼 c"` present + `.imageReconnect` present (never a `BlockRenderedAttachment`).
  - `testResolvedLocalImageEmitsBlockAttachment` — write a real 400×200 PNG to a temp dir; render `"![cat](pic.png)"` with `documentDirectory: <tmpdir>` and a REAL `ImageAttachmentProvider()` (use the full `render(...)` signature); assert the output contains an `.attachment` that is a `BlockRenderedAttachment` and NO `.imageReconnect` marker, and the attachment's `image?.accessibilityDescription == "cat"`.
  - `testPlaceholderAndImageUseSameBlockSpacing` — render an unresolved and a resolved image; assert both runs carry a paragraph style whose `paragraphSpacing` equals `imageBlockSpacing`'s value (no layout jump). (Assert the numeric spacing on the paragraph style.)
  - `testOtherConstructsUnchanged` — a smoke test that `render("# H\n\nBody")` string is still `"H\n\nBody"` (guards the dispatch edit didn't disturb existing output). (Existing tests already cover this broadly; keep this as a local sanity check.)
- [ ] Run to fail:
  `xcodebuild test … -only-testing:LineformTests/MarkdownPreviewRendererTests`
- [ ] Implement `appendImageBlock`, the dispatch case (+ `lineIndex` on `.image`, updating Task 3 tests), the keys, `imageBlockSpacing`, and thread `documentDirectory`/`imageProvider` through the render call + the four view layers + `EditorContainerView`. No new files (edits only) → no pbxproj change, EXCEPT confirm nothing new was added.
- [ ] Run to pass: `MarkdownPreviewRendererTests` AND re-run `MarkdownBlockGroupingTests` (the `.image` case gained `lineIndex`).
- [ ] **Manual verification (state it explicitly — the on-screen render is not unit-tested):** build+run the app; open a workspace `.md` containing an own-line relative image and an absolute image; confirm both render as pictures, left-aligned, fit within the column with a height cap; resize the window and confirm the attachment refits (width) with no re-render and no runaway height; confirm a mid-sentence image stays `🖼`; confirm a remote URL stays `🖼` and (via Console / no network) never hits the network.
- [ ] Commit: `Image rendering: appendImageBlock (local → block attachment, else placeholder) + documentDirectory threading`.

---

## Task 6 — Reconnect pill: hover/hit-test → NSOpenPanel → pure link-rewrite → document.text (interaction is manual-verified; rewrite helper is unit-tested)

Reuse the checkbox `mouseDown` hit-test to detect a click on a placeholder carrying `.imageReconnect`, present an image-restricted `NSOpenPanel`, compute the new link, and rewrite `![alt](old)` → `![alt](new)` at the source range through the checkbox-toggle binding path.

**Files:**
- NEW `Lineform/Preview/ImageLinkRewrite.swift` (product; pbxproj — app target + `Lineform/Preview` group) — the pure rewrite + relative/absolute path helper.
- NEW `LineformTests/ImageLinkRewriteTests.swift` (pbxproj — LineformTests).
- `Lineform/Preview/MarkdownPreviewViewRepresentable.swift` — add `onImageReconnect: (NSRange) -> Void` to the representable + text view (mirror `onCheckboxToggle`); extend `mouseDown` to hit-test `.imageReconnect` runs and invoke the panel; add a hover affordance for the pill (see notes).
- `Lineform/Preview/DebouncedMarkdownPreviewView.swift` — thread `onImageReconnect`.
- `Lineform/Editor/EditorContainerView.swift` — add `reconnectImage(at:)` (sibling of `toggleCheckbox`) that presents `NSOpenPanel`, computes the new path, calls `ImageLinkRewrite.rewritten(...)`, and assigns `document.text`; pass it into both preview call sites.

**Interfaces:**
- Produces:
  ```swift
  enum ImageLinkRewrite {
      /// Rewrite the image reference spanning `range` in `text` to point at `newPath`, preserving
      /// the original alt text. Returns the new full text, or nil when `range` does not still span a
      /// single `![…](…)` image (stale range after an external edit) — same discipline as
      /// CheckboxToggle.toggledText.
      static func rewritten(in text: String, at range: NSRange, newPath: String) -> String?

      /// The link path to write: a path RELATIVE to `documentDirectory` when `pickedFile` is within
      /// (under) that directory, otherwise the absolute path. Nil documentDirectory → absolute.
      static func linkPath(for pickedFile: URL, documentDirectory: URL?) -> String
  }
  ```
- Consumes: `Foundation`; the existing `MarkdownPreviewRenderer.imageRegex` character classes (re-declare an anchored regex here, don't reach into the renderer's private).

**Implementation notes:**
- `rewritten`: bounds-check `range` against `text` (like `CheckboxToggle`); extract the substring; match `^\s*!\[([^\]\n]*)\]\(([^\)\n]+)\)\s*$` (whole-line, tolerating the surrounding whitespace the source range spans); nil if no match; else reconstruct `"![\(alt)](\(newPath))"` preserving any leading/trailing whitespace the original had, and `ns.replacingCharacters(in: range, with: rebuilt)`.
- `linkPath`: if `documentDirectory != nil` and `pickedFile.standardizedFileURL.path` has the `documentDirectory.standardizedFileURL.path + "/"` prefix, return the relative remainder (path components after the dir, joined by "/"); else return `pickedFile.standardizedFileURL.path` (absolute). (Do NOT compute `../` escapes — only a direct under-the-dir relative or an absolute path, per spec.)
- `mouseDown` extension: after the checkbox check, add an `imageReconnectSourceRange(at:)` hit-test mirroring `checkboxSourceRange(at:)` but reading `.imageSourceRange` on a run that also carries `.imageReconnect` (only fire when the click lands within the placeholder run's glyph rect / the pill's trailing rect). On hit → `onImageReconnect(range)`.
- Pill hover affordance: draw a quiet translucent pill (`usesDarkChrome`-aware, `arrow.counterclockwise` SF Symbol + "Reconnect") in the placeholder run's trailing area on hover — mirror the code-block copy-pill treatment. Track hover via `updateTrackingAreas` / `mouseMoved` and invalidate the pill rect; this is view chrome, not text. (If the copy-pill implementation is reused, name the shared piece; if none exists yet for the preview view, a minimal `NSView` overlay drawn in `drawRect` over the placeholder's bounding rect is acceptable — keep it small and theme-aware.)
- `EditorContainerView.reconnectImage(at range:)`:
  ```swift
  private func reconnectImage(at range: NSRange) {
      let panel = NSOpenPanel()
      panel.allowedContentTypes = [.png, .jpeg, .gif, .heic, .tiff, .bmp, .image]   // image UTIs
      panel.allowsMultipleSelection = false
      panel.canChooseDirectories = false
      guard panel.runModal() == .OK, let picked = panel.url else { return }
      let dir = currentFileURL?.deletingLastPathComponent()
      let newPath = ImageLinkRewrite.linkPath(for: picked, documentDirectory: dir)
      guard let newText = ImageLinkRewrite.rewritten(in: document.text, at: range, newPath: newPath) else { return }
      document.text = newText
  }
  ```
  This is a normal `document.text` edit → dirty-tracking, autosave, single-⌘Z undo (identical to `toggleCheckbox`). The `NSOpenPanel` grant gives the app a security scope for the picked file (Powerbox), so the very next re-render resolves + loads it.

**TDD steps (rewrite helper is fully unit-tested; the panel + pill are manual):**
- [ ] Write `ImageLinkRewriteTests`:
  - `testRewriteReplacesPathPreservingAlt` — `rewritten(in: "![cat](old.png)", at: NSRange(0,15), newPath: "new.png")` == `"![cat](new.png)"`.
  - `testRewritePreservesSurroundingWhitespace` — `rewritten(in: "  ![a](x.png)  ", at: <whole range>, newPath: "y.png")` == `"  ![a](y.png)  "`.
  - `testRewriteStaleRangeReturnsNil` — a range that no longer spans an image (e.g. text edited to `"hello world"`) → nil.
  - `testRewriteEmptyAltPreserved` — `"![](a.png)"` → `"![](b.png)"`.
  - `testLinkPathRelativeWhenUnderDocumentDirectory` — `linkPath(for: <dir>/img/pic.png, documentDirectory: <dir>)` == `"img/pic.png"`.
  - `testLinkPathAbsoluteWhenOutsideDocumentDirectory` — `linkPath(for: /elsewhere/pic.png, documentDirectory: <dir>)` == `"/elsewhere/pic.png"`.
  - `testLinkPathAbsoluteWhenNilDirectory` — nil dir → absolute path.
- [ ] Run to fail:
  `xcodebuild test … -only-testing:LineformTests/ImageLinkRewriteTests`
- [ ] Implement `ImageLinkRewrite.swift` (register in pbxproj), then wire `onImageReconnect` through the views + `reconnectImage(at:)` in `EditorContainerView` + the `mouseDown` hit-test + hover pill. Register the new test file in pbxproj. `xcodebuild build`.
- [ ] Run to pass: `ImageLinkRewriteTests`.
- [ ] **Manual verification (state it explicitly — the panel + pill hover/click are not unit-tested):** run the app; break an image path so the placeholder + Reconnect pill show; hover → pill appears; click → `NSOpenPanel` (image types only); pick a file UNDER the document dir → confirm the `.md` link becomes relative and the image renders; pick a file OUTSIDE → confirm absolute path written; single ⌘Z reverts the reconnect; drop the originally-missing file back into place and confirm auto-heal on the next re-render (no manual refresh); confirm the whole flow never touches the network.
- [ ] Commit: `Image rendering: Reconnect pill → NSOpenPanel → link rewrite (relative/absolute, stale-safe)`.

---

## Task 7 — Full default-plan gate + docs

**Files:**
- `CLAUDE.md` — add a Main-Features bullet for local image rendering + Reconnect (mirror the mermaid/math bullets' depth: block-only, left-aligned, fit box + `max(240,min(500,0.70×viewport))` cap, downscale-only memory cache, network-free, sandbox + Reconnect escape hatch, export keeps placeholder v1, auto-heal).
- `docs/superpowers/specs/2026-07-18-inline-local-image-rendering-design.md` — flip Status to note implementation landed (optional; keep the spec as the record).
- Info sidebar (`MarkdownReference` in `Lineform/Outline`) — OPTIONAL: the image row already teaches `![alt](path)`; no change required unless the copy should mention local rendering. Skip unless trivial.

**TDD steps:**
- [ ] Run the FULL default plan (all new + existing pure tests, crash-free) — warn the user first about the TCC Documents prompt (ad-hoc re-signed test host) and have them click Allow:
  ```
  xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO
  ```
  Read the output; report exact pass/fail counts. Expect: green, including `TestPlanGuardTests` (no test-plan drift) and every pre-existing renderer/grouping test.
- [ ] Update `CLAUDE.md` Main-Features with the image bullet.
- [ ] Commit: `Image rendering: docs (CLAUDE.md feature bullet) + full default-plan gate green`.

---

## Verification command (per-task)
```
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/<ClassName>/<testName>
```
Full default plan on the final task (drop `-only-testing`). The hosted plan is NOT needed for this feature (no window-motion / PDF-byte changes), though if the manual resize check surfaces a refit regression, re-run `-testPlan LineformHosted` on a quiet machine per CLAUDE.md.

## Manual-verified surfaces (not unit-tested — called out per project quality bar)
- The on-screen picture render (Task 5): TextKit attachment layout can't be pixel-asserted in the pure suite; the renderer OUTPUT (attachment presence/type, accessibilityDescription, spacing, markers) IS asserted.
- The Reconnect pill hover/click + `NSOpenPanel` (Task 6): the pure `ImageLinkRewrite` helper IS unit-tested; the panel presentation and hover chrome are manual.
- Window-resize refit of a real image, auto-heal on file-appear, and the network-never invariant (Tasks 5–6): manual.
