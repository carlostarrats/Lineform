# Live Spell Check Implementation Plan

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn on live (as-you-type) spell checking in the Markdown editor, suppressed inside non-prose Markdown regions, with autocorrect turned off and no typing-latency regression.

**Architecture:** A pure, AppKit-free helper (`MarkdownSpellCheckRegions`) computes the sub-ranges of a checked range that are actually prose, by subtracting block regions (fenced code, front matter, math) and inline tokens (`codeSpan`, `linkDestination`, `imageDestination`). `LineformTextView` overrides `checkText(in:types:options:)` and calls `super` once per prose sub-range. Continuous-checking state persists in `LineformSettingsStore` and is driven solely by the standard Edit menu item.

**Tech Stack:** Swift, AppKit (`NSTextView`, `NSSpellChecker`), SwiftUI (settings store only), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-26-live-spell-check-design.md` — read it before Task 1.

## Global Constraints

- **Local only.** Spell checking must route through the system `NSSpellChecker` and nothing else. No bundled dictionary, no third-party checking service, no network-backed suggestions. This sits alongside the existing rule that remote image URLs are never fetched.
- **No typing-latency regression.** Hard gate, verified by measurement, not by inspection. Budget for our own code: `checkableRanges` ≤ 1 ms per call on a 730 KB document. If the gate fails, the feature does not ship in this form — report the numbers and stop.
- **Never call whole-document passes from the checking path.** `MarkdownWritingToolsProtection.ignoredRanges(in:enclosingRange:)` measures 18 ms on 730 KB. `MarkdownRangeAnalyzer.ranges(in:)` has the same shape. Both are banned from the checking path.
- **`MarkdownRangeAnalyzer` must stay strictly line-local.** This is a pre-existing load-bearing invariant (`CLAUDE.md`). Do not add cross-line token state to make this feature easier.
- **Do not force a synchronous re-highlight** from the checking path. `didChangeText` already schedules the debounced one.
- **Do not disturb** the `lastSyncedText` guard in `updateNSView`, or the visual-anchor / deferred-restore machinery in `LineformTextView`.
- **Grammar checking stays off.** Set `isGrammarCheckingEnabled = false` explicitly, not by omission.
- **New source files must be hand-added to `Lineform.xcodeproj/project.pbxproj`** in 4 places each. There are no synced groups (objectVersion 56). Reserved unused IDs for this feature: `0086` (source), `0087` (source tests), `0088` (perf tests). See Task 3 Step 4 for the exact recipe.
- **Test commands** always use `-parallel-testing-enabled NO`.
- **QA builds** are opened with `open -a "$BUILT_PRODUCTS_DIR/Lineform.app" file.md`, never a bare `open`.

---

### Task 1: Resolve the open question and take baseline measurements

**This task writes NO shippable code.** It builds a throwaway instrumented build, answers one question, records three numbers, and then reverts everything. Its deliverable is a written finding that decides the shape of Tasks 3 and 5.

**Why first:** the inline-suppression design depends on which AppKit hook as-you-type checking routes through. Guessing wrong means building the feature twice. And the performance attribution must be taken *before* our code exists, or there is nothing to compare against.

**Files:**
- Modify (temporarily, reverted at the end of this task): `Lineform/Editor/LineformTextView.swift`
- Modify (temporarily, reverted): `Lineform/Editor/MarkdownTextViewRepresentable.swift`
- Create: `docs/notes/2026-07-26-spell-check-probe-findings.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a findings document, and a go/no-go decision for the inline-suppression design. No code.

- [ ] **Step 1: Create the large test fixture**

A 730 KB Markdown document, matching the size in the `ignoredRanges` doc comment so the numbers are comparable. Mixed prose, fenced code, front matter, math, inline code, and links — not one repeated line, or the fence/token walks get unrealistically cheap.

```bash
mkdir -p /tmp/lineform-spellcheck-qa
python3 - <<'PY'
import random
random.seed(7)
words = "the quick brown fox jumps over lazy dog writing calm native markdown editor document".split()
typos = ["teh", "recieve", "seperate", "occured"]
out = ["---", "title: Large Fixture", "author: QA", "---", ""]
i = 0
while sum(len(s) + 1 for s in out) < 730 * 1024:
    i += 1
    kind = i % 12
    if kind == 0:
        out += ["```swift", "let isRichText = false  // recieve seperate", "func doThing() {}", "```", ""]
    elif kind == 5:
        out += ["$$", r"\sum_{i=0}^{n} x_i = \frac{a}{b}", "$$", ""]
    elif kind == 7:
        out += [f"See [the docs]({'/Users/qa/notes/somefile-%d.md' % i}) and `NSTextView` for detail.", ""]
    elif kind == 9:
        out += [f"## Section {i}", ""]
    else:
        line = " ".join(random.choice(words) for _ in range(18))
        if i % 4 == 0:
            line += " " + random.choice(typos)
        out += [line, ""]
open("/tmp/lineform-spellcheck-qa/large.md", "w").write("\n".join(out))
PY
ls -l /tmp/lineform-spellcheck-qa/large.md
```

Expected: a file of roughly 730 KB.

- [ ] **Step 2: Add temporary probe logging to both candidate hooks**

In `LineformTextView.swift`, inside the class, add:

```swift
    // TEMPORARY PROBE — Task 1 only. Reverted in Step 7. Do not commit.
    override func checkText(
        in range: NSRange,
        types checkingTypes: NSTextCheckingTypes,
        options: [NSAttributedString.TextCheckingOptionKey: Any]
    ) {
        NSLog("[PROBE] checkText range=%@ types=%llu", NSStringFromRange(range), UInt64(checkingTypes))
        super.checkText(in: range, types: checkingTypes, options: options)
    }
```

In `MarkdownTextViewRepresentable.swift`, inside `final class Coordinator`, add:

```swift
    // TEMPORARY PROBE — Task 1 only. Reverted in Step 7. Do not commit.
    func textView(
        _ view: NSTextView,
        shouldCheckTextIn range: NSRange,
        options: [NSAttributedString.TextCheckingOptionKey: Any],
        types checkingTypes: UnsafeMutablePointer<NSTextCheckingTypes>
    ) -> [NSAttributedString.TextCheckingOptionKey: Any] {
        NSLog("[PROBE] shouldCheckTextIn range=%@ types=%llu", NSStringFromRange(range), UInt64(checkingTypes.pointee))
        return options
    }
