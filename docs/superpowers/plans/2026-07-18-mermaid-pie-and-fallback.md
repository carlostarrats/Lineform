# Mermaid Pie + Clean Fallback Implementation Plan

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make unsupported Mermaid types fall back cleanly (instead of mis-rendering as flowcharts) and render Mermaid `pie` charts natively.

**Architecture:** A pure type-classifier gates the existing `MermaidImageProvider` seam: unsupported types short-circuit to the clean captioned-source fallback; `pie` is parsed and drawn natively with Core Graphics, reusing the existing cache/palette/attachment pipeline. No new dependency, no WebView.

**Tech Stack:** Swift, AppKit/Core Graphics, XCTest. Existing `BeautifulMermaid` (pinned 1.0.4) is untouched.

## Global Constraints

- Native only — NO WebView, JavaScript, Vega-Lite, or new remote dependency.
- Pie must use the two-color mono theme contract already passed to the provider (`background`, `foreground`) — no new hues.
- All new tests are pure/deterministic and live in the **default** test plan (`Lineform.xctestplan`). No hosted tests.
- New files must be registered in `Lineform.xcodeproj/project.pbxproj` by hand (objectVersion 56, no synced groups): app sources use ID group `1F000016`, test files `1F000017`/`1F000018` (build-file id `…0001`, file-ref id `…0002` per group).
- Verification command (default gate):
  ```sh
  xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO
  ```
- The classifier's supported-prefix list is coupled to the pinned BeautifulMermaid version — comment it at the source and reference the version.

---

### Task 1: Mermaid type classifier (Part 1 core)

**Files:**
- Modify: `Lineform/Preview/MermaidRendering.swift` (add `MermaidDiagramKind` + `MermaidTypeClassifier`)
- Test: `LineformTests/MermaidTypeClassifierTests.swift` (create)
- Modify: `Lineform.xcodeproj/project.pbxproj` (register the test file, group `1F000017`)

**Interfaces:**
- Produces: `enum MermaidDiagramKind { case supported, pie, unsupported }` and
  `enum MermaidTypeClassifier { static func classify(_ source: String) -> MermaidDiagramKind }`

- [ ] **Step 1: Write the failing test** — `LineformTests/MermaidTypeClassifierTests.swift`:

```swift
import XCTest
@testable import Lineform

final class MermaidTypeClassifierTests: XCTestCase {
    func testSupportedTypes() {
        for src in ["flowchart TD\n A-->B", "graph LR\n A-->B", "stateDiagram-v2\n [*]-->S",
                    "sequenceDiagram\n A->>B: hi", "classDiagram\n class A",
                    "erDiagram\n A ||--o{ B : has", "xychart-beta\n bar [1,2,3]"] {
            XCTAssertEqual(MermaidTypeClassifier.classify(src), .supported, "\(src)")
        }
    }

    func testPieType() {
        for src in ["pie\n \"A\" : 1", "pie showData\n \"A\" : 1", "pie title Fruit\n \"A\" : 1"] {
            XCTAssertEqual(MermaidTypeClassifier.classify(src), .pie, "\(src)")
        }
    }

    func testUnsupportedTypes() {
        for src in ["gantt\n title X", "mindmap\n root", "timeline\n 2024",
                    "journey\n title X", "quadrantChart\n title X", "sankey-beta\n a,b,1",
                    "totally unknown thing"] {
            XCTAssertEqual(MermaidTypeClassifier.classify(src), .unsupported, "\(src)")
        }
    }

    func testSkipsCommentsAndFrontMatter() {
        XCTAssertEqual(MermaidTypeClassifier.classify("%% a comment\nflowchart TD\n A-->B"), .supported)
        XCTAssertEqual(MermaidTypeClassifier.classify("---\ntitle: T\n---\npie\n \"A\" : 1"), .pie)
        XCTAssertEqual(MermaidTypeClassifier.classify("\n\n   \nPIE showData\n \"A\":1"), .pie)
    }
}
```

