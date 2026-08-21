# Math / LaTeX Support Implementation Plan

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render inline `$…$` and block `$$…$$` LaTeX math as typeset equations in Read and Preview modes (Write shows source), mirroring the existing Mermaid feature.

**Architecture:** A new isolated provider seam (`MathImageProvider` in `Lineform/Preview/MathRendering.swift`) wraps SwiftMath, rendering each equation to a cached raster `NSImage` embedded as an `NSTextAttachment` — exactly as `MermaidImageProvider` does. A pure delimiter parser applies GitHub/CommonMark `$` rules so prose dollar signs are never mangled. Block math plugs into the renderer's existing block-accumulation loop; inline math becomes a new inline-token kind that emits a baseline-aligned attachment. Every failure degrades to a captioned/inline-code source fallback.

**Tech Stack:** Swift, AppKit, TextKit (`NSAttributedString`/`NSTextAttachment`), SwiftMath (SPM), XCTest.

## Global Constraints

- **No WebView, no JavaScript, no network, no analytics.** Rendering is fully local. (Copied from spec.)
- **Dependency:** SwiftMath, MIT, pinned to an exact version via SPM (mirror how `beautiful-mermaid-swift` is pinned `exactVersion`).
- **Delimiters:** `$…$` (inline) and `$$…$$` (block) only. No `\(…\)`/`\[…\]`.
- **Delimiter rules (CommonMark/GitHub math):** opening `$` not followed by whitespace; closing `$` not preceded by whitespace; `$` adjacent to a digit does not open inline math; `\$` is a literal dollar; anything that does not cleanly open-and-close stays literal text.
- **Modes:** render in Read + Preview only. Write mode is unchanged (shows source).
- **Every render is defensive** (`do/catch`): any failure → captioned-source fallback (block) or inline-code fallback (inline). Document content is never altered.
- **Accessibility:** attach the raw LaTeX as the image's `accessibilityDescription`.
- **Reading experience:** render at the reading profile's point size × screen scale, in the theme foreground color.
- **Verification gate** (from `CLAUDE.md`, quit Xcode first):
  ```sh
  xcodebuild test -project Lineform.xcodeproj -scheme Lineform \
    -destination 'platform=macOS' -parallel-testing-enabled NO
  ```
  For unattended iteration, prefer build-only (`xcodebuild build …`) and run the full test suite once at the end (CLI test runs re-sign ad-hoc and re-trigger TCC prompts).

---

## File Structure