```

And in `configureForMarkdownEditing()` in `LineformTextView.swift`, temporarily add below the existing substitution lines:

```swift
        isContinuousSpellCheckingEnabled = true   // TEMPORARY PROBE — Task 1 only
```

- [ ] **Step 3: Build and run the probe**

```bash
xcodebuild -project Lineform.xcodeproj -scheme Lineform -configuration Debug build 2>&1 | tail -5
```

Then launch the fresh build explicitly by full path — never `open -a Lineform`, which picks an installed copy:

```bash
BUILT=$(xcodebuild -project Lineform.xcodeproj -scheme Lineform -configuration Debug \
  -showBuildSettings 2>/dev/null | awk -F'= ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
killall Lineform 2>/dev/null; sleep 1
open -a "$BUILT/Lineform.app" /tmp/lineform-spellcheck-qa/large.md
```

**This step needs the user.** GUI typing cannot be automated on this machine (System Events is unauthorized). Ask the user to type `teh` into the document in a prose paragraph, then read the log:

```bash
log show --predicate 'eventMessage CONTAINS "[PROBE]"' --last 3m --style compact | tail -40
```

- [ ] **Step 4: Record which hook fired, and with what ranges**

The decision:

- **`checkText` fires with sub-paragraph ranges** → the design in the spec works as written. Tasks 4 and 6 proceed unchanged.
- **Only `shouldCheckTextIn` fires** → inline suppression via range-splitting is impossible. **STOP and report to the user.** Block-level suppression (code fences, front matter, math) still works via the delegate; the inline part (`inline code`, link URLs) becomes a product decision. Do not silently drop it, and do not adopt the temporary-attribute-stripping approach — it was explicitly rejected in the spec.
- **Both fire** → prefer `checkText`; note the delegate's ranges for reference.

- [ ] **Step 5: Measure configurations A and B**

There is no committed profiling harness in this repo — the earlier large-document typing
investigation used an ad-hoc one. Build the minimal version below as part of this task; it is
temporary and reverted in Step 7 along with the probes.

Add to `LineformTextView.swift`, inside the class:

```swift
    // TEMPORARY INSTRUMENTATION — Task 1 only. Reverted in Step 7. Do not commit.
    private static let latencyLog: FileHandle? = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lineform-typing-latency.csv")
        FileManager.default.createFile(atPath: url.path, contents: Data("elapsed_ms\n".utf8))
        NSLog("[PROBE] latency CSV: %@", url.path)
        return try? FileHandle(forWritingTo: url)
    }()

    override func didChangeText() {
        let start = CFAbsoluteTimeGetCurrent()
        super.didChangeText()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        Self.latencyLog?.write(Data(String(format: "%.4f\n", elapsed).utf8))
    }
```

`FileManager.default.temporaryDirectory` resolves inside the app's sandbox container, so the
path must be read from the `[PROBE]` log line rather than assumed.

**The typing itself needs the user** — System Events is unauthorized on this machine, so
keystrokes cannot be synthesized. Ask them to place the caret in the MIDDLE of
`large.md` (the worst case for the prefix walk, and the case a caret at the top would hide) and
type continuously for about thirty seconds.

Then summarize:

```bash
CSV=$(log show --predicate 'eventMessage CONTAINS "latency CSV"' --last 10m --style compact \
  | tail -1 | sed 's/.*: //')
