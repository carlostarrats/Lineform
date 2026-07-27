import XCTest
@testable import Lineform

/// The third probe file, chosen the same way as `RobustnessProbeTests`: ask which surfaces the
/// previous sweeps *omit*, not whether the code reads correctly.
///
/// What the earlier sweeps did not reach:
///
/// - **The outline.** Its fence tracking is a second definition of "am I inside fenced code",
///   independent of the one `markdownBlocks(in:)` uses, and every such pair in this codebase that
///   was checked turned out to disagree. A disagreement here is user-visible twice over: a phantom
///   heading listed from inside a code block, and a real heading missing from the list. Its
///   `characterRange` is also fed to the scroll restore, so a bad one misaims a jump.
/// - **The insertion paths that are not keystrokes.** The line-ending invariant was closed over
///   Return, list continuation, and the table commands. Image insertion writes to the document
///   through the same undo path and was never included.
final class OutlineAndInsertionProbeTests: XCTestCase {

    private struct Seeded {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func int(_ bound: Int) -> Int { bound <= 0 ? 0 : Int(next() % UInt64(bound)) }
    }

    /// Fence-shaped fragments plus the characters the heading parser special-cases.
    private static let lineAlphabet = [
        "```", "~~~", "````", "~~~~", "``` swift", "```mermaid", "# One", "## Two", "#Three",
        "   # Indented", "    # Code indented", "text", "", "| a | b |", "- item", "> quote",
        "---", "# Wide 😀 é\u{301}",
    ]

    private func fuzzDocument(_ random: inout Seeded, lineCount: Int = 14) -> String {
        (0..<lineCount)
            .map { _ in Self.lineAlphabet[random.int(Self.lineAlphabet.count)] }
            .joined(separator: random.int(4) == 0 ? "\r\n" : "\n")
    }

    // MARK: - Outline vs. the renderer

    /// The two definitions of "inside fenced code" must agree.
    ///
    /// `markdownBlocks(in:)` matches a closing fence per CommonMark — same delimiter character, a
    /// run at least as long as the opener's — which is what stops an inner `~~~` from truncating a
    /// ``` block. Anything that tracks fences by toggling on "starts with ``` or ~~~" answers a
    /// different question, and the two diverge on documents that are entirely ordinary: any note
    /// *about* Markdown, where a longer fence wraps a shorter one.
    func testOutlineNeverReportsHeadingsInsideFencedCode() {
        var random = Seeded(state: 0x5EED_0C7)
        let parser = MarkdownOutlineParser()

        for _ in 0..<400 {
            let text = fuzzDocument(&random)
            let source = markdownSourceLines(in: text)
            let fencedRanges = Self.fencedSourceRanges(in: source)

            for item in parser.items(in: text) {
                let location = item.characterRange.location
                XCTAssertFalse(
                    fencedRanges.contains { NSLocationInRange(location, $0) },
                    "Outline listed a heading from inside a fenced code block in:\n\(text)"
                )
            }
        }
    }

    /// The other half: every heading the renderer treats as prose must appear in the outline.
    func testOutlineListsEveryHeadingTheRendererTreatsAsProse() {
        var random = Seeded(state: 0x0C7_5EED)
        let parser = MarkdownOutlineParser()

        for _ in 0..<400 {
            let text = fuzzDocument(&random)
            let source = markdownSourceLines(in: text)
            let fencedRanges = Self.fencedSourceRanges(in: source)
            let listed = Set(parser.items(in: text).map(\.characterRange.location))

            for (index, line) in source.lines.enumerated() {
                let start = source.ranges[index].location
                guard !fencedRanges.contains(where: { NSLocationInRange(start, $0) }) else { continue }
                guard MarkdownHeadingParser.heading(in: line) != nil else { continue }
                XCTAssertTrue(
                    listed.contains(start),
                    "Outline omitted the heading '\(line)' in:\n\(text)"
                )
            }
        }
    }

    /// `characterRange` is handed to the scroll restore and to `setSelectedRange`-shaped calls.
    func testOutlineRangesStayInBounds() {
        var random = Seeded(state: 0xB0_1145)
        let parser = MarkdownOutlineParser()

        for _ in 0..<400 {
            let text = fuzzDocument(&random)
            let length = (text as NSString).length
            for item in parser.items(in: text) {
                XCTAssertGreaterThanOrEqual(item.characterRange.location, 0)
                XCTAssertLessThanOrEqual(NSMaxRange(item.characterRange), length, "in:\n\(text)")
                XCTAssertGreaterThan(item.lineNumber, 0)
            }
        }
    }