- [ ] **Step 2: Register the test file in pbxproj.** In `Lineform.xcodeproj/project.pbxproj`, mirror the four entries used by `MermaidRenderingTests.swift` (PBXBuildFile, PBXFileReference, the LineformTests group children, the test target's Sources build phase), using build-file id `1F0000170000000000000001` and file-ref id `1F0000170000000000000002`:

```
# PBXBuildFile section (near line ~38):
		1F0000170000000000000001 /* MermaidTypeClassifierTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1F0000170000000000000002 /* MermaidTypeClassifierTests.swift */; };
# PBXFileReference section (near line ~192):
		1F0000170000000000000002 /* MermaidTypeClassifierTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MermaidTypeClassifierTests.swift; sourceTree = "<group>"; };
# LineformTests group children (near line ~516):
				1F0000170000000000000002 /* MermaidTypeClassifierTests.swift */,
# LineformTests Sources build phase (near line ~824):
				1F0000170000000000000001 /* MermaidTypeClassifierTests.swift in Sources */,
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MermaidTypeClassifierTests`
Expected: FAIL — `MermaidTypeClassifier` / `MermaidDiagramKind` not found.

- [ ] **Step 4: Implement** — append to `Lineform/Preview/MermaidRendering.swift`:

```swift
/// Which renderer, if any, handles a mermaid block.
enum MermaidDiagramKind: Equatable {
    case supported     // BeautifulMermaid renders it
    case pie           // Lineform renders it natively (MermaidPieChart)
    case unsupported   // recognized-but-unrenderable → clean captioned fallback
}

/// Classifies a mermaid block by its declared type WITHOUT invoking BeautifulMermaid.
///
/// BeautifulMermaid 1.0.4's `Parser.parse` matches a fixed prefix set and DEFAULTS everything
/// else to flowchart, so an unsupported type (pie/gantt/mindmap/…) is silently mis-drawn as a
/// garbage flowchart instead of degrading to our clean fallback. This mirrors that parser's
/// supported prefixes exactly. If the BeautifulMermaid pin is bumped, re-check its parser and
/// update this list (same discipline as the orientation-flip note above).
enum MermaidTypeClassifier {
    /// Prefixes BeautifulMermaid 1.0.4 actually renders (lowercased, matched on the first line).
    private static let supportedPrefixes = [
        "sequencediagram", "classdiagram", "erdiagram", "xychart", "statediagram",
        "flowchart", "graph"
    ]

    static func classify(_ source: String) -> MermaidDiagramKind {
        guard let first = firstSignificantLine(source) else { return .unsupported }
        let lower = first.lowercased()
        if lower.hasPrefix("pie") { return .pie }
        if supportedPrefixes.contains(where: { lower.hasPrefix($0) }) { return .supported }
        return .unsupported
    }

    /// First line that isn't blank, a `%%` comment, or inside a leading `---`/`---` front-matter block.
    private static func firstSignificantLine(_ source: String) -> String? {
        var inFrontMatter = false
        var seenFirstLine = false
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { seenFirstLine = true; continue }
            if !seenFirstLine, line == "---" { inFrontMatter = true; seenFirstLine = true; continue }
            seenFirstLine = true
            if inFrontMatter {
                if line == "---" { inFrontMatter = false }
                continue
            }
            if line.hasPrefix("%%") { continue }
            return line
        }
        return nil
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/MermaidTypeClassifierTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Lineform/Preview/MermaidRendering.swift LineformTests/MermaidTypeClassifierTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add MermaidTypeClassifier (Part 1 core)"
```

---

### Task 2: Route unsupported types to the clean fallback (Part 1 wiring)

**Files:**
- Modify: `Lineform/Preview/MermaidRendering.swift` (`MermaidRenderOutcome`, `MermaidImageProvider.outcome`)
- Modify: `Lineform/Preview/MarkdownPreviewRenderer.swift` (`appendMermaidBlock` switch)
- Test: `LineformTests/MermaidRenderingTests.swift` (add cases — already registered)

**Interfaces:**
- Consumes: `MermaidTypeClassifier.classify` (Task 1)
- Produces: `MermaidRenderOutcome.unsupported(String)`; provider returns it for unsupported types; renderer emits captioned fallback with no report link / no log for it.

- [ ] **Step 1: Write the failing test** — add to `LineformTests/MermaidRenderingTests.swift`:

```swift
func testProviderReturnsUnsupportedForGanttWithoutCallingLibrary() {
    let provider = MermaidImageProvider()
    let outcome = provider.outcome(source: "gantt\n title Project\n section A\n Task :a1, 2024-01-01, 30d",
                                   background: .white, foreground: .black, scale: 2)
    guard case .unsupported = outcome else { return XCTFail("expected .unsupported, got \(outcome)") }
}

func testProviderStillAttemptsSupportedType() {
    let provider = MermaidImageProvider()
    let outcome = provider.outcome(source: "flowchart TD\n A-->B",
                                   background: .white, foreground: .black, scale: 2)
    // Supported types route to BeautifulMermaid: image or a genuine failure, never .unsupported.
    if case .unsupported = outcome { XCTFail("supported type must not be .unsupported") }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:LineformTests/MermaidRenderingTests/testProviderReturnsUnsupportedForGanttWithoutCallingLibrary`
Expected: FAIL — `.unsupported` case does not exist (compile error).

- [ ] **Step 3: Add the outcome case** — in `MermaidRendering.swift`, extend `MermaidRenderOutcome`:

```swift
enum MermaidRenderOutcome {
    case image(NSImage)
    case skipped               // size guard tripped
    case unsupported(String)   // recognized-but-unrenderable type (e.g. "gantt"); clean fallback, no report/log
    case failed(String)        // render threw or produced no image
}
```

- [ ] **Step 4: Gate the provider** — in `MermaidImageProvider.outcome`, immediately after the `MermaidBlockPolicy.shouldAttemptRender` guard and BEFORE computing the cache key, add:

```swift
switch MermaidTypeClassifier.classify(source) {
case .unsupported:
    return .unsupported(MermaidTypeClassifier.classify(source) == .unsupported ? "unsupported" : "")
case .pie, .supported:
    break   // pie handled in Task 5; supported falls through to the existing path
}
```

Replace the throwaway string above with a clean type label — simplest correct form:

```swift
if MermaidTypeClassifier.classify(source) == .unsupported {
    return .unsupported("unsupported mermaid type")
}
```

(Task 5 inserts the `.pie` branch here; for now only `.unsupported` is handled and `.supported`/`.pie` fall through to the existing BeautifulMermaid path — a `pie` will still mis-render until Task 5, which is fine because Tasks 3–5 land before release.)

- [ ] **Step 5: Handle the case in the renderer** — in `MarkdownPreviewRenderer.appendMermaidBlock`, add an arm to the `switch outcome` alongside `.skipped`:

```swift
case .unsupported:
    // Recognized-but-unrenderable mermaid type: clean fallback, not a bug — no log, no report.
    appendMermaidFallback(source: source, to: output, profile: profile, codeAttributes: codeAttributes, reportHash: nil)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test ... -only-testing:LineformTests/MermaidRenderingTests`
Expected: PASS (existing + 2 new).

- [ ] **Step 7: Commit**

```bash
git add Lineform/Preview/MermaidRendering.swift Lineform/Preview/MarkdownPreviewRenderer.swift LineformTests/MermaidRenderingTests.swift
git commit -m "Route unsupported mermaid types to clean fallback (Part 1 wiring)"
```

---

### Task 3: Pie parsing (Part 2 — pure model)

**Files:**
- Create: `Lineform/Preview/MermaidPieChart.swift`
- Test: `LineformTests/MermaidPieChartTests.swift` (create)
- Modify: `Lineform.xcodeproj/project.pbxproj` (register app source group `1F000016`, test group `1F000018`)

**Interfaces:**
- Produces:
  - `struct MermaidPieSlice { let label: String; let value: Double }`
  - `struct MermaidPieModel { let title: String?; let slices: [MermaidPieSlice]; var total: Double; func fraction(of:) -> Double }`
  - `enum MermaidPieChart { static func parse(_ source: String) -> MermaidPieModel? }`

- [ ] **Step 1: Write the failing test** — `LineformTests/MermaidPieChartTests.swift`:

```swift
import XCTest
@testable import Lineform

final class MermaidPieChartTests: XCTestCase {
    func testParsesLabelsValuesTitle() {
        let model = MermaidPieChart.parse("pie title Fruit\n \"Apples\" : 30\n \"Pears\" : 10")
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.title, "Fruit")
        XCTAssertEqual(model?.slices.count, 2)
        XCTAssertEqual(model?.slices.first?.label, "Apples")
        XCTAssertEqual(model?.slices.first?.value, 30)
        XCTAssertEqual(model?.total, 40)
        XCTAssertEqual(model?.fraction(of: model!.slices[0]) ?? 0, 0.75, accuracy: 0.0001)
    }

    func testShowDataAndDecimalsAndWhitespace() {
        let model = MermaidPieChart.parse("pie showData\n  \"A\"  :  12.5 \n\"B\":37.5")
        XCTAssertNil(model?.title)
        XCTAssertEqual(model?.slices.count, 2)
        XCTAssertEqual(model?.slices[0].value ?? 0, 12.5, accuracy: 0.0001)
        XCTAssertEqual(model?.total ?? 0, 50, accuracy: 0.0001)
    }

    func testSkipsCommentsAndFrontMatter() {
        let model = MermaidPieChart.parse("---\ntitle: ignore\n---\npie\n%% note\n \"A\" : 1\n \"B\" : 1")
        XCTAssertEqual(model?.slices.count, 2)
    }

    func testRejectsInvalid() {
        XCTAssertNil(MermaidPieChart.parse("pie title Empty"))            // no slices
        XCTAssertNil(MermaidPieChart.parse("pie\n \"A\" : -5"))           // negative
        XCTAssertNil(MermaidPieChart.parse("pie\n \"A\" : 0\n \"B\" : 0")) // zero total
        XCTAssertNil(MermaidPieChart.parse("pie\n \"A\" : notanumber"))   // non-numeric
        XCTAssertNil(MermaidPieChart.parse("flowchart TD\n A-->B"))       // not a pie
    }
}
```

- [ ] **Step 2: Register both files in pbxproj.** Add `MermaidPieChart.swift` to the app target (group `1F000016`, build-file `…0001`, file-ref `…0002`) mirroring `MermaidRendering.swift`'s four entries but in the **Lineform** (app) group + app Sources phase; add `MermaidPieChartTests.swift` to the test target (group `1F000018`) mirroring Task 1's registration:

```
# PBXBuildFile:
		1F0000160000000000000001 /* MermaidPieChart.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1F0000160000000000000002 /* MermaidPieChart.swift */; };
		1F0000180000000000000001 /* MermaidPieChartTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1F0000180000000000000002 /* MermaidPieChartTests.swift */; };
# PBXFileReference:
		1F0000160000000000000002 /* MermaidPieChart.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MermaidPieChart.swift; sourceTree = "<group>"; };
		1F0000180000000000000002 /* MermaidPieChartTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MermaidPieChartTests.swift; sourceTree = "<group>"; };
# Preview group children (same group that lists MermaidRendering.swift):
				1F0000160000000000000002 /* MermaidPieChart.swift */,
# LineformTests group children:
				1F0000180000000000000002 /* MermaidPieChartTests.swift */,
# App Sources build phase (same phase that lists MermaidRendering.swift in Sources):
				1F0000160000000000000001 /* MermaidPieChart.swift in Sources */,
# LineformTests Sources build phase:
				1F0000180000000000000001 /* MermaidPieChartTests.swift in Sources */,
```

- [ ] **Step 3: Run to verify failure**

Run: `xcodebuild test ... -only-testing:LineformTests/MermaidPieChartTests`
Expected: FAIL — `MermaidPieChart` not found.

- [ ] **Step 4: Implement parsing** — `Lineform/Preview/MermaidPieChart.swift`:

```swift
import Foundation

/// One slice of a mermaid `pie` chart. `value` is always > 0 (parser rejects otherwise).
struct MermaidPieSlice: Equatable {
    let label: String
    let value: Double
}

/// Parsed mermaid `pie` chart. Always has >= 1 slice and a positive total.
struct MermaidPieModel: Equatable {
    let title: String?
    let slices: [MermaidPieSlice]

    var total: Double { slices.reduce(0) { $0 + $1.value } }

    /// This slice's share of the whole (0...1).
    func fraction(of slice: MermaidPieSlice) -> Double {
        total > 0 ? slice.value / total : 0
    }
}

/// Parses mermaid `pie` syntax into a drawable model. Pure; no rendering.
enum MermaidPieChart {
    /// Returns nil for anything unrenderable (not a pie, no slices, or any non-positive /
    /// non-numeric value) so the caller degrades to the clean captioned fallback.
    static func parse(_ source: String) -> MermaidPieModel? {
        var lines = significantLines(source)
        guard let header = lines.first, header.lowercased().hasPrefix("pie") else { return nil }
        lines.removeFirst()

        let title = parseTitle(fromHeader: header)

        var slices: [MermaidPieSlice] = []
        for line in lines {
            guard let slice = parseSlice(line) else { return nil }  // any malformed data line → whole block fails
            slices.append(slice)
        }
        guard !slices.isEmpty, slices.allSatisfy({ $0.value > 0 }) else { return nil }
        return MermaidPieModel(title: title, slices: slices)
    }

    /// `pie [showData] [title <text>]` → the title text, or nil.
    private static func parseTitle(fromHeader header: String) -> String? {
        // Strip a leading "pie" and an optional "showData", then look for "title <rest>".
        var rest = header
        rest = String(rest.dropFirst(3))                                  // drop "pie"
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.lowercased().hasPrefix("showdata") {
            rest = String(rest.dropFirst("showdata".count)).trimmingCharacters(in: .whitespaces)
        }
        if rest.lowercased().hasPrefix("title") {
            let t = String(rest.dropFirst("title".count)).trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    /// `"label" : value` → a slice, or nil if the line isn't a valid data line.
    private static func parseSlice(_ line: String) -> MermaidPieSlice? {
        guard line.first == "\"" else { return nil }
        let afterOpen = line.dropFirst()
        guard let closeQuote = afterOpen.firstIndex(of: "\"") else { return nil }
        let label = String(afterOpen[afterOpen.startIndex..<closeQuote])
        var remainder = String(afterOpen[afterOpen.index(after: closeQuote)...])
            .trimmingCharacters(in: .whitespaces)
        guard remainder.first == ":" else { return nil }
        remainder = String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces)
        guard let value = Double(remainder) else { return nil }
        return MermaidPieSlice(label: label, value: value)
    }

    /// Lines with blanks, `%%` comments, and a leading `---`/`---` front-matter block removed.
    private static func significantLines(_ source: String) -> [String] {
        var out: [String] = []
        var inFrontMatter = false
        var seenFirst = false
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { seenFirst = true; continue }
            if !seenFirst, line == "---" { inFrontMatter = true; seenFirst = true; continue }
            seenFirst = true
            if inFrontMatter { if line == "---" { inFrontMatter = false }; continue }
            if line.hasPrefix("%%") { continue }
            out.append(line)
        }
        return out
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test ... -only-testing:LineformTests/MermaidPieChartTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Lineform/Preview/MermaidPieChart.swift LineformTests/MermaidPieChartTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add MermaidPieChart parser (Part 2 model)"
```

---

### Task 4: Pie rendering (Part 2 — draw to NSImage)

**Files:**
- Modify: `Lineform/Preview/MermaidPieChart.swift` (add `MermaidPieRenderer`)
- Test: `LineformTests/MermaidPieChartTests.swift` (add render cases)

**Interfaces:**
- Consumes: `MermaidPieModel` (Task 3)
- Produces: `enum MermaidPieRenderer { static func image(model:background:foreground:scale:) -> NSImage? }`

- [ ] **Step 1: Write the failing test** — add to `MermaidPieChartTests.swift`:

```swift
func testRendersNonEmptyImageLightAndDark() {
    let model = MermaidPieChart.parse("pie title T\n \"A\" : 3\n \"B\" : 1")!
    let light = MermaidPieRenderer.image(model: model, background: .clear, foreground: .black, scale: 2)
    XCTAssertNotNil(light)
    XCTAssertGreaterThan(light?.size.width ?? 0, 0)
    XCTAssertGreaterThan(light?.size.height ?? 0, 0)
    let dark = MermaidPieRenderer.image(model: model, background: .black, foreground: .white, scale: 2)
    XCTAssertNotNil(dark)
    XCTAssertGreaterThan(dark?.size.height ?? 0, 0)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:LineformTests/MermaidPieChartTests/testRendersNonEmptyImageLightAndDark`
Expected: FAIL — `MermaidPieRenderer` not found.

- [ ] **Step 3: Implement the renderer** — append to `Lineform/Preview/MermaidPieChart.swift`:

```swift
import AppKit

/// Draws a `MermaidPieModel` as an upright NSImage: title, pie circle, and a legend.
///
/// Monochrome by design — Lineform's mermaid diagrams use a strict two-color (page + ink) theme,
/// so slices are the `foreground` ink at stepped alpha with a thin `foreground` stroke, matching
/// the calm look of every other diagram. We draw the raster ourselves (top-left origin via a
/// flipped image), so no `uprightForMacOS` flip is required.
enum MermaidPieRenderer {
    static func image(model: MermaidPieModel, background: NSColor,
                      foreground: NSColor, scale: CGFloat) -> NSImage? {
        let pieDiameter: CGFloat = 200
        let padding: CGFloat = 16
        let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let legendFont = NSFont.systemFont(ofSize: 12)
        let rowHeight: CGFloat = 20
        let swatch: CGFloat = 12

        let titleHeight: CGFloat = model.title == nil ? 0 : 24
        let legendHeight = CGFloat(model.slices.count) * rowHeight
        let contentWidth = pieDiameter + 24 + legendMaxWidth(model, font: legendFont, swatch: swatch)
        let width = contentWidth + padding * 2
        let height = titleHeight + max(pieDiameter, legendHeight) + padding * 2

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            if background != .clear {
                ctx.setFillColor(background.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }

            var y = padding
            if let title = model.title {
                drawText(title, at: CGPoint(x: padding, y: y), font: titleFont, color: foreground)
                y += titleHeight
            }

            // Pie circle (flipped context → top-left origin, y grows downward).
            let center = CGPoint(x: padding + pieDiameter / 2, y: y + pieDiameter / 2)
            let radius = pieDiameter / 2
            var startAngle: CGFloat = -.pi / 2   // 12 o'clock
            for (i, slice) in model.slices.enumerated() {
                let sweep = CGFloat(model.fraction(of: slice)) * 2 * .pi
                let end = startAngle + sweep
                let path = CGMutablePath()
                path.move(to: center)
                path.addArc(center: center, radius: radius, startAngle: startAngle,
                            endAngle: end, clockwise: false)
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(foreground.withAlphaComponent(alpha(i, of: model.slices.count)).cgColor)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(foreground.cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()
                startAngle = end
            }

            // Legend.
            var ly = y
            let lx = padding + pieDiameter + 24
            for (i, slice) in model.slices.enumerated() {
                let sr = CGRect(x: lx, y: ly + (rowHeight - swatch) / 2, width: swatch, height: swatch)
                ctx.setFillColor(foreground.withAlphaComponent(alpha(i, of: model.slices.count)).cgColor)
                ctx.fill(sr)
                ctx.setStrokeColor(foreground.cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(sr)
                let pct = Int((model.fraction(of: slice) * 100).rounded())
                let text = "\(slice.label)  \(formatValue(slice.value)) (\(pct)%)"
                drawText(text, at: CGPoint(x: lx + swatch + 8, y: ly + 2), font: legendFont, color: foreground)
                ly += rowHeight
            }
            return true
        }
        return image.size.width > 0 && image.size.height > 0 ? image : nil
    }

    /// Stepped alpha so adjacent slices read distinctly without new hues (0.85 → 0.30).
    private static func alpha(_ index: Int, of count: Int) -> CGFloat {
        guard count > 1 else { return 0.7 }
        let steps: [CGFloat] = [0.85, 0.45, 0.65, 0.30, 0.75, 0.40, 0.55, 0.35]
        return steps[index % steps.count]
    }

    private static func formatValue(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }

    private static func drawText(_ s: String, at p: CGPoint, font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        NSAttributedString(string: s, attributes: attrs).draw(at: p)
    }

    private static func legendMaxWidth(_ model: MermaidPieModel, font: NSFont, swatch: CGFloat) -> CGFloat {
        var maxW: CGFloat = 120
        for slice in model.slices {
            let pct = Int((model.fraction(of: slice) * 100).rounded())
            let text = "\(slice.label)  \(formatValue(slice.value)) (\(pct)%)"
            let w = (text as NSString).size(withAttributes: [.font: font]).width + swatch + 8
            maxW = max(maxW, w)
        }
        return maxW
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test ... -only-testing:LineformTests/MermaidPieChartTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Lineform/Preview/MermaidPieChart.swift LineformTests/MermaidPieChartTests.swift
git commit -m "Draw mermaid pie charts to NSImage (Part 2 renderer)"
```

---

### Task 5: Wire pie into the provider (Part 2 integration)

**Files:**
- Modify: `Lineform/Preview/MermaidRendering.swift` (`MermaidImageProvider.outcome` `.pie` branch)
- Test: `LineformTests/MermaidRenderingTests.swift` (add pie integration case)

**Interfaces:**
- Consumes: `MermaidTypeClassifier.classify`, `MermaidPieChart.parse`, `MermaidPieRenderer.image`

- [ ] **Step 1: Write the failing test** — add to `MermaidRenderingTests.swift`:

```swift
func testProviderRendersPieNatively() {
    let provider = MermaidImageProvider()
    let outcome = provider.outcome(source: "pie title Fruit\n \"Apples\" : 30\n \"Pears\" : 10",
                                   background: .clear, foreground: .black, scale: 2)
    guard case .image(let img) = outcome else { return XCTFail("expected .image, got \(outcome)") }
    XCTAssertGreaterThan(img.size.width, 0)
}

func testProviderFallsBackForMalformedPie() {
    let provider = MermaidImageProvider()
    let outcome = provider.outcome(source: "pie title Empty",
                                   background: .clear, foreground: .black, scale: 2)
    guard case .unsupported = outcome else { return XCTFail("expected .unsupported, got \(outcome)") }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test ... -only-testing:LineformTests/MermaidRenderingTests/testProviderRendersPieNatively`
Expected: FAIL — `.pie` falls through to BeautifulMermaid, returns something other than a valid pie `.image` (garbage flowchart or `.failed`).

- [ ] **Step 3: Implement the `.pie` branch** — in `MermaidImageProvider.outcome`, replace the Task-2 classifier gate with the full three-way form, placed AFTER the cache/failure lookups (so a rendered pie is cached under the same key). Concretely, the method body becomes:

```swift
func outcome(source: String, background: NSColor, foreground: NSColor, scale: CGFloat) -> MermaidRenderOutcome {
    guard MermaidBlockPolicy.shouldAttemptRender(source: source) else { return .skipped }

    let kind = MermaidTypeClassifier.classify(source)
    if kind == .unsupported { return .unsupported("unsupported mermaid type") }

    let key = MermaidCacheKey.key(
        source: source,
        backgroundHex: MermaidHexColor.string(from: background),
        foregroundHex: MermaidHexColor.string(from: foreground),
        scale: scale
    ) as NSString
    if let cached = cache.object(forKey: key) { return .image(cached) }
    if let failure = failureCache.object(forKey: key) { return .failed(failure as String) }

    if kind == .pie {
        guard let model = MermaidPieChart.parse(source) else { return .unsupported("malformed pie") }
        guard let image = MermaidPieRenderer.image(model: model, background: background,
                                                   foreground: foreground, scale: scale) else {
            return .failed("Pie render produced no image")   // transient; not neg-cached
        }
        cache.setObject(image, forKey: key, cost: RasterImageCost.bytes(for: image))
        return .image(image)
    }

    // .supported → BeautifulMermaid (existing do/catch, unchanged).
    do {
        let theme = DiagramTheme(background: background, foreground: foreground)
        if let image = try MermaidRenderer.renderImage(source: source, theme: theme, scale: scale) {
            let upright = MermaidImageOrientation.uprightForMacOS(image)
            cache.setObject(upright, forKey: key, cost: RasterImageCost.bytes(for: upright))
            return .image(upright)
        }
        return .failed("Mermaid render produced no image")
    } catch {
        let message = String(describing: error)
        failureCache.setObject(message as NSString, forKey: key)
        return .failed(message)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test ... -only-testing:LineformTests/MermaidRenderingTests`
Expected: PASS (existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add Lineform/Preview/MermaidRendering.swift LineformTests/MermaidRenderingTests.swift
git commit -m "Render mermaid pie charts natively in the provider (Part 2 integration)"
```

---

### Task 6: Full suite + docs

- [ ] **Step 1: Run the full default test plan**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
Expected: all pass (report exact counts).

- [ ] **Step 2: Update CLAUDE.md** — in the Mermaid rendering bullet, note that `pie` renders natively (mono, legend) and that unsupported types degrade to the captioned fallback rather than mis-rendering. Keep it factual and brief; do not add churn elsewhere.

- [ ] **Step 3: Commit docs**

```bash
git add CLAUDE.md
git commit -m "Docs: mermaid pie support + clean fallback for unsupported types"
```

## Self-Review

- **Spec coverage:** Part 1 classifier (Task 1) + outcome/routing (Task 2); Part 2 parse (Task 3) + render (Task 4) + integration (Task 5); tests all in default plan; docs (Task 6). All spec sections mapped.
- **Placeholders:** none — every step has concrete code/commands.
- **Type consistency:** `MermaidDiagramKind`/`classify` (T1) used in T2/T5; `MermaidPieModel`/`MermaidPieSlice`/`parse` (T3) used in T4/T5; `MermaidPieRenderer.image` (T4) used in T5; `MermaidRenderOutcome.unsupported(String)` (T2) consumed by renderer (T2) and provider (T2/T5). Consistent.
- **Note:** Task 2's interim gate is superseded by Task 5's full three-way body — Task 5 Step 3 shows the final method verbatim to avoid drift.