python3 -c "
import sys
v = sorted(float(x) for x in open('$CSV').readlines()[1:] if x.strip())
print(f'n={len(v)} median={v[len(v)//2]:.3f}ms p99={v[int(len(v)*0.99)]:.3f}ms max={v[-1]:.3f}ms')
"
```

Record `n`, median, p99, and max for each configuration. Discard any run with `n < 200` — too
few samples for a meaningful p99.

- **A** — `isContinuousSpellCheckingEnabled` left at its default `false` (comment out the probe line from Step 2): today's behavior, the baseline.
- **B** — `isContinuousSpellCheckingEnabled = true`, no suppression: Apple's checker cost.

Record median and p99 keystroke latency for each.

- [ ] **Step 6: Write the findings document**

Create `docs/notes/2026-07-26-spell-check-probe-findings.md` recording: which hook fires and with what range granularity; the A and B latency numbers; and the go/no-go call for inline suppression. Include the raw log excerpt. State honestly if any measurement was not taken.

**If B is dramatically worse than A**, that is Apple's checker, not our code — no implementation change can fix it. Report it to the user as a product question (likely answer: a document-size threshold above which continuous checking stays off) rather than optimizing around it.

- [ ] **Step 7: Revert every temporary change**

```bash
git checkout -- Lineform/Editor/LineformTextView.swift Lineform/Editor/MarkdownTextViewRepresentable.swift
git status --short
```

Expected: only the new findings doc is untracked. **Verify no `[PROBE]` string survives:**

```bash
grep -rn "PROBE" Lineform/ || echo "clean"
```

- [ ] **Step 8: Report to the user before continuing**

Summarize the finding and the three numbers in plain language. If the finding is anything other than "all clear," stop here and wait.

---

### Task 2: Scoped block-region detection

**Files:**
- Modify: `Lineform/Editor/MarkdownWritingToolsProtection.swift`
- Test: `LineformTests/MarkdownWritingToolsProtectionTests.swift` (existing file — add to it)

**Interfaces:**
- Consumes: nothing new.
- Produces: `MarkdownWritingToolsProtection.protectedRanges(in text: NSString, intersecting scope: NSRange) -> [NSRange]` — block-level protected ranges (front matter, fenced code, math) that intersect `scope`, clipped to `scope`. Used by Task 3.

**Why this exists:** the existing `ignoredRanges(in:enclosingRange:)` computes every protected region in the whole document (18 ms at 730 KB) and then intersects. The checking path needs the intersection without the whole-document cost. Fence, front-matter, and `$$`-block state genuinely depend on the document prefix, so a prefix walk is unavoidable — but the expensive per-line inline-math regex must run only on lines that intersect `scope`.

- [ ] **Step 1: Write the failing tests**

Add to `LineformTests/MarkdownWritingToolsProtectionTests.swift`:

```swift
    // MARK: - Scoped block regions (live spell check)

    func testScopedProtectedRangesFindsFenceOpenedBeforeScope() {
        let text = "```swift\nlet a = 1\nlet b = 2\n```\nprose here\n" as NSString
        let scopeStart = text.range(of: "let b").location
        let scope = NSRange(location: scopeStart, length: 5)
        let ranges = MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: scope)
        XCTAssertEqual(ranges, [scope], "a fence opened before the scope must still protect inside it")
    }

    func testScopedProtectedRangesExcludesProseOutsideFence() {
        let text = "```\ncode\n```\nprose here\n" as NSString
        let proseStart = text.range(of: "prose").location
        let scope = NSRange(location: proseStart, length: 5)
        let ranges = MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: scope)
        XCTAssertTrue(ranges.isEmpty, "prose after a closed fence is not protected")
    }

    func testScopedProtectedRangesCoversFrontMatter() {
        let text = "---\ntitle: teh\n---\nprose\n" as NSString
        let scope = text.range(of: "title: teh")
        let ranges = MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: scope)
        XCTAssertEqual(ranges, [scope])
    }

    func testScopedProtectedRangesCoversDisplayMathOpenedBeforeScope() {
        let text = "prose\n$$\nx = y\n$$\nmore\n" as NSString
        let scope = text.range(of: "x = y")
        let ranges = MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: scope)
        XCTAssertEqual(ranges, [scope])
    }

    /// The equivalence that makes the scoped path safe to substitute for the whole-document one.
    func testScopedProtectedRangesMatchesWholeDocumentIntersection() {
        let text = """
        ---
        title: Doc
        ---
        prose one $x+y$ tail
        ```swift
        let a = 1
        ```
        prose two
        $$
        a = b
        $$
        prose three
        """ as NSString
        let full = NSRange(location: 0, length: text.length)

        var scope = NSRange(location: 0, length: 0)
        while scope.location < text.length {
            scope = text.lineRange(for: NSRange(location: scope.location, length: 0))
            let scoped = MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: scope)
            let expected = MarkdownWritingToolsProtection
                .ignoredRanges(in: text as String, enclosingRange: full)
                .map { NSIntersectionRange($0, scope) }
                .filter { $0.length > 0 }
            XCTAssertEqual(
                normalized(scoped), normalized(expected),
                "scoped result diverged from the whole-document pass at \(NSStringFromRange(scope))"
            )
            scope.location = NSMaxRange(scope)
        }
    }

    /// Merges touching/overlapping ranges so the two paths compare on coverage, not on
    /// how each happened to split it.
    private func normalized(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/MarkdownWritingToolsProtectionTests 2>&1 | tail -20
```

Expected: compile failure — `protectedRanges(in:intersecting:)` does not exist.

- [ ] **Step 3: Implement the scoped variant**

**Do NOT hand-roll a new fence/front-matter/math parser.** The three existing whole-document
passes encode rules that were paid for in regressions — `mathRanges` defers to
`MathBlockFence.blockDelimiterOnly`, `MathBlockFence.singleLineBlock`, and
`MathDelimiters.inlineMathRanges` (`Lineform/Preview/MathRendering.swift`) so prose dollar signs
like "$5" are never protected, and it toggles `inCodeFence` with different logic than
`fencedCodeRanges` uses. A parallel implementation will diverge, and the equivalence test in
Step 1 will (correctly) reject it.

Instead, make this a **bounded refactor** that keeps every per-line predicate byte-identical:

1. **`frontMatterRange(in:)` needs no change.** It is already cheap — a `hasPrefix("---\n")`
   check plus one `range(of: "\n---")` search. Call it as-is.

2. **Give `fencedCodeRanges` and `mathRanges` an `upTo limit: Int?` parameter**, defaulting to
   `nil` (whole document). Change ONLY their iteration, not their bodies:
   - Replace `text.components(separatedBy: "\n")` — which allocates ~15,000 strings for a
     730 KB file before any work happens — with a lazy walk that finds each `"\n"` via
     `NSString.range(of:range:)`. Split on `"\n"` **only**, exactly as `components` does; do not
     switch to `lineRange(for:)`, which also breaks on `\r`, `\u{2028}`, and `\u{2029}` and would
     silently change behavior on CRLF files.
   - Keep `storedLineLength` as the line's length plus 1 when a `"\n"` terminator was found.
     This reproduces the existing `hasNewline = index < lines.count - 1` rule.
   - After processing each line, `break` once `offset >= limit`. The existing
     "an unclosed construct protects through end of text" tail then handles anything still open,
     which — after clipping to the scope — is identical to what the whole-document pass produces,
     because the scope ends at or before `limit`.

   A trailing `"\n"` makes `components` emit one final empty string that the lazy walk does not.
   That line contributes nothing under either function's predicates, so behavior is unchanged;
   the equivalence test covers it.

3. **`ignoredRanges(in:enclosingRange:)` keeps calling the unbounded form** (`upTo: nil`), so
   Writing Tools protection is untouched. It must remain whole-document.

4. **Add the scoped entry point:**

```swift
    /// Block-level protected ranges (front matter, fenced code, math) intersecting `scope`,
    /// clipped to it.
    ///
    /// Load-bearing: this exists so the spell-check path never pays for the whole-document
    /// `ignoredRanges` pass (18 ms at 730 KB — see its note above). Fence and `$$`-block state
    /// depend on the document prefix, so lines before `scope` are still walked for state; the
    /// walk stops once past `scope` and allocates no per-line array.
    ///
    /// See `docs/superpowers/specs/2026-07-26-live-spell-check-design.md`.
    static func protectedRanges(in text: NSString, intersecting scope: NSRange) -> [NSRange] {
        let full = NSRange(location: 0, length: text.length)
        let clampedScope = NSIntersectionRange(scope, full)
        guard clampedScope.length > 0 else { return [] }

        let source = text as String
        let limit = NSMaxRange(clampedScope)

        var ranges: [NSRange] = []
        if let frontMatter = frontMatterRange(in: source) {
            ranges.append(frontMatter)
        }
        ranges.append(contentsOf: fencedCodeRanges(in: source, upTo: limit))
        ranges.append(contentsOf: mathRanges(in: source, upTo: limit))

        return ranges
            .map { NSIntersectionRange($0, clampedScope) }
            .filter { $0.length > 0 }
    }
```

**If the equivalence test fails**, the whole-document functions are the source of truth. Fix the
bounded iteration to match them — never adjust the whole-document behavior, which would change
Writing Tools protection and is out of scope for this feature.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/MarkdownWritingToolsProtectionTests 2>&1 | tail -20
```

Expected: all pass, including the pre-existing tests in that file (they guard `ignoredRanges`, which must be unchanged).

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/MarkdownWritingToolsProtection.swift LineformTests/MarkdownWritingToolsProtectionTests.swift
git commit -m "Add scoped block-region detection for spell checking"
```

---

### Task 3: `MarkdownSpellCheckRegions`

**Files:**
- Create: `Lineform/Editor/MarkdownSpellCheckRegions.swift`
- Test: `LineformTests/MarkdownSpellCheckRegionsTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `MarkdownWritingToolsProtection.protectedRanges(in:intersecting:)` (Task 2); `MarkdownSyntaxHighlighter.scopedTokenRange(visibleRange:margin:in:)` and `tokens(in:scope:)` (existing); `MarkdownTokenKind` (existing).
- Produces: `MarkdownSpellCheckRegions.checkableRanges(in text: NSString, enclosing range: NSRange, highlighter: MarkdownSyntaxHighlighter) -> [NSRange]`. Used by Task 5.

- [ ] **Step 1: Write the failing tests**

Create `LineformTests/MarkdownSpellCheckRegionsTests.swift`:

```swift
import XCTest
@testable import Lineform

final class MarkdownSpellCheckRegionsTests: XCTestCase {
    private func checkableText(_ source: String) -> [String] {
        let text = source as NSString
        let full = NSRange(location: 0, length: text.length)
        return MarkdownSpellCheckRegions
            .checkableRanges(in: text, enclosing: full)
            .map { text.substring(with: $0) }
    }

    func testPlainProseIsFullyCheckable() {
        let text = "the quick brown fox" as NSString
        let full = NSRange(location: 0, length: text.length)
        XCTAssertEqual(MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: full), [full])
    }

    func testInlineCodeIsExcludedButSurroundingProseIsKept() {
        let joined = checkableText("Set `isRichText` to false befor shipping").joined()
        XCTAssertFalse(joined.contains("isRichText"), "inline code must not be checked")
        XCTAssertTrue(joined.contains("befor"), "prose around inline code must still be checked")
    }

    func testFencedCodeIsExcluded() {
        let joined = checkableText("prose one\n```swift\nlet teh = 1\n```\nprose two").joined()
        XCTAssertFalse(joined.contains("let teh"))
        XCTAssertTrue(joined.contains("prose one"))
        XCTAssertTrue(joined.contains("prose two"))
    }

    func testFrontMatterIsExcluded() {
        let joined = checkableText("---\ntitle: teh\n---\nprose here").joined()
        XCTAssertFalse(joined.contains("title: teh"))
        XCTAssertTrue(joined.contains("prose here"))
    }

    func testDisplayMathIsExcluded() {
        let joined = checkableText("prose\n$$\nx = y\n$$\nmore prose").joined()
        XCTAssertFalse(joined.contains("x = y"))
        XCTAssertTrue(joined.contains("more prose"))
    }

    func testLinkTextIsCheckedButDestinationIsNot() {
        let joined = checkableText("See [teh docs](/Users/qa/somefile.md) now").joined()
        XCTAssertTrue(joined.contains("teh docs"), "link TEXT is prose and must be checked")
        XCTAssertFalse(joined.contains("/Users/qa/somefile.md"), "link destination must not be checked")
    }

    func testImageDestinationIsNotChecked() {
        let joined = checkableText("![alt teh](/Users/qa/img-pth.png) after").joined()
        XCTAssertFalse(joined.contains("/Users/qa/img-pth.png"))
        XCTAssertTrue(joined.contains("after"))
    }

    func testResultRangesAreOrderedNonEmptyAndNonOverlapping() {
        let text = "a `b` c `d` e\n```\nf\n```\ng [h](/i) j" as NSString
        let ranges = MarkdownSpellCheckRegions
            .checkableRanges(in: text, enclosing: NSRange(location: 0, length: text.length))
        for range in ranges {
            XCTAssertGreaterThan(range.length, 0, "zero-length range emitted")
        }
        for (lhs, rhs) in zip(ranges, ranges.dropFirst()) {
            XCTAssertLessThanOrEqual(NSMaxRange(lhs), rhs.location, "ranges overlap or are unsorted")
        }
    }

    func testEnclosingRangeIsRespected() {
        let text = "aaaa `bb` cccc" as NSString
        let enclosing = NSRange(location: 0, length: 4)
        let ranges = MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: enclosing)
        XCTAssertEqual(ranges, [enclosing], "must never return anything outside the enclosing range")
    }

    func testEmptyAndOutOfBoundsRangesAreSafe() {
        let text = "hello" as NSString
        XCTAssertTrue(MarkdownSpellCheckRegions
            .checkableRanges(in: text, enclosing: NSRange(location: 0, length: 0)).isEmpty)
        XCTAssertTrue(MarkdownSpellCheckRegions
            .checkableRanges(in: "" as NSString, enclosing: NSRange(location: 0, length: 0)).isEmpty)
        XCTAssertEqual(
            MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: NSRange(location: 0, length: 999)),
            [NSRange(location: 0, length: 5)],
            "an over-long enclosing range must clamp, not crash"
        )
    }

    /// Guards the line-local invariant: a scoped computation must agree with the
    /// whole-document one, clipped. Mirrors ScopedSyntaxHighlightingTests.
    func testScopedResultMatchesWholeDocumentClipped() {
        let text = """
        ---
        title: Doc
        ---
        prose one `code` tail
        ```swift
        let a = 1
        ```
        prose two [link](/a/b) end
        $$
        a = b
        $$
        prose three $x+y$ done
        """ as NSString
        let full = NSRange(location: 0, length: text.length)
        let whole = MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: full)

        var scope = NSRange(location: 0, length: 0)
        while scope.location < text.length {
            scope = text.lineRange(for: NSRange(location: scope.location, length: 0))
            let scoped = MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: scope)
            let expected = whole.map { NSIntersectionRange($0, scope) }.filter { $0.length > 0 }
            XCTAssertEqual(
                scoped, expected,
                "scoped diverged from whole-document at \(NSStringFromRange(scope))"
            )
            scope.location = NSMaxRange(scope)
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/MarkdownSpellCheckRegionsTests 2>&1 | tail -20
```

Expected: compile failure — no such type `MarkdownSpellCheckRegions`, and the test file is not yet in the project.

- [ ] **Step 3: Implement**

Create `Lineform/Editor/MarkdownSpellCheckRegions.swift`:

```swift
import Foundation

/// The sub-ranges of a document that should be spell-checked: everything except the Markdown
/// regions where a "misspelling" is not a misspelling.
///
/// Pure and AppKit-free so it tests in the default plan, and — load-bearing — so the checking
/// path never touches a whole-document pass. `MarkdownWritingToolsProtection.ignoredRanges` and
/// `MarkdownRangeAnalyzer.ranges(in:)` are both whole-document (18 ms at 730 KB) and are BANNED
/// from this path. See `docs/superpowers/specs/2026-07-26-live-spell-check-design.md`.
enum MarkdownSpellCheckRegions {
    /// Inline token kinds that are not prose. Link and image TEXT are deliberately absent:
    /// `[teh docs](/path)` should flag `teh` and ignore `/path`.
    static let suppressedInlineKinds: Set<MarkdownTokenKind> = [
        .codeSpan,
        .linkDestination,
        .imageDestination,
    ]

    static func checkableRanges(
        in text: NSString,
        enclosing range: NSRange,
        highlighter: MarkdownSyntaxHighlighter = MarkdownSyntaxHighlighter()
    ) -> [NSRange] {
        let full = NSRange(location: 0, length: text.length)
        let clamped = NSIntersectionRange(range, full)
        guard clamped.length > 0 else { return [] }

        // Snap out to line boundaries before tokenizing. The analyzer is line-local, so this is
        // exactly what makes the scoped tokens byte-identical to a whole-document pass; a raw
        // AppKit range would mis-tokenize a construct straddling the edge.
        let scope = MarkdownSyntaxHighlighter.scopedTokenRange(visibleRange: clamped, margin: 0, in: text)

        var suppressed = MarkdownWritingToolsProtection.protectedRanges(in: text, intersecting: scope)
        suppressed += highlighter
            .tokens(in: text, scope: scope)
            .filter { suppressedInlineKinds.contains($0.kind) }
            .map(\.range)

        return subtracting(suppressed, from: clamped)
    }

    /// `range` minus `ranges`, clipped, sorted, coalesced. Never returns zero-length or
    /// overlapping ranges — AppKit is handed each result directly.
    static func subtracting(_ ranges: [NSRange], from range: NSRange) -> [NSRange] {
        let clipped = ranges
            .map { NSIntersectionRange($0, range) }
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }

        var result: [NSRange] = []
        var cursor = range.location
        for suppressed in clipped {
            if suppressed.location > cursor {
                result.append(NSRange(location: cursor, length: suppressed.location - cursor))
            }
            cursor = max(cursor, NSMaxRange(suppressed))
        }
        if cursor < NSMaxRange(range) {
            result.append(NSRange(location: cursor, length: NSMaxRange(range) - cursor))
        }
        return result
    }
}
```

- [ ] **Step 4: Add both files to the Xcode project**

There are no synced groups; each file needs 4 entries. Use the reserved IDs — `0086` for the source file, `0087` for the test file. Verify they are still unused first:

```bash
grep -c "00000000000086 \|00000000000087 " Lineform.xcodeproj/project.pbxproj
```

Expected: `0`. Then add, mirroring the `MarkdownListContinuation.swift` entries exactly:

1. **PBXBuildFile** (near line 89, app section):
   `1F0000010000000000000086 /* MarkdownSpellCheckRegions.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1F0000020000000000000086 /* MarkdownSpellCheckRegions.swift */; };`
2. **PBXBuildFile** (near line 16, test section):
   `1F0000010000000000000087 /* MarkdownSpellCheckRegionsTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1F0000020000000000000087 /* MarkdownSpellCheckRegionsTests.swift */; };`
3. **PBXFileReference** ×2 (near lines 284 and 202 respectively):
   `1F0000020000000000000086 /* MarkdownSpellCheckRegions.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MarkdownSpellCheckRegions.swift; sourceTree = "<group>"; };`
   `1F0000020000000000000087 /* MarkdownSpellCheckRegionsTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MarkdownSpellCheckRegionsTests.swift; sourceTree = "<group>"; };`
4. **PBXGroup children** — add the source ref to the Editor group (near line 482, beside `MarkdownListContinuation.swift`) and the test ref to the tests group (near line 576).
5. **PBXSourcesBuildPhase files** — add the build-file ref to the app target's Sources (near line 843) and the test one to the test target's Sources (near line 918).

Then confirm the project still parses:

```bash
plutil -lint Lineform.xcodeproj/project.pbxproj
xcodebuild -project Lineform.xcodeproj -list >/dev/null && echo "project OK"
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/MarkdownSpellCheckRegionsTests 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Lineform/Editor/MarkdownSpellCheckRegions.swift \
        LineformTests/MarkdownSpellCheckRegionsTests.swift \
        Lineform.xcodeproj/project.pbxproj
git commit -m "Add MarkdownSpellCheckRegions: prose-only ranges for spell checking"
```

---

### Task 4: Persist the continuous-checking preference

**Files:**
- Modify: `Lineform/App/LineformSettings.swift`
- Test: `LineformTests/LineformSettingsTests.swift` (existing file — add to it)

**Interfaces:**
- Consumes: nothing new.
- Produces: `LineformSettingsStore.checksSpellingWhileTyping: Bool` (settable, `@Published`, defaults `true`) and `LineformSettingsStore.checksSpellingWhileTypingKey: String`. Used by Task 5.

- [ ] **Step 1: Write the failing tests**

Add to `LineformTests/LineformSettingsTests.swift`, following the existing pattern in that file for creating a store with an injected `UserDefaults`:

```swift
    // MARK: - Spell checking

    @MainActor
    func testChecksSpellingWhileTypingDefaultsToTrue() {
        let defaults = UserDefaults(suiteName: "spellcheck-default-\(UUID().uuidString)")!
        let store = LineformSettingsStore(defaults: defaults)
        XCTAssertTrue(store.checksSpellingWhileTyping, "spell check ships on")
    }

    @MainActor
    func testChecksSpellingWhileTypingPersistsFalse() {
        let suite = "spellcheck-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = LineformSettingsStore(defaults: defaults)
        store.checksSpellingWhileTyping = false

        let reloaded = LineformSettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.checksSpellingWhileTyping, "the user's choice must survive relaunch")
    }

    @MainActor
    func testChecksSpellingWhileTypingWritesThroughToDefaults() {
        let defaults = UserDefaults(suiteName: "spellcheck-writethrough-\(UUID().uuidString)")!
        let store = LineformSettingsStore(defaults: defaults)
        store.checksSpellingWhileTyping = false
        XCTAssertEqual(
            defaults.object(forKey: LineformSettingsStore.checksSpellingWhileTypingKey) as? Bool,
            false
        )
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/LineformSettingsTests 2>&1 | tail -20
```

Expected: compile failure — no such member `checksSpellingWhileTyping`.

- [ ] **Step 3: Implement**

In `LineformSettings.swift`, add the key beside the existing three:

```swift
    static let checksSpellingWhileTypingKey = "Lineform.settings.checksSpellingWhileTyping"
```

Add the property beside the other `@Published` ones:

```swift
    /// Live (as-you-type) spell checking. Driven solely by the standard
    /// Edit ▸ Spelling and Grammar ▸ Check Spelling While Typing menu item — there is
    /// deliberately no Settings row, to avoid two controls for one Bool. `LineformTextView`
    /// reads this at construction so new tabs and windows inherit the choice.
    @Published var checksSpellingWhileTyping: Bool {
        didSet {
            guard oldValue != checksSpellingWhileTyping else { return }
            defaults.set(checksSpellingWhileTyping, forKey: Self.checksSpellingWhileTypingKey)
        }
    }
```

And in `init(defaults:)`, beside the other backing-storage assignments — **`Published(initialValue:)`, not a plain assignment**, matching the note already in that initializer:

```swift
        _checksSpellingWhileTyping = Published(initialValue: boolOrDefault(Self.checksSpellingWhileTypingKey, true))
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/LineformSettingsTests 2>&1 | tail -20
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Lineform/App/LineformSettings.swift LineformTests/LineformSettingsTests.swift
git commit -m "Persist the live spell check preference"
```

---

### Task 5: Wire spell checking into the text view

**Files:**
- Modify: `Lineform/Editor/LineformTextView.swift` (`configureForMarkdownEditing`, around line 625-640; new overrides)

**Interfaces:**
- Consumes: `MarkdownSpellCheckRegions.checkableRanges(in:enclosing:highlighter:)` (Task 3); `LineformSettingsStore.shared.checksSpellingWhileTyping` (Task 4).
- Produces: no new API. Behavior only.

**Precondition:** Task 1 concluded that `checkText(in:types:options:)` fires for continuous checking. If it did not, STOP — this task's design does not apply and the user must decide.

- [ ] **Step 1: Change the editing configuration**

In `configureForMarkdownEditing()`, replace the single line:

```swift
        isAutomaticSpellingCorrectionEnabled = true
```

with:

```swift
        // Squiggles, not silent rewrites: the app points at problems and lets the writer decide.
        // Autocorrect is actively wrong for Markdown, where identifiers, paths, and URLs are
        // ordinary content. Grammar checking is off DELIBERATELY (set, not omitted) — it flags
        // headings, list items, and captions as fragments, which fights calm writing.
        isAutomaticSpellingCorrectionEnabled = false
        isGrammarCheckingEnabled = false
        isContinuousSpellCheckingEnabled = LineformSettingsStore.shared.checksSpellingWhileTyping
```

Leave the quote / dash / text-replacement lines above it exactly as they are.

- [ ] **Step 2: Add the range-splitting override**

Add near `writingToolsIgnoredRanges(in:)` (around line 803), which solves the same problem for Writing Tools:

```swift
    /// Spell-checks only the prose parts of `range`, calling `super` once per checkable
    /// sub-range so a paragraph containing `inlineCode` still gets its real typos flagged.
    ///
    /// Load-bearing: `MarkdownSpellCheckRegions` is scoped by construction. Do NOT substitute
    /// `MarkdownWritingToolsProtection.ignoredRanges` or `MarkdownRangeAnalyzer.ranges(in:)`
    /// here — both are whole-document (18 ms at 730 KB) and this runs as the user types.
    override func checkText(
        in range: NSRange,
        types checkingTypes: NSTextCheckingTypes,
        options: [NSAttributedString.TextCheckingOptionKey: Any]
    ) {
        guard isContinuousSpellCheckingEnabled else {
            super.checkText(in: range, types: checkingTypes, options: options)
            return
        }

        let checkable = MarkdownSpellCheckRegions.checkableRanges(
            in: string as NSString,
            enclosing: range,
            highlighter: markdownHighlighter
        )
        for subRange in checkable {
            super.checkText(in: subRange, types: checkingTypes, options: options)
        }
    }
```

The `guard` matters: an explicit "Check Document Now" with continuous checking off should behave exactly as AppKit intends, unsuppressed.

- [ ] **Step 3: Persist the menu item's toggle**

Add below the override from Step 2:

```swift
    /// The standard Edit ▸ Spelling and Grammar ▸ Check Spelling While Typing item is the only
    /// control for this feature. AppKit flips the flag on this view; we persist the result so it
    /// survives relaunch and applies to newly opened tabs and windows.
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        LineformSettingsStore.shared.checksSpellingWhileTyping = isContinuousSpellCheckingEnabled
    }
```

- [ ] **Step 4: Build and run the full default suite**

```bash
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO 2>&1 | tail -25
```

Expected: the whole suite passes (~800 tests). Report exact pass/fail counts. **Warn the user before starting** — a CLI test run re-signs the host ad-hoc and can raise a TCC prompt for Documents access that blocks the run.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/LineformTextView.swift
git commit -m "Enable live spell check, suppressed inside non-prose Markdown"
```

---

### Task 6: The performance gate

**This task can block the release.** It is not a formality.

**Files:**
- Create: `LineformTests/MarkdownSpellCheckPerformanceTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `MarkdownSpellCheckRegions.checkableRanges(in:enclosing:highlighter:)` (Task 3).
- Produces: an automated regression guard. No app-facing API.

- [ ] **Step 1: Write the performance guard test**

Create `LineformTests/MarkdownSpellCheckPerformanceTests.swift`. A plain wall-clock ceiling rather than `measure`, so it catches order-of-magnitude regressions (the 18 ms whole-document pass) without failing on ordinary CI noise:

```swift
import XCTest
@testable import Lineform

/// Guards the load-bearing performance constraint: the spell-check range computation runs as the
/// user types, so it must never acquire a whole-document pass. The ceiling is deliberately loose
/// — it is here to catch a regression of that KIND (18 ms whole-document work at this size), not
/// to police microseconds on a busy CI runner.
final class MarkdownSpellCheckPerformanceTests: XCTestCase {
    private static let ceilingSeconds: TimeInterval = 0.005

    private func largeDocument() -> NSString {
        var parts: [String] = ["---", "title: Large Fixture", "---", ""]
        var index = 0
        var size = 0
        while size < 730 * 1024 {
            index += 1
            let block: [String]
            switch index % 12 {
            case 0: block = ["```swift", "let isRichText = false", "func doThing() {}", "```", ""]
            case 5: block = ["$$", "a = b", "$$", ""]
            case 7: block = ["See [the docs](/Users/qa/notes/file-\(index).md) and `NSTextView`.", ""]
            case 9: block = ["## Section \(index)", ""]
            default: block = ["the quick brown fox jumps over the lazy dog writing calm markdown", ""]
            }
            parts += block
            size += block.reduce(0) { $0 + $1.count + 1 }
        }
        return parts.joined(separator: "\n") as NSString
    }

    func testCheckableRangesStaysFastOnALargeDocument() {
        let text = largeDocument()
        XCTAssertGreaterThan(text.length, 700 * 1024, "fixture must be large enough to be meaningful")

        // A realistic checked range: one paragraph in the MIDDLE of the document, which is the
        // worst case for the prefix walk.
        let midpoint = text.length / 2
        let range = text.lineRange(for: NSRange(location: midpoint, length: 0))
        let highlighter = MarkdownSyntaxHighlighter()

        // Warm up, so the first call's one-time costs are not what gets measured.
        _ = MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: range, highlighter: highlighter)

        let iterations = 20
        let start = Date()
        for _ in 0..<iterations {
            _ = MarkdownSpellCheckRegions.checkableRanges(in: text, enclosing: range, highlighter: highlighter)
        }
        let perCall = Date().timeIntervalSince(start) / Double(iterations)

        XCTAssertLessThan(
            perCall, Self.ceilingSeconds,
            """
            checkableRanges took \(String(format: "%.2f", perCall * 1000)) ms per call on a \
            \(text.length / 1024) KB document (ceiling \(Self.ceilingSeconds * 1000) ms). \
            This almost certainly means a whole-document pass crept into the checking path — \
            check for ignoredRanges(in:enclosingRange:) or MarkdownRangeAnalyzer.ranges(in:).
            """
        )
    }
}
```

- [ ] **Step 2: Add the test file to the project**

Same 4-section recipe as Task 3 Step 4, using reserved ID `0088`. Verify unused first:

```bash
grep -c "00000000000088 " Lineform.xcodeproj/project.pbxproj
```

Expected: `0`. Then `plutil -lint Lineform.xcodeproj/project.pbxproj` to confirm it still parses.

- [ ] **Step 3: Run it and record the actual number**

```bash
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:LineformTests/MarkdownSpellCheckPerformanceTests 2>&1 | tail -20
```

Expected: PASS. **Record the actual per-call milliseconds** from the failure message format even on success — re-run with a deliberately tiny ceiling once if needed to print it. The spec's budget is ≤ 1 ms; the test ceiling is 5 ms to absorb CI noise. **If the real number is between 1 and 5 ms, report it to the user** — it passes the guard but misses the budget, and that is a judgement call, not an automatic pass.

- [ ] **Step 4: Take measurement C and compare against Task 1's baselines**

Re-apply the temporary `didChangeText` instrumentation from Task 1 Step 5 verbatim (it was
reverted at the end of that task), rebuild, and repeat the same thirty-second user-driven typing
run in the middle of `/tmp/lineform-spellcheck-qa/large.md`, summarized with the same script.
This is configuration **C** (spell check on + suppression). Revert the instrumentation before
Step 6's commit and verify with `grep -rn "PROBE\|latencyLog" Lineform/ || echo clean`.

Compare against the `n`/median/p99/max recorded in the Task 1 findings document. Use **p99**, not
median, as the decision number — typing lag is felt in the tail, and a median can look clean
while every twentieth keystroke stutters.

Compare:
- **C vs. B** — our code's cost. Should be within noise.
- **C vs. A** — total user-visible change. **This is the gate.**

- [ ] **Step 5: The gate decision**

- **C shows no measurable regression against A** → pass, continue to Task 7.
- **C is measurably worse than A, but C ≈ B** → our code is fine; Apple's checker is the cost. **STOP and report to the user** with all three numbers. Likely resolution is a document-size threshold, which is a product decision, not an implementation one.
- **C is measurably worse than B** → our code is the problem. The documented next step is checkpointing fence state every N lines and invalidating only from the edit offset forward (spec, implementation rule 5). **Do not add this speculatively** — only if this measurement demands it, and re-run the gate afterwards.

Do not proceed past a failed gate by relaxing the ceiling.

- [ ] **Step 6: Commit**

```bash
git add LineformTests/MarkdownSpellCheckPerformanceTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Guard spell check range computation against whole-document regressions"
```

---

### Task 7: Manual QA in a real build

Automated tests cannot see a red underline. This task is where the feature is actually verified.

**Files:** none modified.

**Interfaces:** none.

- [ ] **Step 1: Build and launch the fresh build by full path**

```bash
xcodebuild -project Lineform.xcodeproj -scheme Lineform -configuration Debug build 2>&1 | tail -5
BUILT=$(xcodebuild -project Lineform.xcodeproj -scheme Lineform -configuration Debug \
  -showBuildSettings 2>/dev/null | awk -F'= ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
killall Lineform 2>/dev/null; sleep 1
ps aux | grep -i "[L]ineform.app" || echo "none running"
```

Never `open -a Lineform` and never pick a path via `ls -dt | head` — both select a stale or installed copy, which reads exactly like the fix having failed. After launching, verify the running process path is the one under `$BUILT`.

- [ ] **Step 2: Create the QA fixture**

```bash
cat > /tmp/lineform-spellcheck-qa/qa.md <<'EOF'
---
title: teh front matter
---

This paragraph has a deliberate typo: teh end.

Set `isRichText` to false befor shipping.

See [teh docs](/Users/qa/notes/somefile-pth.md) for detail.

![alt teh](/Users/qa/img-pth.png)

```swift
let teh = 1  // recieve seperate
```

Inline math $x_{teh} + y$ and display math:

$$
a_{teh} = b
$$

Final prose paragraph with anoter typo.
EOF
open -a "$BUILT/Lineform.app" /tmp/lineform-spellcheck-qa/qa.md
```

- [ ] **Step 3: Hand the build to the user for the checks that need typing**

GUI typing cannot be automated here (System Events is unauthorized), so these must be driven by the user. Ask them to confirm, and record each answer honestly:

1. Red underlines appear under `teh`, `befor`, and `anoter` in the prose paragraphs.
2. **No** underline inside the fenced block (`teh`, `recieve`, `seperate`).
3. **No** underline in the front matter `title:` line.
4. **No** underline under `isRichText`, but `befor` on the same line **is** underlined. *(This is the check that proves the inline range-splitting works — the whole point of Task 1's probe.)*
5. In the link: `teh docs` **is** underlined, `/Users/qa/notes/somefile-pth.md` is **not**.
6. **No** underline inside `$x_{teh} + y$` or the `$$` block.
7. Right-clicking an underlined word offers suggestions, Learn Spelling, and Ignore Spelling.
8. Typing a word autocorrect used to "fix" — it is **not** silently changed.
9. Edit ▸ Spelling and Grammar shows "Check Spelling While Typing" **checked**.
10. Uncheck it → underlines disappear. Quit, relaunch, reopen the file → still off, still no underlines. Open a second file in a new tab → also off.
11. Re-check it → underlines return in both tabs' documents.
12. Typing in the middle of `/tmp/lineform-spellcheck-qa/large.md` feels no slower than before the change.

- [ ] **Step 4: Fix and re-verify**

For any failure, diagnose before changing code. Re-run the relevant task's tests plus the full default suite after each fix, then repeat Step 3's checks that were affected. Loop until every check passes. Do not mark this task complete with a known-failing check — record it and report it instead.

- [ ] **Step 5: Clean up**

```bash
rm -rf /tmp/lineform-spellcheck-qa
```

---

### Task 8: Documentation and final verification

Update only what the change actually invalidates. Do not add documentation for its own sake.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/architecture/editor-behavior.md`
- Modify: `docs/research/2026-07-25-feature-backlog.md`
- Modify: `Lineform/Resources/*.md` — **only if** an existing bundled doc describes editor behavior that is now wrong or incomplete. Check first; do not create new files.
- Delete: `docs/notes/2026-07-26-spell-check-probe-findings.md` if its content has been folded into `editor-behavior.md`, or keep it if it records numbers worth preserving. Decide, don't leave both saying the same thing.

**Interfaces:** none.

- [ ] **Step 1: Update `CLAUDE.md`**

Add one line to Main Features:

```markdown
- Live spell checking as you type, suppressed inside fenced code, front matter, math, inline code, and link/image destinations; autocorrect is off and grammar checking is not used.
```

Add one line under Load-Bearing Invariants, in the **Privacy** group beside the remote-image rule:

```markdown
- Spell checking routes through the system `NSSpellChecker` and nothing else — no bundled dictionary, no third-party service, no network-backed suggestions.
```

And one under **Editor**:

```markdown
- The spell-check path must never call `MarkdownWritingToolsProtection.ignoredRanges` or `MarkdownRangeAnalyzer.ranges(in:)` — both are whole-document (18 ms at 730 KB) and it runs as the user types. Use `MarkdownSpellCheckRegions`, which is scoped by construction and guarded by `MarkdownSpellCheckPerformanceTests`.
```

Keep each to one line — that file loads in full every session.

- [ ] **Step 2: Update `docs/architecture/editor-behavior.md`**

This is where the narrative belongs. Record: the two suppression sources and why link/image *text* is checked while destinations are not; the `checkText` override and **the Task 1 finding about which hook fires** (so nobody re-derives it); why autocorrect was turned off and grammar left off; the persistence path through the standard menu item and why there is no Settings row; the performance constraint, the measured A/B/C numbers, and the rejected alternatives from the spec.

- [ ] **Step 3: Update the backlog**

In `docs/research/2026-07-25-feature-backlog.md`: mark item 2 shipped in the same style as item 1, and update the `**Status:** 1 of 6 shipped. Remaining: 2–6.` line to `2 of 6 shipped. Remaining: 3–6.`

- [ ] **Step 4: Check the bundled user-facing docs**

```bash
grep -rln "spell\|autocorrect\|Writing Tools" Lineform/Resources/*.md
```

Update only files that are now inaccurate. If none are, say so and change nothing.

- [ ] **Step 5: Full verification before committing**

Warn the user first (TCC prompt risk), then:

```bash
xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' \
  -parallel-testing-enabled NO 2>&1 | tail -25
```

Report exact pass/fail counts. The hosted plan is **not** required — this change touches neither editor motion, drawer presentation, reload scroll behavior, nor PDF export.

- [ ] **Step 6: Commit**

Include the spec and the plan, which are still uncommitted from the design phase:

```bash
git add CLAUDE.md docs/architecture/editor-behavior.md \
        docs/research/2026-07-25-feature-backlog.md \
        docs/superpowers/specs/2026-07-26-live-spell-check-design.md \
        docs/superpowers/plans/2026-07-26-live-spell-check.md
git status --short
```

Check `git status` before committing: the user has untracked `feature-showcase.md` and `feature-showcase copy.md` files at the repo root that must **not** be committed.

```bash
git commit -m "Document live spell check"
```

---

## Definition of Done

- [ ] Task 1's open question is answered and recorded, not assumed.
- [ ] Full default suite passes, with exact counts reported.
- [ ] The performance gate passed with real numbers, or the feature stopped and the numbers were reported.
- [ ] All 12 manual QA checks confirmed by the user in a real build.
- [ ] Docs updated only where the change made them wrong.
- [ ] `git status` clean except the user's untracked `feature-showcase*.md` files.