- `Lineform/Preview/MathRendering.swift` (**create**) — the SwiftMath seam and the pure delimiter parser: `MathDelimiters`, `MathBlockFence`, `MathBlockPolicy`, `MathCacheKey`, `MathRenderOutcome`, `MathStyle`, `MathImageProviding`, `DisabledMathImageProvider`, `MathImageProvider`.
- `Lineform/Preview/MarkdownPreviewRenderer.swift` (**modify**) — thread a `MathImageProviding` through `render(...)`; add block-`$$` accumulation and an inline-math token that emits an attachment.
- `Lineform/Preview/MarkdownPreviewViewRepresentable.swift` (**modify**) — construct a real `MathImageProvider` and pass it into `render(...)`.
- `Lineform/Editor/MarkdownWritingToolsProtection.swift` (**modify**) — add math regions to `protectedRanges`.
- `LineformTests/MathRenderingTests.swift` (**create**) — delimiter parser, size guard, cache key, provider.
- `LineformTests/MarkdownPreviewRendererTests.swift` (**modify**) — block + inline math rendering/fallback via a fake provider.
- `LineformTests/MarkdownWritingToolsProtectionTests.swift` (**modify or create**) — math-region protection.
- `Lineform.xcodeproj/project.pbxproj` (**modify**) — add the SwiftMath package reference.
- `Lineform/Resources/Fonts/` (**add license files**) + `Lineform/Resources/FontLicenseReview.md` (**modify**).
- `CLAUDE.md`, `README.md`, `Lineform/Resources/*` help doc (**modify** — Task 8, only what's needed).

---

## Task 1: Add SwiftMath SPM dependency + license files

**Files:**
- Modify: `Lineform.xcodeproj/project.pbxproj` (5 sections, mirroring the `BeautifulMermaid` entries)
- Create: `Lineform/Resources/Fonts/SwiftMath-LICENSE.txt` and the font license files SwiftMath bundles
- Modify: `Lineform/Resources/FontLicenseReview.md`

**Interfaces:**
- Produces: the `SwiftMath` module, importable as `import SwiftMath` in the app target.

- [ ] **Step 1: Pick the exact SwiftMath version.** Check the latest release tag at `https://github.com/mgriebling/SwiftMath/releases` and pin that exact version (e.g. `1.7.1`). Record it here before editing.

- [ ] **Step 2: Add the package reference to `project.pbxproj`.** Mirror the four `beautiful-mermaid-swift` entries with new unique IDs (use `1F00000100000000000002A1`-style IDs not already present — grep first to confirm uniqueness). Add:

  In `PBXBuildFile` section (near line 92, after the BeautifulMermaid build file):
  ```
  1F00000100000000000002A1 /* SwiftMath in Frameworks */ = {isa = PBXBuildFile; productRef = 1F00001300000000000002A2 /* SwiftMath */; };
  ```
  In `PBXFrameworksBuildPhase` files list (near line 199, after BeautifulMermaid in Frameworks):
  ```
  1F00000100000000000002A1 /* SwiftMath in Frameworks */,
  ```
  In the target's `packageProductDependencies` (near line 408, after BeautifulMermaid):
  ```
  1F00001300000000000002A2 /* SwiftMath */,
  ```
  In the project's `packageReferences` list (near line 467, after beautiful-mermaid-swift):
  ```
  1F00001400000000000002A3 /* XCRemoteSwiftPackageReference "SwiftMath" */,
  ```
  In `XCRemoteSwiftPackageReference` section (near line 832):
  ```
  1F00001400000000000002A3 /* XCRemoteSwiftPackageReference "SwiftMath" */ = {
      isa = XCRemoteSwiftPackageReference;
      repositoryURL = "https://github.com/mgriebling/SwiftMath";
      requirement = {
          kind = exactVersion;
          version = 1.7.1;
      };
  };
  ```
  In `XCSwiftPackageProductDependency` section (near line 848):
  ```
  1F00001300000000000002A2 /* SwiftMath */ = {
      isa = XCSwiftPackageProductDependency;
      package = 1F00001400000000000002A3 /* XCRemoteSwiftPackageReference "SwiftMath" */;
      productName = SwiftMath;
  };
  ```

- [ ] **Step 3: Resolve the package.**

  Run: `xcodebuild -resolvePackageDependencies -project Lineform.xcodeproj -scheme Lineform`
  Expected: resolves SwiftMath (and existing packages) with no error; `Package.resolved` gains a `SwiftMath` pin.

- [ ] **Step 4: Prove the module links** with a one-line throwaway import build.

  Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -quiet`
  Expected: BUILD SUCCEEDED (SwiftMath is now linkable even though unused).

- [ ] **Step 5: Add SwiftMath's license files.** Copy SwiftMath's `LICENSE` (MIT) and the bundled font license files (Latin Modern Math / TeX Gyre Termes → GUST Font License; XITS Math → OFL; KpMath → SIL OFL) from the resolved package checkout (`~/Library/Developer/Xcode/DerivedData/…/SourcePackages/checkouts/SwiftMath/`) into `Lineform/Resources/Fonts/` as `SwiftMath-LICENSE.txt`, `GUST-FontLicense.txt`, `OFL-XITSMath.txt`, `OFL-KpMath.txt`.

- [ ] **Step 6: Update `FontLicenseReview.md`.** Add a "SwiftMath (math rendering)" subsection under Bundled Font Set listing the fonts + licenses, add the new files under License Files, and note SwiftMath's code is MIT.

- [ ] **Step 7: Commit.**
  ```bash
  git add Lineform.xcodeproj/project.pbxproj Package.resolved Lineform.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved Lineform/Resources/Fonts Lineform/Resources/FontLicenseReview.md
  git commit -m "Math: add SwiftMath SPM dependency (MIT) + license files"
  ```

---

## Task 2: Pure delimiter parser (`MathDelimiters` + `MathBlockFence`)

**Files:**
- Create: `Lineform/Preview/MathRendering.swift`
- Create: `LineformTests/MathRenderingTests.swift`

**Interfaces:**
- Produces:
  - `enum MathBlockFence { static func blockDelimiterOnly(_ trimmedLine: String) -> Bool }` — true when a trimmed line is exactly `$$` (opens/closes a display block).
  - `enum MathBlockFence { static func singleLineBlock(_ trimmedLine: String) -> String? }` — for a line like `$$ x $$`, returns the inner LaTeX; else nil.
  - `struct MathInlineSegment { enum Kind { case text; case math }; let kind: Kind; let value: String }`
  - `enum MathDelimiters { static func segments(in line: String) -> [MathInlineSegment] }` — splits a line into ordered text/inline-math segments applying the CommonMark `$` rules. `value` for `.math` is the LaTeX without the `$` delimiters; for `.text` it is the literal text (with `\$` still escaped — the renderer unescapes for display).

- [ ] **Step 1: Write failing tests** in `LineformTests/MathRenderingTests.swift`:

```swift
import XCTest
@testable import Lineform

final class MathRenderingTests: XCTestCase {
    // MARK: Block fence
    func testBlockDelimiterOnly() {
        XCTAssertTrue(MathBlockFence.blockDelimiterOnly("$$"))
        XCTAssertTrue(MathBlockFence.blockDelimiterOnly("  $$  "))
        XCTAssertFalse(MathBlockFence.blockDelimiterOnly("$"))
        XCTAssertFalse(MathBlockFence.blockDelimiterOnly("$$x"))
    }
    func testSingleLineBlock() {
        XCTAssertEqual(MathBlockFence.singleLineBlock("$$x^2$$"), "x^2")
        XCTAssertEqual(MathBlockFence.singleLineBlock("$$ E=mc^2 $$"), " E=mc^2 ")
        XCTAssertNil(MathBlockFence.singleLineBlock("$$"))
        XCTAssertNil(MathBlockFence.singleLineBlock("$x$"))
    }

    // MARK: Inline delimiter rules
    private func kinds(_ line: String) -> [MathInlineSegment.Kind] {
        MathDelimiters.segments(in: line).map(\.kind)
    }
    private func mathValues(_ line: String) -> [String] {
        MathDelimiters.segments(in: line).filter { $0.kind == .math }.map(\.value)
    }
    func testSimpleInlineMath() {
        XCTAssertEqual(mathValues("the value $x^2$ here"), ["x^2"])
        XCTAssertEqual(kinds("the value $x^2$ here"), [.text, .math, .text])
    }
    func testDigitAdjacentDollarsAreProse() {
        XCTAssertEqual(mathValues("it costs $5 to $10 today"), [])          // rule 3
        XCTAssertEqual(kinds("it costs $5 to $10 today"), [.text])
    }
    func testOpeningDollarFollowedBySpaceIsProse() {
        XCTAssertEqual(mathValues("give me $ 5 and $ 6"), [])               // rule 1
    }
    func testClosingDollarPrecededBySpaceIsProse() {
        XCTAssertEqual(mathValues("a $x ^2$ b"), [])                        // rule 2 (space before close)
    }
    func testEscapedDollarIsLiteral() {
        XCTAssertEqual(mathValues(#"a \$5 and \$6 b"#), [])                 // rule 4
        XCTAssertEqual(kinds(#"a \$5 and \$6 b"#), [.text])
    }
    func testUnbalancedDollarStaysLiteral() {
        XCTAssertEqual(mathValues("a single $ here"), [])                   // rule 5/6
    }
    func testTwoInlineExpressions() {
        XCTAssertEqual(mathValues("$a+b$ and $c-d$"), ["a+b", "c-d"])
    }
}
```

- [ ] **Step 2: Run to verify failure.**
  Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -only-testing:LineformTests/MathRenderingTests -parallel-testing-enabled NO`
  Expected: FAIL — `MathBlockFence`/`MathDelimiters` undefined.

- [ ] **Step 3: Implement the parser** in `Lineform/Preview/MathRendering.swift`:

```swift
import AppKit
import CryptoKit

/// Fence detection for display ($$) math blocks.
enum MathBlockFence {
    /// True when a trimmed line is exactly `$$` (a display-block open/close delimiter).
    static func blockDelimiterOnly(_ trimmedLine: String) -> Bool {
        trimmedLine.trimmingCharacters(in: .whitespaces) == "$$"
    }

    /// For a single-line block `$$…$$`, return the inner LaTeX; else nil.
    static func singleLineBlock(_ trimmedLine: String) -> String? {
        let t = trimmedLine.trimmingCharacters(in: .whitespaces)
        guard t.count >= 5, t.hasPrefix("$$"), t.hasSuffix("$$") else { return nil }
        let inner = t.dropFirst(2).dropLast(2)
        return inner.isEmpty ? nil : String(inner)
    }
}

/// One ordered piece of a line: literal text or an inline-math expression.
struct MathInlineSegment: Equatable {
    enum Kind { case text, math }
    let kind: Kind
    let value: String
}

/// Splits a line into text/inline-math segments using GitHub/CommonMark `$` rules so that
/// ordinary prose dollar signs ("$5") are never treated as math.
enum MathDelimiters {
    static func segments(in line: String) -> [MathInlineSegment] {
        let chars = Array(line)
        var segments: [MathInlineSegment] = []
        var text = ""
        var i = 0

        func flushText() {
            if !text.isEmpty { segments.append(.init(kind: .text, value: text)); text = "" }
        }

        while i < chars.count {
            let c = chars[i]
            // Rule 4: \$ is a literal dollar.
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
                text.append("\\"); text.append("$"); i += 2; continue
            }
            if c == "$", let close = closingIndex(chars, openAt: i) {
                flushText()
                let latex = String(chars[(i + 1)..<close])
                segments.append(.init(kind: .math, value: latex))
                i = close + 1
                continue
            }
            text.append(c); i += 1
        }
        flushText()
        return segments
    }

    /// Given an opening `$` at `open`, return the index of a valid closing `$`, or nil.
    private static func closingIndex(_ chars: [Character], openAt open: Int) -> Int? {
        // Rule 1: opening `$` must not be followed by whitespace, and must have a next char.
        let next = open + 1
        guard next < chars.count, !chars[next].isWhitespace else { return nil }
        // Rule 3: a `$` adjacent to a digit does not open math (before or after).
        if open > 0, chars[open - 1].isNumber { return nil }
        if chars[next].isNumber { return nil }
        // Not a display `$$` opener handled inline.
        if chars[next] == "$" { return nil }

        var j = next
        while j < chars.count {
            if chars[j] == "\\", j + 1 < chars.count { j += 2; continue }   // skip escapes inside math
            if chars[j] == "$" {
                // Rule 2: closing `$` must not be preceded by whitespace.
                if chars[j - 1].isWhitespace { return nil }
                // Rule 3: closing `$` adjacent to a digit after it is prose, not a close.
                if j + 1 < chars.count, chars[j + 1].isNumber { return nil }
                return j
            }
            j += 1
        }
        return nil   // Rule 5/6: unbalanced → not math.
    }
}
```

- [ ] **Step 4: Run to verify pass.**
  Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -only-testing:LineformTests/MathRenderingTests -parallel-testing-enabled NO`
  Expected: PASS (all parser tests).

- [ ] **Step 5: Commit.**
  ```bash
  git add Lineform/Preview/MathRendering.swift LineformTests/MathRenderingTests.swift
  git commit -m "Math: pure \$-delimiter parser with CommonMark rules + tests"
  ```

---

## Task 3: The provider seam (`MathImageProvider`)

**Files:**
- Modify: `Lineform/Preview/MathRendering.swift`
- Modify: `LineformTests/MathRenderingTests.swift`

**Interfaces:**
- Produces:
  - `enum MathStyle { case inline, display }`
  - `enum MathBlockPolicy { static let maxSourceLength = 20_000; static func shouldAttemptRender(source: String) -> Bool }`
  - `enum MathCacheKey { static func key(latex: String, style: MathStyle, foregroundHex: String, scale: CGFloat) -> String }`
  - `enum MathRenderOutcome { case image(NSImage); case skipped; case failed(String) }`
  - `protocol MathImageProviding: AnyObject { func outcome(latex: String, style: MathStyle, foreground: NSColor, pointSize: CGFloat, scale: CGFloat) -> MathRenderOutcome }`
  - `final class DisabledMathImageProvider: MathImageProviding` (always `.skipped`)
  - `final class MathImageProvider: MathImageProviding` (wraps SwiftMath)
  - reuse `MermaidHexColor.string(from:)` for hex (already exists) — do **not** duplicate it.

- [ ] **Step 1: Write failing tests** (append to `MathRenderingTests.swift`):

```swift
extension MathRenderingTests {
    func testMathSizeGuardBoundary() {
        XCTAssertTrue(MathBlockPolicy.shouldAttemptRender(source: String(repeating: "a", count: 20_000)))
        XCTAssertFalse(MathBlockPolicy.shouldAttemptRender(source: String(repeating: "a", count: 20_001)))
    }
    func testMathCacheKeyStableAndDistinct() {
        let a = MathCacheKey.key(latex: "x^2", style: .inline, foregroundHex: "#ffffff", scale: 2)
        XCTAssertEqual(a, MathCacheKey.key(latex: "x^2", style: .inline, foregroundHex: "#ffffff", scale: 2))
        XCTAssertNotEqual(a, MathCacheKey.key(latex: "x^3", style: .inline, foregroundHex: "#ffffff", scale: 2))
        XCTAssertNotEqual(a, MathCacheKey.key(latex: "x^2", style: .display, foregroundHex: "#ffffff", scale: 2))
        XCTAssertNotEqual(a, MathCacheKey.key(latex: "x^2", style: .inline, foregroundHex: "#000000", scale: 2))
        XCTAssertNotEqual(a, MathCacheKey.key(latex: "x^2", style: .inline, foregroundHex: "#ffffff", scale: 1))
    }
    func testDisabledProviderSkips() {
        let outcome = DisabledMathImageProvider().outcome(latex: "x^2", style: .inline, foreground: .white, pointSize: 18, scale: 2)
        if case .skipped = outcome {} else { XCTFail("disabled provider must skip") }
    }
    @MainActor func testLiveProviderRendersUprightNonEmptyImage() throws {
        // Guarded smoke test against real SwiftMath: a known-good formula renders to a
        // non-empty image. Catches a future SwiftMath bump that breaks rendering.
        let outcome = MathImageProvider().outcome(latex: "x^2+y^2", style: .display, foreground: .black, pointSize: 18, scale: 2)
        guard case .image(let image) = outcome else { return XCTFail("expected an image, got \(outcome)") }
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }
    @MainActor func testLiveProviderFailsOnGarbageLaTeX() {
        let outcome = MathImageProvider().outcome(latex: "\\frac{", style: .inline, foreground: .black, pointSize: 18, scale: 2)
        if case .failed = outcome {} else { XCTFail("malformed LaTeX must fail → fallback") }
    }
}
```

- [ ] **Step 2: Run to verify failure.**
  Run: `xcodebuild test … -only-testing:LineformTests/MathRenderingTests -parallel-testing-enabled NO`
  Expected: FAIL — symbols undefined.

- [ ] **Step 3: Implement the seam** (append to `MathRendering.swift`):

```swift
import SwiftMath

enum MathStyle { case inline, display }

enum MathBlockPolicy {
    static let maxSourceLength = 20_000
    static func shouldAttemptRender(source: String) -> Bool { source.count <= maxSourceLength }
}

enum MathCacheKey {
    static func key(latex: String, style: MathStyle, foregroundHex: String, scale: CGFloat) -> String {
        let styleTag = style == .inline ? "i" : "d"
        let material = "\(styleTag)\n\(scale)\n\(foregroundHex)\n\(latex)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum MathRenderOutcome { case image(NSImage), skipped, failed(String) }

protocol MathImageProviding: AnyObject {
    func outcome(latex: String, style: MathStyle, foreground: NSColor, pointSize: CGFloat, scale: CGFloat) -> MathRenderOutcome
}

final class DisabledMathImageProvider: MathImageProviding {
    func outcome(latex: String, style: MathStyle, foreground: NSColor, pointSize: CGFloat, scale: CGFloat) -> MathRenderOutcome { .skipped }
}

/// The single seam that touches SwiftMath. Every render is defensive; any failure → `.failed`.
final class MathImageProvider: MathImageProviding {
    private let cache = NSCache<NSString, NSImage>()
    private let failureCache = NSCache<NSString, NSString>()

    init() { cache.countLimit = 100; failureCache.countLimit = 200 }

    @MainActor
    func outcome(latex: String, style: MathStyle, foreground: NSColor, pointSize: CGFloat, scale: CGFloat) -> MathRenderOutcome {
        guard MathBlockPolicy.shouldAttemptRender(source: latex) else { return .skipped }
        let key = MathCacheKey.key(
            latex: latex, style: style,
            foregroundHex: MermaidHexColor.string(from: foreground), scale: scale
        ) as NSString
        if let cached = cache.object(forKey: key) { return .image(cached) }
        if let failure = failureCache.object(forKey: key) { return .failed(failure as String) }

        let label = MTMathUILabel()
        label.latex = latex
        label.labelMode = style == .inline ? .text : .display
        label.fontSize = pointSize
        label.textColor = foreground
        label.contentInsets = MTEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        // Parse/layout errors surface via `.error` (we do not display them inline).
        label.displayErrorInline = false
        label.sizeToFit()

        if let error = label.error {
            let message = error.localizedDescription
            failureCache.setObject(message as NSString, forKey: key)
            return .failed(message)
        }
        let size = label.intrinsicContentSize
        guard size.width > 0, size.height > 0 else {
            return .failed("Math render produced no image")
        }
        label.frame = CGRect(origin: .zero, size: size)
        guard let rep = label.bitmapImageRepForCachingDisplay(in: label.bounds) else {
            return .failed("Math render produced no bitmap")
        }
        rep.size = size
        label.cacheDisplay(in: label.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        cache.setObject(image, forKey: key)
        return .image(image)
    }
}
```

  Note: `MTMathUILabel`, `MTEdgeInsets`, `.text`/`.display`, `.error`, `.displayErrorInline` are SwiftMath symbols — verify exact spelling against the resolved checkout during implementation and adjust if the API differs (e.g. `MTEdgeInsets` may be `NSEdgeInsets` on macOS). If `bitmapImageRepForCachingDisplay` yields a blank image because the view was never in a window, fall back to drawing `label.layer` via `NSImage(size:flipped:)` + `label.layer?.render(in:)`.

- [ ] **Step 4: Run to verify pass** (build first to shake out SwiftMath API spelling):
  Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -quiet`
  Then: `xcodebuild test … -only-testing:LineformTests/MathRenderingTests -parallel-testing-enabled NO`
  Expected: BUILD SUCCEEDED, then PASS (including the two live SwiftMath smoke tests).

- [ ] **Step 5: Commit.**
  ```bash
  git add Lineform/Preview/MathRendering.swift LineformTests/MathRenderingTests.swift
  git commit -m "Math: SwiftMath provider seam (cached raster, size guard, fallback) + tests"
  ```

---

## Task 4: Block math `$$…$$` in the renderer

**Files:**
- Modify: `Lineform/Preview/MarkdownPreviewRenderer.swift`
- Modify: `LineformTests/MarkdownPreviewRendererTests.swift`

**Interfaces:**
- Consumes: `MathImageProviding`, `MathRenderOutcome`, `MathBlockFence`, `MathStyle` (Task 2–3).
- Produces: `render(...)` gains a `mathProvider: MathImageProviding` parameter; the back-compat `render(_:profile:)` passes `DisabledMathImageProvider()`.

- [ ] **Step 1: Write failing tests** (append to `MarkdownPreviewRendererTests.swift`). Add a fake provider:

```swift
private final class FakeMathProvider: MathImageProviding {
    let result: MathRenderOutcome
    init(_ result: MathRenderOutcome) { self.result = result }
    func outcome(latex: String, style: MathStyle, foreground: NSColor, pointSize: CGFloat, scale: CGFloat) -> MathRenderOutcome { result }
}

@MainActor
func testBlockMathRendersAttachmentWithAccessibility() throws {
    let image = NSImage(size: NSSize(width: 20, height: 12))
    let rendered = MarkdownPreviewRenderer().render(
        "$$\nx^2+y^2\n$$",
        profile: .original, columnWidth: 600,
        mermaidProvider: DisabledMermaidImageProvider(),
        mathProvider: FakeMathProvider(.image(image)),
        diagramLog: FakeLog(), reportRegistry: DiagramReportRegistry(), appVersion: "1.0"
    )
    var found: NSImage?
    rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { v, _, stop in
        if let a = v as? NSTextAttachment, let img = a.image { found = img; stop.pointee = true }
    }
    XCTAssertEqual(try XCTUnwrap(found).accessibilityDescription, "Math. x^2+y^2")
}

@MainActor
func testBlockMathFailureFallsBackToSource() {
    let out = MarkdownPreviewRenderer().render(
        "$$\n\\frac{\n$$",
        profile: .original, columnWidth: 600,
        mermaidProvider: DisabledMermaidImageProvider(),
        mathProvider: FakeMathProvider(.failed("boom")),
        diagramLog: FakeLog(), reportRegistry: DiagramReportRegistry(), appVersion: "1.0"
    ).string
    XCTAssertTrue(out.contains("Math (source)"))
    XCTAssertTrue(out.contains("\\frac{"))
    XCTAssertFalse(out.contains("$$"))
}
```

  (If `FakeLog` isn't already visible in this test file, reuse the one from `MermaidRenderingTests` by copying the small fake in, or make it `internal`.)

- [ ] **Step 2: Run to verify failure.**
  Run: `xcodebuild build … -quiet`
  Expected: FAIL — `render` has no `mathProvider:` parameter.

- [ ] **Step 3: Thread `mathProvider` + add block handling** in `MarkdownPreviewRenderer.swift`:
  - Add `mermaidProvider`-parallel parameter `mathProvider: MathImageProviding` to the full `render(...)`. Update the back-compat `render(_:profile:)` to pass `mathProvider: DisabledMathImageProvider()`.
  - In the main loop, alongside the mermaid accumulation, add display-math accumulation. Add a `var mathBody: [String]?`. Before the mermaid checks:
    ```swift
    if mathBody != nil {
        if MathBlockFence.blockDelimiterOnly(trimmed) {
            appendMathBlock(latex: mathBody!.joined(separator: "\n"), to: output,
                            profile: profile, theme: theme, columnWidth: columnWidth,
                            codeAttributes: codeAttributes, mathProvider: mathProvider)
            mathBody = nil
            if index < lines.count - 1 { output.append(NSAttributedString(string: "\n", attributes: bodyAttributes)) }
        } else { mathBody!.append(line) }
        index += 1; continue
    }
    ```
    And where new blocks open (not `inFence`, not mermaid): a single-line block first, then an opener:
    ```swift
    if !inFence, let inner = MathBlockFence.singleLineBlock(trimmed) {
        appendMathBlock(latex: inner, to: output, profile: profile, theme: theme,
                        columnWidth: columnWidth, codeAttributes: codeAttributes, mathProvider: mathProvider)
        if index < lines.count - 1 { output.append(NSAttributedString(string: "\n", attributes: activeBodyAttributes)) }
        index += 1; continue
    } else if !inFence, MathBlockFence.blockDelimiterOnly(trimmed) {
        mathBody = []; index += 1; continue
    }
    ```
    Flush an unclosed `mathBody` after the loop, mirroring the mermaid flush.
  - Add `appendMathBlock` and `appendMathFallback` (parallel to the mermaid pair, but no diagram log / report link — math failures aren't collected):
    ```swift
    private func appendMathBlock(latex: String, to output: NSMutableAttributedString,
        profile: ReadingProfile, theme: Theme, columnWidth: CGFloat,
        codeAttributes: [NSAttributedString.Key: Any], mathProvider: MathImageProviding) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pointSize = CGFloat(profile.fontSize)
        let outcome = mathProvider.outcome(latex: latex, style: .display,
            foreground: theme.textColor, pointSize: pointSize, scale: scale)
        switch outcome {
        case .image(let image):
            image.accessibilityDescription = "Math. \(latex)"
            let attachment = NSTextAttachment()
            attachment.image = image
            let natural = image.size
            let width = min(natural.width, max(columnWidth, 1))
            let height = natural.width > 0 ? natural.height * (width / natural.width) : natural.height
            attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            output.append(NSAttributedString(attachment: attachment))
        case .skipped, .failed:
            appendMathFallback(latex: latex, to: output, profile: profile, codeAttributes: codeAttributes)
        }
    }

    private func appendMathFallback(latex: String, to output: NSMutableAttributedString,
        profile: ReadingProfile, codeAttributes: [NSAttributedString.Key: Any]) {
        var captionAttributes = MarkdownSyntaxHighlighter.baseAttributes(for: profile)
        captionAttributes[.foregroundColor] = Theme.theme(for: profile).textColor.withAlphaComponent(0.6)
        if let font = captionAttributes[.font] as? NSFont {
            captionAttributes[.font] = NSFont.systemFont(ofSize: max(10, font.pointSize - 2))
        }
        output.append(NSAttributedString(string: "Math (source)", attributes: captionAttributes))
        output.append(NSAttributedString(string: "\n", attributes: captionAttributes))
        output.append(NSAttributedString(string: latex, attributes: codeAttributes))
    }
    ```

- [ ] **Step 4: Update all existing callers** of the full `render(...)` to pass `mathProvider:`. In tests, pass `FakeMathProvider(.skipped)` or `DisabledMathImageProvider()` where math is irrelevant, and in `MarkdownPreviewViewRepresentable` this is done in Task 6. Build to find every caller.
  Run: `xcodebuild build … -quiet` → fix each "missing argument" error.

- [ ] **Step 5: Run to verify pass.**
  Run: `xcodebuild test … -only-testing:LineformTests/MarkdownPreviewRendererTests -parallel-testing-enabled NO`
  Expected: PASS.

- [ ] **Step 6: Commit.**
  ```bash
  git add Lineform/Preview/MarkdownPreviewRenderer.swift LineformTests/MarkdownPreviewRendererTests.swift
  git commit -m "Math: render block \$\$…\$\$ equations with source fallback + tests"
  ```

---

## Task 5: Inline math `$…$` in the renderer

**Files:**
- Modify: `Lineform/Preview/MarkdownPreviewRenderer.swift`
- Modify: `LineformTests/MarkdownPreviewRendererTests.swift`

**Interfaces:**
- Consumes: `MathDelimiters.segments(in:)`, `MathImageProviding` (`.inline` style).
- Produces: inline `$…$` inside a body line renders as a baseline-aligned attachment; failure falls back to inline-code styling of the raw LaTeX.

- [ ] **Step 1: Write failing tests** (append to `MarkdownPreviewRendererTests.swift`):

```swift
@MainActor
func testInlineMathRendersAttachmentInline() throws {
    let image = NSImage(size: NSSize(width: 10, height: 8))
    let rendered = MarkdownPreviewRenderer().render(
        "the value $x^2$ is fixed",
        profile: .original, columnWidth: 600,
        mermaidProvider: DisabledMermaidImageProvider(),
        mathProvider: FakeMathProvider(.image(image)),
        diagramLog: FakeLog(), reportRegistry: DiagramReportRegistry(), appVersion: "1.0"
    )
    // Surrounding prose is preserved as text…
    XCTAssertTrue(rendered.string.contains("the value "))
    XCTAssertTrue(rendered.string.contains(" is fixed"))
    // …and the equation is an inline attachment with a baseline offset (bounds.origin.y != 0).
    var attachment: NSTextAttachment?
    rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { v, _, stop in
        if let a = v as? NSTextAttachment { attachment = a; stop.pointee = true }
    }
    let a = try XCTUnwrap(attachment)
    XCTAssertEqual(a.image?.accessibilityDescription, "Math. x^2")
    XCTAssertLessThan(a.bounds.origin.y, 0, "inline math sits on the baseline via a negative y offset")
}

@MainActor
func testInlineMathFailureFallsBackToCodeStyledSource() {
    let out = MarkdownPreviewRenderer().render(
        "bad $\\frac{$ here",
        profile: .original, columnWidth: 600,
        mermaidProvider: DisabledMermaidImageProvider(),
        mathProvider: FakeMathProvider(.failed("boom")),
        diagramLog: FakeLog(), reportRegistry: DiagramReportRegistry(), appVersion: "1.0"
    ).string
    XCTAssertTrue(out.contains("\\frac{"))       // raw LaTeX shown, not dropped
}

@MainActor
func testProseDollarsAreNotTreatedAsMath() {
    let out = MarkdownPreviewRenderer().render(
        "it costs $5 to $10 today",
        profile: .original, columnWidth: 600,
        mermaidProvider: DisabledMermaidImageProvider(),
        mathProvider: FakeMathProvider(.failed("should not be called")),
        diagramLog: FakeLog(), reportRegistry: DiagramReportRegistry(), appVersion: "1.0"
    ).string
    XCTAssertEqual(out, "it costs $5 to $10 today")
}
```

- [ ] **Step 2: Run to verify failure.**
  Run: `xcodebuild test … -only-testing:LineformTests/MarkdownPreviewRendererTests -parallel-testing-enabled NO`
  Expected: FAIL — inline math not yet handled.

- [ ] **Step 3: Route body lines through math segmentation.** In `render(...)`, the `else` branch currently calls `inlineMarkdown(in:baseAttributes:profile:)`. Replace that single call with a segmenter that splits the line into math / non-math pieces first, applying `inlineMarkdown` to non-math text and an attachment for math:

```swift
} else {
    output.append(inlineWithMath(in: line, baseAttributes: activeBodyAttributes,
        profile: profile, theme: theme, mathProvider: mathProvider))
}
```

  Add the method:

```swift
private func inlineWithMath(in line: String, baseAttributes: [NSAttributedString.Key: Any],
    profile: ReadingProfile, theme: Theme, mathProvider: MathImageProviding) -> NSAttributedString {
    let segments = MathDelimiters.segments(in: line)
    // Fast path: no inline math → existing behavior unchanged.
    if !segments.contains(where: { $0.kind == .math }) {
        return inlineMarkdown(in: line, baseAttributes: baseAttributes, profile: profile)
    }
    let output = NSMutableAttributedString()
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let pointSize = CGFloat(profile.fontSize)
    let baseFont = (baseAttributes[.font] as? NSFont) ?? .systemFont(ofSize: pointSize)
    for segment in segments {
        switch segment.kind {
        case .text:
            // Unescape \$ for display, then run normal inline markdown.
            let unescaped = segment.value.replacingOccurrences(of: "\\$", with: "$")
            output.append(inlineMarkdown(in: unescaped, baseAttributes: baseAttributes, profile: profile))
        case .math:
            let outcome = mathProvider.outcome(latex: segment.value, style: .inline,
                foreground: theme.textColor, pointSize: pointSize, scale: scale)
            if case .image(let image) = outcome {
                image.accessibilityDescription = "Math. \(segment.value)"
                let attachment = NSTextAttachment()
                attachment.image = image
                let size = image.size
                // Center the equation on the font's math axis (~ x-height/2 above baseline).
                let yOffset = baseFont.xHeight / 2 - size.height / 2
                attachment.bounds = CGRect(x: 0, y: yOffset, width: size.width, height: size.height)
                output.append(NSAttributedString(attachment: attachment))
            } else {
                // Fallback: show the raw LaTeX in inline-code style.
                var codeAttrs = baseAttributes
                codeAttrs[.font] = NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
                output.append(NSAttributedString(string: segment.value, attributes: codeAttrs))
            }
        }
    }
    return output
}
```

  Note the baseline offset (`xHeight/2 - height/2`) is the initial approximation; adjust empirically in Task 7 verification if equations sit visibly high/low. The test only asserts it is negative (image taller than x-height ⇒ negative), which holds for any real equation.

- [ ] **Step 4: Run to verify pass.**
  Run: `xcodebuild test … -only-testing:LineformTests/MarkdownPreviewRendererTests -parallel-testing-enabled NO`
  Expected: PASS.

- [ ] **Step 5: Commit.**
  ```bash
  git add Lineform/Preview/MarkdownPreviewRenderer.swift LineformTests/MarkdownPreviewRendererTests.swift
  git commit -m "Math: render inline \$…\$ as baseline-aligned attachment + tests"
  ```

---

## Task 6: Wire the real provider into the preview view

**Files:**
- Modify: `Lineform/Preview/MarkdownPreviewViewRepresentable.swift:38,79-88`

**Interfaces:**
- Consumes: `MathImageProvider`, the `mathProvider:` parameter on `render(...)`.

- [ ] **Step 1: Add the provider property.** After `private let mermaidProvider = MermaidImageProvider()` (line 38) add:
  ```swift
  private let mathProvider = MathImageProvider()
  ```

- [ ] **Step 2: Pass it into `render(...)`.** In the `render(` call (lines 79–88), add `mathProvider: mathProvider,` alongside `mermaidProvider: mermaidProvider,`.

- [ ] **Step 3: Build.**
  Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -quiet`
  Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit.**
  ```bash
  git add Lineform/Preview/MarkdownPreviewViewRepresentable.swift
  git commit -m "Math: wire MathImageProvider into the preview text view"
  ```

---

## Task 7: Writing Tools protection over math regions

**Files:**
- Modify: `Lineform/Editor/MarkdownWritingToolsProtection.swift`
- Create/Modify: `LineformTests/MarkdownWritingToolsProtectionTests.swift`

**Interfaces:**
- Consumes: nothing new (self-contained range scan).
- Produces: `protectedRanges(in:)` also returns inline `$…$` and block `$$…$$` ranges.

- [ ] **Step 1: Write failing tests.** In `MarkdownWritingToolsProtectionTests.swift`:

```swift
import XCTest
@testable import Lineform

final class MarkdownWritingToolsProtectionMathTests: XCTestCase {
    private func protects(_ text: String, substring: String) -> Bool {
        let full = NSRange(location: 0, length: (text as NSString).length)
        let ranges = MarkdownWritingToolsProtection.ignoredRanges(in: text, enclosingRange: full)
        let target = (text as NSString).range(of: substring)
        return ranges.contains { NSIntersectionRange($0, target).length == target.length }
    }
    func testInlineMathIsProtected() {
        XCTAssertTrue(protects("the value $x^2$ here", substring: "$x^2$"))
    }
    func testBlockMathIsProtected() {
        XCTAssertTrue(protects("intro\n$$\nx^2\n$$\nend", substring: "$$\nx^2\n$$"))
    }
    func testProseDollarsAreNotProtected() {
        XCTAssertFalse(protects("it costs $5 to $10", substring: "$5 to $10"))
    }
}
```

- [ ] **Step 2: Run to verify failure.**
  Run: `xcodebuild test … -only-testing:LineformTests/MarkdownWritingToolsProtectionMathTests -parallel-testing-enabled NO`
  Expected: FAIL.

- [ ] **Step 3: Add math ranges** to `protectedRanges(in:)`. Add `ranges.append(contentsOf: mathRanges(in: text))` and implement `mathRanges` using `MathDelimiters`/`MathBlockFence` to compute NSRanges over the full text: for each line, find inline-math segment ranges (map segment offsets back to absolute `NSRange`), and accumulate block `$$…$$` spans (open `$$` line through the closing `$$` line). Reuse the line/offset walk pattern from `fencedCodeRanges`. Keep it structure-preserving — protect the delimiters + inner LaTeX.

- [ ] **Step 4: Run to verify pass.**
  Run: `xcodebuild test … -only-testing:LineformTests/MarkdownWritingToolsProtectionMathTests -parallel-testing-enabled NO`
  Expected: PASS.

- [ ] **Step 5: Commit.**
  ```bash
  git add Lineform/Editor/MarkdownWritingToolsProtection.swift LineformTests/MarkdownWritingToolsProtectionTests.swift
  git commit -m "Math: protect \$ math regions from Writing Tools like fenced code"
  ```

---

## Task 8: Full gate, visual verification, and docs

**Files:**
- Modify (only if needed): `CLAUDE.md`, `README.md`, a help doc under `Lineform/Resources/`.

- [ ] **Step 1: Quit Xcode, run the full suite serially.**
  Run:
  ```sh
  xcodebuild test -project Lineform.xcodeproj -scheme Lineform \
    -destination 'platform=macOS' -parallel-testing-enabled NO
  ```
  Expected: all tests pass. Read the exact pass/fail counts.

- [ ] **Step 2: Visual check (the baseline-offset tuning gate).** Build+run the app (or use the `run` skill), open a document containing:
  ```
  Inline $E = mc^2$ mid-sentence, and $\frac{a}{b}$ too.

  $$
  \int_0^1 x^2\,dx = \tfrac{1}{3}
  $$

  Prose: it costs $5 to $10 (must NOT render).
  ```
  Confirm in Read + Preview: inline equations sit on the baseline (adjust the `xHeight/2 - height/2` offset in Task 5 if they float high/low), the block equation is centered, prose dollars are literal, and Write mode shows raw source. Re-run Step 1 if the offset was changed.

- [ ] **Step 3: Update docs (only what changed).**
  - `CLAUDE.md` "Main Features": add a math-rendering bullet paralleling the Mermaid bullet (`$…$`/`$$…$$` render in Read/Preview via SwiftMath behind `MathImageProvider`, raster+fallback, VoiceOver reads source).
  - `README.md`: add math to the feature list **only if** Mermaid is listed there.
  - Add a brief "Math" section to the user-facing help doc **only if** one lists comparable features (Mermaid). Include the `$`/`$$` syntax and the VoiceOver-reads-source caveat. Do not add a doc just to add one.

- [ ] **Step 4: Final commit.**
  ```bash
  git add -A
  git commit -m "Math: docs for \$…\$ / \$\$…\$\$ LaTeX rendering"
  ```

---

## Self-Review Notes

- **Spec coverage:** dependency+license (T1), delimiter rules (T2), provider seam/cache/size-guard/fallback (T3), block math (T4), inline math + baseline (T5), reading-profile/theme wiring (T3 params + T4/T5 call sites + T6), Writing Tools protection (T7), accessibility alt-text (T4/T5), docs+FontLicenseReview (T1/T8). MathML/`\(\)`/equation-editor are spec non-goals — intentionally absent.
- **Type consistency:** `MathImageProviding.outcome(latex:style:foreground:pointSize:scale:)`, `MathRenderOutcome`, `MathStyle{.inline,.display}`, `MathDelimiters.segments(in:)→[MathInlineSegment]`, `MathBlockFence.blockDelimiterOnly/singleLineBlock` are used identically across T3–T7.
- **Known API risk (flagged in T3):** SwiftMath symbol spellings (`MTMathUILabel`, `MTEdgeInsets` vs `NSEdgeInsets`, `.error`, `.displayErrorInline`, view→bitmap path) must be confirmed against the resolved checkout; the plan notes the fallback rendering path if `cacheDisplay` yields blank.