    /// Source ranges of every fenced block, walked with the SAME primitives `markdownBlocks(in:)`
    /// uses to consume a fence — `MermaidFence.openingMarker` / `isClosingFence`, i.e. CommonMark
    /// matching. Written out here rather than read off `markdownBlocks` because the `.mermaid`
    /// case does not carry its opening line index, and this is the rule under test either way.
    private static func fencedSourceRanges(in source: MarkdownSourceLines) -> [NSRange] {
        var ranges: [NSRange] = []
        var openMarker: (character: Character, length: Int)?
        var openStart: Int?

        for (index, line) in source.lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: markdownLineTrimCharacters)
            if let marker = openMarker, let start = openStart {
                if MermaidFence.isClosingFence(trimmed, matching: marker) {
                    ranges.append(NSRange(location: start, length: NSMaxRange(source.ranges[index]) - start))
                    openMarker = nil
                    openStart = nil
                }
            } else if let marker = MermaidFence.openingMarker(trimmed) {
                openMarker = marker
                openStart = source.ranges[index].location
            }
        }

        if let start = openStart, let last = source.ranges.last {
            ranges.append(NSRange(location: start, length: NSMaxRange(last) - start))
        }
        return ranges
    }

    // MARK: - Insertion paths and line endings

    /// Every path that inserts a line into the document must write the ending already in force —
    /// dropping an image into a Windows-authored file must not leave a lone LF behind.
    func testImageInsertionPreservesCRLFEndings() {
        let crlf = "First line\r\nSecond line\r\n"

        let onLine = ImageInsertionText.insertingOnLine(into: crlf, at: 12, path: "pic.png")
        XCTAssertFalse(
            Self.hasLoneLF(onLine.applied(to: crlf)),
            "insertingOnLine introduced a lone LF into a CRLF document"
        )

        let atEnd = ImageInsertionText.appendingAtEnd(into: crlf, path: "pic.png")
        XCTAssertFalse(
            Self.hasLoneLF(atEnd.applied(to: crlf)),
            "appendingAtEnd introduced a lone LF into a CRLF document"
        )

        // An LF document must stay pure LF.
        let lf = "First line\nSecond line\n"
        XCTAssertFalse(
            ImageInsertionText.insertingOnLine(into: lf, at: 6, path: "pic.png")
                .applied(to: lf).contains("\r")
        )
        XCTAssertFalse(
            ImageInsertionText.appendingAtEnd(into: lf, path: "pic.png")
                .applied(to: lf).contains("\r")
        )
    }

    /// A CRLF document whose last line is unterminated still ends the appended image's own line
    /// with CRLF, and does not glue the image onto the previous line.
    func testImageAppendAtEndOfUnterminatedCRLFDocument() {
        let crlf = "First line\r\nSecond line"
        let result = ImageInsertionText.appendingAtEnd(into: crlf, path: "pic.png").applied(to: crlf)
        XCTAssertFalse(Self.hasLoneLF(result))
        XCTAssertTrue(result.hasPrefix("First line\r\nSecond line\r\n!["), result)
    }

    /// The insertion offsets go straight to `replaceCharacters`, which raises out of bounds.
    func testImageInsertionOffsetsStayInBounds() {
        var random = Seeded(state: 0xF00D_1E)
        for _ in 0..<400 {
            let text = fuzzDocument(&random, lineCount: 6)
            let length = (text as NSString).length
            for index in [-5, 0, length / 2, length, length + 9] {
                let edit = ImageInsertionText.insertingOnLine(into: text, at: index, path: "p.png")
                XCTAssertGreaterThanOrEqual(edit.location, 0)
                XCTAssertLessThanOrEqual(edit.location, length, "in:\n\(text)")
            }
            let end = ImageInsertionText.appendingAtEnd(into: text, path: "p.png")
            XCTAssertEqual(end.location, length)
        }
    }

    private static func hasLoneLF(_ text: String) -> Bool {
        let ns = text as NSString
        for index in 0..<ns.length where ns.character(at: index) == 0x0A {
            if index == 0 || ns.character(at: index - 1) != 0x0D {
                return true
            }
        }
        return false
    }

    // MARK: - Edits driven by a range the renderer produced

    /// Both take a source range computed from an earlier render and hand the result back as the
    /// whole document. A stale or malformed range must decline, never trap or corrupt.
    func testCheckboxToggleDeclinesOnAdversarialRanges() {
        var random = Seeded(state: 0xC4EC_B0)
        for _ in 0..<600 {
            let text = fuzzDocument(&random, lineCount: 5)
            let length = (text as NSString).length
            let range = NSRange(
                location: random.int(max(1, length + 4)) - 2,
                length: random.int(6)
            )
            if let toggled = CheckboxToggle.toggledText(in: text, at: range) {
                XCTAssertEqual((toggled as NSString).length, length, "toggle changed the length")
            }
        }
    }

    func testImageLinkRewriteDeclinesOnAdversarialRanges() {
        var random = Seeded(state: 0x1A6E_02)
        for _ in 0..<600 {
            let text = fuzzDocument(&random, lineCount: 5)
            let length = (text as NSString).length
            let range = NSRange(
                location: random.int(max(1, length + 4)) - 2,
                length: random.int(max(1, length))
            )
            _ = ImageLinkRewrite.rewritten(in: text, at: range, newPath: "new 😀.png")
        }
    }

    /// Return is the highest-frequency edit in the app; its outcome is applied verbatim.
    func testListContinuationOutcomesAreApplicable() {
        var random = Seeded(state: 0x11_57C0)
        for _ in 0..<600 {
            let text = fuzzDocument(&random, lineCount: 8)
            let length = (text as NSString).length
            let location = random.int(length + 1)
            let selection = NSRange(location: location, length: random.int(max(1, length - location + 1)))
            guard let outcome = MarkdownListContinuation.outcome(for: text, selectedRange: selection) else {
                continue
            }
            switch outcome {
            case let .continue(insertion):
                XCTAssertFalse(insertion.isEmpty)
                XCTAssertFalse(
                    Self.hasLoneLF(insertion) && text.contains("\r\n"),
                    "continued a CRLF document with a lone LF:\n\(text)"
                )
            case let .terminate(clearing):
                XCTAssertGreaterThanOrEqual(clearing.location, 0)
                XCTAssertLessThanOrEqual(NSMaxRange(clearing), length, "in:\n\(text)")
            }
        }
    }
}
