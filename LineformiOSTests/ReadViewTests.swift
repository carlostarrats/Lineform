import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The iPhone Read view: the shared renderer with real display metrics, task checkboxes that
/// toggle the source (one undo step, never a stale line, CRLF kept), Copy and Reconnect pills,
/// local-only images, the reflow anchor and refit on a width change, the table rows and their
/// grid, and the accessibility mirrors. Every test saves into its own temporary folder and copies
/// into its own pasteboard; nothing touches the network or iCloud.
@MainActor
final class ReadViewTests: XCTestCase {
    private var folder: URL!
    private var pasteboard: UIPasteboard!
    private var window: UIWindow?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("read-view-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pasteboard = UIPasteboard.withUniqueName()
    }

    override func tearDownWithError() throws {
        UIPasteboard.remove(withName: pasteboard.name)
        window?.isHidden = true
        window = nil
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Display metrics

    func testRendersWithRealDisplayScale() throws {
        func blockMath(scale: CGFloat) throws -> (pixelWidth: Int, view: LineformReadView) {
            let view = LineformReadView.make()
            view.traitOverrides.displayScale = scale
            host(view)
            view.updateTraitsIfNeeded()
            view.apply(text: "$$x^2+y^2$$\n\nAfter.", profile: .original, documentDirectory: nil)
            let attachment = try XCTUnwrap(blockAttachments(in: view).first, "a block equation")
            let image = try XCTUnwrap(attachment.image)
            return (try XCTUnwrap(image.cgImage).width, view)
        }
        let two = try blockMath(scale: 2)
        let metricsTwo = try XCTUnwrap(two.view.lastRenderMetrics)
        XCTAssertEqual(metricsTwo.scale, 2, "the view's displayScale, never the placeholder")
        XCTAssertEqual(metricsTwo.visibleViewportHeight, try XCTUnwrap(two.view.window).bounds.height,
                       "the window's height, never the placeholder")
        let three = try blockMath(scale: 3)
        XCTAssertEqual(three.view.lastRenderMetrics?.scale, 3)
        XCTAssertNotEqual(two.pixelWidth, three.pixelWidth, "the equation's raster follows the scale")
        XCTAssertEqual(CGFloat(three.pixelWidth) / CGFloat(two.pixelWidth), 1.5, accuracy: 0.05)
    }

    func testRendersOnlyWhenAnInputChanges() throws {
        let view = LineformReadView.make()
        host(view)
        view.apply(text: "```swift\nlet a = 1\n```", profile: .original, documentDirectory: nil)
        let storage = view.textStorage
        let firstColour = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        // The same inputs again (SwiftUI updates often): no new render, the code colours stay.
        view.apply(text: "```swift\nlet a = 1\n```", profile: .original, documentDirectory: nil)
        XCTAssertTrue(view.textStorage === storage)
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, firstColour)
    }

    // MARK: - Checkboxes

    func testCheckboxTapTogglesSourceAndUndoes() async throws {
        let document = await preparedDocument(text: "- [ ] one\n- [ ] two\n")
        let editor = attachedEditor(for: document)
        let view = readView(for: document, editor: editor)

        let second = NSRange(location: 12, length: 3)
        let rect = try XCTUnwrap(view.checkboxGlyphRect(forSourceRange: second))
        XCTAssertTrue(view.activateCheckbox(at: CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(document.text, "- [ ] one\n- [x] two\n")

        // A tap beside the glyph, on the same line, toggles nothing.
        XCTAssertFalse(view.activateCheckbox(at: CGPoint(x: view.bounds.width - 30, y: rect.midY)))
        XCTAssertEqual(document.text, "- [ ] one\n- [x] two\n")

        // One undo step in the editor's history, which is the view's undo manager too.
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(view.undoManager === undo)
        XCTAssertEqual(editor.text, "- [ ] one\n- [x] two\n", "a ranged edit in the editor's storage")
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(document.text, "- [ ] one\n- [ ] two\n")
        XCTAssertFalse(undo.canUndo)
        undo.redo()
        XCTAssertEqual(document.text, "- [ ] one\n- [x] two\n")

        // It is a normal edit: autosave writes it.
        await document.flush()
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(document.url), encoding: .utf8), "- [ ] one\n- [x] two\n")
    }

    func testStaleCheckboxRangeDoesNothing() async throws {
        let document = await preparedDocument(text: "- [ ] a\n- [ ] b\n")
        let view = readView(for: document)
        let rangeOfB = NSRange(location: 10, length: 3)
        let rect = try XCTUnwrap(view.checkboxGlyphRect(forSourceRange: rangeOfB))

        // Write typed a whole task line above before the render caught up: the old range now
        // holds the marker of "a", another line. The tap must not toggle it.
        document.edit("- [ ] z\n- [ ] a\n- [ ] b\n")
        XCTAssertTrue(view.activateCheckbox(at: CGPoint(x: rect.midX, y: rect.midY)), "the tap still lands on the old glyph")
        XCTAssertEqual(document.text, "- [ ] z\n- [ ] a\n- [ ] b\n", "a stale render toggles nothing")

        // A range that no longer holds a marker does nothing either (`CheckboxToggle` is nil).
        XCTAssertFalse(document.toggleCheckbox(at: NSRange(location: 3, length: 3)))
        XCTAssertEqual(document.text, "- [ ] z\n- [ ] a\n- [ ] b\n")
        XCTAssertFalse(document.toggleCheckbox(at: NSRange(location: 400, length: 3)))
        XCTAssertEqual(document.text, "- [ ] z\n- [ ] a\n- [ ] b\n")
    }

    func testCheckboxToggleKeepsCRLF() async throws {
        let text = "Tasks\r\n- [ ] one\r\n- [ ] two\r\nend\r\n"
        let document = await preparedDocument(text: text)
        let view = readView(for: document)
        let ranges = checkboxRanges(in: view)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual((text as NSString).substring(with: ranges[1]), "[ ]", "the range counts every \\r")
        let rect = try XCTUnwrap(view.checkboxGlyphRect(forSourceRange: ranges[1]))
        XCTAssertTrue(view.activateCheckbox(at: CGPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(document.text, "Tasks\r\n- [ ] one\r\n- [x] two\r\nend\r\n")
    }

    // MARK: - Copy

    func testCopyPillCopiesSourceAndDoesNotEdit() async throws {
        let text = "Intro\n\n```swift\nlet a = 1\nlet b = 2\n```\n\nOutro\n"
        let document = await preparedDocument(text: text)
        let view = readView(for: document)
        view.pasteboardForTesting = pasteboard

        let copy = try XCTUnwrap(view.overlayButtons.first { $0.kind == .copy })
        XCTAssertEqual(copy.frame.size, CGSize(width: 26, height: 26))
        let columnRight = view.textContainerInset.left + view.textContainer.size.width
        XCTAssertEqual(copy.frame.maxX, columnRight - 8, accuracy: 0.5, "at the column's right edge")
        XCTAssertEqual(copy.accessibilityLabel, "Copy code block 1")

        copy.sendActions(for: .touchUpInside)
        XCTAssertEqual(pasteboard.string, "let a = 1\nlet b = 2")
        XCTAssertEqual(document.text, text, "Copy never edits")
        XCTAssertTrue(copy.isShowingCopied, "the checkmark shows")

        try await Task.sleep(for: .milliseconds(700))
        XCTAssertTrue(copy.isShowingCopied, "still showing before 1.0 s")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(copy.isShowingCopied, "gone after 1.0 s")
    }

    // MARK: - Images

    func testReconnectRewritesLinkRelativeToDocumentFolder() async throws {
        let document = await preparedDocument(text: "Notes\n![pic](old/pic.png)\n")
        XCTAssertEqual(document.documentDirectory?.standardizedFileURL, folder.standardizedFileURL)
        let picked = folder.appendingPathComponent("images/pic.png")
        try FileManager.default.createDirectory(at: picked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.pngData(width: 40, height: 20).write(to: picked)

        var reconnectRanges: [NSRange] = []
        var renderedTexts: [String?] = []
        let editor = attachedEditor(for: document)
        let view = readView(for: document, editor: editor, onImageReconnect: {
            reconnectRanges.append($0)
            renderedTexts.append($1)
        })
        XCTAssertTrue(blockAttachments(in: view).isEmpty, "the missing file is a placeholder")
        let pill = try XCTUnwrap(view.overlayButtons.first { $0.kind == .reconnect })
        XCTAssertEqual(pill.frame.height, 22)
        XCTAssertEqual(pill.accessibilityLabel, "Reconnect image")
        pill.sendActions(for: .touchUpInside)
        let range = try XCTUnwrap(reconnectRanges.first)
        XCTAssertEqual(renderedTexts.first, document.text, "the pill reports the source it was rendered from")

        XCTAssertTrue(document.reconnectImage(at: range, with: picked, renderedFrom: renderedTexts.first ?? nil))
        XCTAssertEqual(document.text, "Notes\n![pic](images/pic.png)\n", "relative to the document's folder")

        // The next render loads it, and the pill is gone.
        configure(view, for: document)
        view.layoutIfNeeded()
        XCTAssertEqual(blockAttachments(in: view).count, 1)
        XCTAssertTrue(view.overlayButtons.filter { $0.kind == .reconnect }.isEmpty)

        try XCTUnwrap(editor.undoManager).undo()
        XCTAssertEqual(document.text, "Notes\n![pic](old/pic.png)\n", "one undo step, in the editor's history")

        // A CRLF document keeps every \r\n.
        document.edit("A\r\n![](gone.png)\r\nB\r\n")
        syncEditor(editor, to: document)
        var crlfRanges: [NSRange] = []
        let crlfView = readView(for: document, editor: editor, onImageReconnect: { range, _ in crlfRanges.append(range) })
        try XCTUnwrap(crlfView.overlayButtons.first { $0.kind == .reconnect }).sendActions(for: .touchUpInside)
        document.reconnectImage(at: try XCTUnwrap(crlfRanges.first), with: picked)
        XCTAssertEqual(document.text, "A\r\n![](images/pic.png)\r\nB\r\n")
    }

    func testReconnectPillStaysInsideColumn() async throws {
        // A long placeholder label on a narrow phone: the pill cannot follow the run, so it sits
        // under it, inside the column.
        let longName = String(repeating: "a-very-long-image-name-", count: 6) + "end.png"
        let document = await preparedDocument(text: "Intro\n\n![a long description of a missing picture](\(longName))\n\nOutro\n")
        let view = readView(for: document)
        let columnMinX = view.textContainerInset.left
        let columnMaxX = columnMinX + view.textContainer.size.width
        let pill = try XCTUnwrap(view.overlayButtons.first { $0.kind == .reconnect })
        XCTAssertGreaterThanOrEqual(pill.frame.minX, columnMinX - 0.5)
        XCTAssertLessThanOrEqual(pill.frame.maxX, columnMaxX + 0.5, "inside the column, not just the view")

        // The rule itself: after the run while it fits, else 4 pt under it.
        let short = CGRect(x: 20, y: 100, width: 80, height: 20)
        let after = LineformReadView.reconnectPillRect(after: short, columnMinX: 20, columnMaxX: 300)
        XCTAssertEqual(after.minX, short.maxX + ReadOverlayButton.reconnectPillLeadingGap)
        XCTAssertLessThan(after.minY, short.maxY, "beside the run")
        let wide = CGRect(x: 20, y: 100, width: 260, height: 40)
        let below = LineformReadView.reconnectPillRect(after: wide, columnMinX: 20, columnMaxX: 300)
        XCTAssertEqual(below.minY, wide.maxY + 4)
        XCTAssertEqual(below.minX, 20)
        XCTAssertLessThanOrEqual(below.maxX, 300)
    }

    func testReconnectRefusesTextChangedSincePickerOpened() async throws {
        let document = await preparedDocument(text: "Notes\n![pic](old/pic.png)\n")
        let picked = folder.appendingPathComponent("pic.png")
        try Self.pngData(width: 10, height: 10).write(to: picked)
        var opened: (range: NSRange, rendered: String?)?
        let view = readView(for: document, onImageReconnect: { opened = ($0, $1) })
        try XCTUnwrap(view.overlayButtons.first { $0.kind == .reconnect }).sendActions(for: .touchUpInside)
        let pick = try XCTUnwrap(opened)
        XCTAssertEqual(pick.rendered, document.text, "the source is captured with the range")

        // The writer typed above the image while the picker was open.
        document.edit("New first line\nNotes\n![pic](old/pic.png)\n")
        XCTAssertFalse(document.reconnectImage(at: pick.range, with: picked, renderedFrom: pick.rendered))
        XCTAssertEqual(document.text, "New first line\nNotes\n![pic](old/pic.png)\n", "a stale pick changes nothing")

        // The same pick against an unchanged text goes through.
        document.edit("Notes\n![pic](old/pic.png)\n")
        XCTAssertTrue(document.reconnectImage(at: pick.range, with: picked, renderedFrom: pick.rendered))
        XCTAssertEqual(document.text, "Notes\n![pic](pic.png)\n")
    }

    func testRemoteImageStaysPlaceholder() async throws {
        // A file with the remote image's name sits in the folder: it must still not load.
        try Self.pngData(width: 10, height: 10).write(to: folder.appendingPathComponent("a.png"))
        let text = "![a](https://example.com/a.png)\n\n![b](data:image/png;base64,iVBORw0KGgo=)\n\nEnd\n"
        let document = await preparedDocument(text: text)
        let view = readView(for: document)
        XCTAssertTrue(blockAttachments(in: view).isEmpty, "remote and data: images never load")
        var placeholders = 0
        view.textStorage.enumerateAttribute(.imageReconnect, in: NSRange(location: 0, length: view.textStorage.length)) { value, _, _ in
            if value != nil { placeholders += 1 }
        }
        XCTAssertEqual(placeholders, 2)
        XCTAssertEqual(view.overlayButtons.filter { $0.kind == .reconnect }.count, 2)
    }

    // MARK: - Width changes

    func testWidthChangeKeepsTopParagraph() async throws {
        let paragraphs = (0..<80).map { "Paragraph \($0). " + String(repeating: "Some words that wrap across the column. ", count: 6) }
        let text = paragraphs.joined(separator: "\n\n")
        var starts: [Int] = []
        var location = 0
        for paragraph in paragraphs {
            starts.append(location)
            location += (paragraph as NSString).length + 2
        }
        func paragraph(at sourceLocation: Int) -> Int { starts.lastIndex { $0 <= sourceLocation } ?? 0 }

        let document = await preparedDocument(text: text)
        let view = readView(for: document)
        // Park the page in the middle of paragraph 40.
        view.scrollSourceLocationToTop(starts[40] + 120)
        view.layoutIfNeeded()
        let before = try XCTUnwrap(view.sourceLocationAtTopOfViewport())
        XCTAssertEqual(paragraph(at: before), 40)

        // Rotate to landscape, then back.
        view.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        view.layoutIfNeeded()
        XCTAssertEqual(paragraph(at: try XCTUnwrap(view.sourceLocationAtTopOfViewport())), 40, "landscape")
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        view.layoutIfNeeded()
        XCTAssertEqual(paragraph(at: try XCTUnwrap(view.sourceLocationAtTopOfViewport())), 40, "portrait again")

        // A font-size change rewraps everything: the same paragraph stays at the top.
        var bigger = ReadingProfile.original
        bigger.fontSize += 6
        view.apply(text: text, profile: bigger, documentDirectory: document.documentDirectory)
        view.layoutIfNeeded()
        XCTAssertEqual(paragraph(at: try XCTUnwrap(view.sourceLocationAtTopOfViewport())), 40, "font size")

        // At the very top, the page stays pinned at the top.
        view.contentOffset = CGPoint(x: 0, y: -view.adjustedContentInset.top)
        view.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        view.layoutIfNeeded()
        XCTAssertEqual(view.contentOffset.y, -view.adjustedContentInset.top, accuracy: 0.5)
    }

    func testBlockImageRefitsOnWidthChange() async throws {
        try Self.pngData(width: 1600, height: 400).write(to: folder.appendingPathComponent("wide.png"))
        let document = await preparedDocument(text: "![wide](wide.png)\n\nAfter the picture.\n")
        let view = readView(for: document)
        let attachment = try XCTUnwrap(blockAttachments(in: view).first, "the local image renders")
        let natural = try XCTUnwrap(attachment.image).size
        let profile = ReadingProfile.original

        func expectedWidth(_ width: CGFloat) -> CGFloat {
            min(natural.width, EditorReadingLayout.blockAttachmentFitWidth(forContainerWidth: width, profile: profile))
        }
        XCTAssertEqual(attachment.bounds.width, expectedWidth(393), accuracy: 0.5)

        view.frame = CGRect(x: 0, y: 0, width: 300, height: 700)
        view.layoutIfNeeded()
        XCTAssertEqual(attachment.bounds.width, expectedWidth(300), accuracy: 0.5, "narrower: it shrinks")
        XCTAssertEqual(attachment.bounds.height / attachment.bounds.width, natural.height / natural.width, accuracy: 0.01)

        view.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        view.layoutIfNeeded()
        XCTAssertGreaterThan(attachment.bounds.width, expectedWidth(300), "wider: it grows back")
        XCTAssertLessThanOrEqual(attachment.bounds.width, natural.width + 0.5, "never past its raster")
        XCTAssertLessThanOrEqual(attachment.bounds.height,
                                 ImageFit.maxHeight(visibleViewportHeight: 393) + 0.5, "and never taller than the short page allows")
    }

    // MARK: - Accessibility

    func testAccessibilityActionsMirrorPills() async throws {
        let text = """
        ```
        first
        ```

        ```
        second
        ```

        ![pic](missing.png)

        - [ ] water the plants
        - [x] post the letter
        """
        let document = await preparedDocument(text: text)
        let view = readView(for: document)
        view.pasteboardForTesting = pasteboard

        let actions = view.readAccessibilityActions()
        let names = actions.map(\.name)
        XCTAssertEqual(Array(names.prefix(3)), ["Copy code block 1", "Copy code block 2", "Reconnect image"])
        XCTAssertEqual(names.count, 5)
        XCTAssertTrue(names[3].hasPrefix("Toggle task: ") && names[3].contains("water the plants"), names[3])
        XCTAssertTrue(names[4].hasPrefix("Toggle task: ") && names[4].contains("post the letter"), names[4])
        XCTAssertEqual(Set(names), Set((view.accessibilityCustomActions ?? []).map(\.name)).intersection(names),
                       "the view offers them")

        // Every pill has its action.
        XCTAssertEqual(view.overlayButtons.map(\.accessibilityLabel), ["Copy code block 1", "Copy code block 2", "Reconnect image"])

        XCTAssertEqual(actions[1].actionHandler?(actions[1]), true)
        XCTAssertEqual(pasteboard.string, "second")
        XCTAssertEqual(document.text, text, "copying edits nothing")

        XCTAssertEqual(actions[3].actionHandler?(actions[3]), true)
        XCTAssertTrue(document.text.contains("- [x] water the plants"), "the mirror toggles like a tap")
    }

    // MARK: - Tables

    func testTabStopLocationsMatchColumnPercentages() async throws {
        let text = """
        | Name | Qty | Notes |
        |---|:-:|--:|
        | apple | 1 | crisp and sweet |
        """
        let document = await preparedDocument(text: text)
        let view = readView(for: document)
        let rows: [(cells: [String], isHeader: Bool)] = [(["Name", "Qty", "Notes"], true), (["apple", "1", "crisp and sweet"], false)]
        let percentages = MarkdownPreviewRenderer.fitColumnPercentages(rows: rows, columns: 3)
        let width = EditorReadingLayout.blockAttachmentFitWidth(forContainerWidth: view.bounds.width, profile: .original)
        let columnWidths = percentages.map { $0 / 100 * width }
        let expected: [(NSTextAlignment, CGFloat)] = [
            (.left, 0),
            (.center, columnWidths[0] + columnWidths[1] / 2),
            (.right, columnWidths[0] + columnWidths[1] + columnWidths[2])
        ]

        var rowCount = 0
        view.textStorage.enumerateAttribute(.markdownTableRow, in: NSRange(location: 0, length: view.textStorage.length)) { value, range, _ in
            guard value != nil else { return }
            rowCount += 1
            let style = view.textStorage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let stops = style?.tabStops ?? []
            XCTAssertEqual(stops.count, 3)
            for (stop, (alignment, location)) in zip(stops, expected) {
                XCTAssertEqual(stop.alignment, alignment)
                XCTAssertEqual(stop.location, location, accuracy: 0.5)
            }
            // A left first column needs no leading tab; the cells are tab-separated.
            let row = (view.textStorage.string as NSString).substring(with: range)
            XCTAssertFalse(row.hasPrefix("\t"))
            XCTAssertEqual(row.components(separatedBy: "\t").count, 3)
        }
        XCTAssertEqual(rowCount, 2)

        // The hairline grid: a line above the header and under each row, and two inner column edges.
        let grid = try XCTUnwrap(view.state.tableGridView)
        var moves = 0
        view.tableGridPath().cgPath.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { moves += 1 }
        }
        XCTAssertEqual(moves, 3 + 2)
        let theme = Theme.theme(for: .original)
        let ink = theme.readableInk(theme.textColor.withAlphaComponent(0.15), minimumRatio: 1.5)
        XCTAssertEqual(grid.shapeLayer.strokeColor.map { UIColor(cgColor: $0) }, ink)
        XCTAssertTrue(grid === view.subviews.first, "the grid sits behind the text")
    }

    func testTableGridEdgesFollowColumnFractions() async throws {
        // A long right-aligned cell (one that still fits its column) after a centred column: an
        // edge halfway between the two stops would cut through it.
        let text = """
        | Item | Qty | Description |
        |---|:-:|--:|
        | apple | 1 | crisp and sweet |
        | pear | 12 | soft |
        """
        let document = await preparedDocument(text: text)
        let view = readView(for: document)
        let rows: [(cells: [String], isHeader: Bool)] = [
            (["Item", "Qty", "Description"], true),
            (["apple", "1", "crisp and sweet"], false),
            (["pear", "12", "soft"], false)
        ]
        let fractions = MarkdownPreviewRenderer.fitColumnPercentages(rows: rows, columns: 3).map { $0 / 100 }
        let fitWidth = EditorReadingLayout.blockAttachmentFitWidth(forContainerWidth: view.bounds.width, profile: .original)
        let originX = view.textContainerInset.left
        let expectedEdges = [fractions[0] * fitWidth, (fractions[0] + fractions[1]) * fitWidth]
        XCTAssertEqual(LineformReadView.columnEdges(fractions: fractions, fitWidth: fitWidth).count, 2)
        for (edge, expected) in zip(LineformReadView.columnEdges(fractions: fractions, fitWidth: fitWidth), expectedEdges) {
            XCTAssertEqual(edge, expected, accuracy: 0.01)
        }

        // The path: horizontal row lines end at the fit width; vertical lines at the edges.
        var segments: [(CGPoint, CGPoint)] = []
        var start = CGPoint.zero
        view.tableGridPath().cgPath.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint: start = element.pointee.points[0]
            case .addLineToPoint: segments.append((start, element.pointee.points[0]))
            default: break
            }
        }
        let horizontal = segments.filter { abs($0.0.y - $0.1.y) < 0.01 }
        let vertical = segments.filter { abs($0.0.x - $0.1.x) < 0.01 }
        XCTAssertEqual(horizontal.count, 4, "above the header and under each of three rows")
        for line in horizontal {
            XCTAssertEqual(line.0.x, originX, accuracy: 0.01)
            XCTAssertEqual(line.1.x, originX + fitWidth, accuracy: 0.5, "the row lines end at the fit width")
        }
        XCTAssertEqual(vertical.map { $0.0.x - originX }.sorted().count, 2)
        for (line, expected) in zip(vertical.sorted { $0.0.x < $1.0.x }, expectedEdges) {
            XCTAssertEqual(line.0.x - originX, expected, accuracy: 0.5)
        }

        // No edge falls inside any cell's glyphs.
        let storage = view.textStorage
        let string = storage.string as NSString
        var cellRects: [(String, CGRect)] = []
        storage.enumerateAttribute(.markdownTableRow, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            var location = range.location
            let end = NSMaxRange(range)
            while location < end {
                var cellEnd = location
                while cellEnd < end, string.character(at: cellEnd) != 9, string.character(at: cellEnd) != 10 { cellEnd += 1 }
                if cellEnd > location {
                    let cell = NSRange(location: location, length: cellEnd - location)
                    let glyphs = view.layoutManager.glyphRange(forCharacterRange: cell, actualCharacterRange: nil)
                    view.layoutManager.enumerateEnclosingRects(
                        forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                        in: view.textContainer
                    ) { rect, _ in
                        cellRects.append((string.substring(with: cell), rect.offsetBy(dx: originX, dy: 0)))
                    }
                }
                location = cellEnd + 1
            }
        }
        XCTAssertEqual(cellRects.count, 9, "every cell on one line (a wrapped cell crosses any grid)")
        // The old midpoint rule would have cut the long right-aligned cell.
        let stops = (storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.tabStops ?? []
        XCTAssertEqual(stops.count, 3)
        let midpoint = originX + (stops[1].location + stops[2].location) / 2
        let longCell = try XCTUnwrap(cellRects.first { $0.0 == "crisp and sweet" }).1
        XCTAssertTrue(midpoint > longCell.minX && midpoint < longCell.maxX, "set-up: the case the fix is for")
        for line in vertical {
            for (cell, rect) in cellRects {
                XCTAssertFalse(line.0.x > rect.minX + 0.5 && line.0.x < rect.maxX - 0.5,
                               "an edge at \(line.0.x) cuts through \"\(cell)\" (\(rect.minX)…\(rect.maxX))")
            }
        }
    }

    func testHorizontalRuleLaysOutInReadView() async throws {
        let document = await preparedDocument(text: "a\n\n---\n\nb")
        let view = readView(for: document)
        XCTAssertNil(view.textLayoutManager, "TextKit 1: the rule attachment draws there")
        view.layoutManager.ensureLayout(for: view.textContainer)
        var ruleRange: NSRange?
        view.textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.textStorage.length)) { value, range, stop in
            if value is HorizontalRuleAttachment {
                ruleRange = range
                stop.pointee = true
            }
        }
        let range = try XCTUnwrap(ruleRange, "the rule is rendered")
        let glyphs = view.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = view.layoutManager.boundingRect(forGlyphRange: glyphs, in: view.textContainer)
        XCTAssertGreaterThan(view.textContainer.size.width, 100, "laid out at the column width")
        XCTAssertGreaterThan(rect.width, 0, "the rule has a width")
        XCTAssertGreaterThan(rect.height, 0, "the rule has a height")
        XCTAssertLessThanOrEqual(rect.maxX, view.textContainer.size.width + 0.5)
    }

    func testLongTableCellLaysOutAtNarrowWidth() {
        let longCell = String(repeating: "a long table cell that never stops ", count: 60)
        let text = "| Key | Value |\n|---|---|\n| one | \(longCell) |\n| two | short |\n"
        let rendered = MarkdownPreviewRenderer().render(
            text,
            profile: .original,
            columnWidth: 320,
            mermaidProvider: DisabledMermaidImageProvider(),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            appVersion: "0",
            displayMetrics: RenderDisplayMetrics(scale: 3, visibleViewportHeight: 852)
        )
        for width in [CGFloat(1), 320] {
            let storage = NSTextStorage(attributedString: rendered)
            let layoutManager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            storage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            XCTAssertGreaterThan(layoutManager.numberOfGlyphs, 0, "width \(width)")
            XCTAssertTrue(used.height.isFinite && used.height > 0, "width \(width) lays out")
            XCTAssertEqual(layoutManager.firstUnlaidCharacterIndex(), storage.length, "width \(width) lays out every character")
        }
    }

    // MARK: - Position

    func testScrollRequestWaitsForSizeAndTopIsReported() async throws {
        let paragraphs = (0..<60).map { "Line \($0) with a little text." }
        let text = paragraphs.joined(separator: "\n\n")
        let document = await preparedDocument(text: text)
        let target = (text as NSString).range(of: "Line 30 ").location

        let view = LineformReadView.make()
        var reported: [Int] = []
        configure(view, for: document, onVisibleTop: { reported.append($0) })
        // Asked before the view has a window or a size: it waits.
        view.scrollSourceLocationToTop(target)
        host(view)
        view.layoutIfNeeded()
        XCTAssertEqual(view.sourceLocationAtTopOfViewport().map { ($0 - target) < 40 && $0 >= target - 2 }, true,
                       "applied once the view was sized")

        // The top is reported 0.08 s after scrolling stops.
        reported.removeAll()
        view.contentOffset.y += 200
        view.delegate?.scrollViewDidScroll?(view)
        XCTAssertTrue(reported.isEmpty, "not at once")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(reported, [try XCTUnwrap(view.sourceLocationAtTopOfViewport())])
    }

    // MARK: - Construction and the screen

    func testFactoryPathHasEveryDefault() {
        let view = LineformReadView(usingTextLayoutManager: false)
        XCTAssertNil(view.textLayoutManager, "TextKit 1, like the Mac's Read view")
        XCTAssertNil(view.renderedSourceText)
        XCTAssertNil(view.lastRenderMetrics)
        XCTAssertNil(view.undoManagerProvider)
        XCTAssertNil(view.onFirstRender)
        XCTAssertTrue(view.overlayButtons.isEmpty)
        XCTAssertNil(view.onVisibleTopSourceLocationChanged)

        let made = LineformReadView.make()
        XCTAssertFalse(made.isEditable)
        XCTAssertTrue(made.isSelectable)
        XCTAssertEqual(made.textContainerInset.top, 32)
        XCTAssertEqual(made.backgroundColor, Theme.theme(for: .original).backgroundColor)
    }

    func testDocumentScreenShowsReadView() async throws {
        let document = await preparedDocument(text: "# Title\n\n- [ ] task\n")
        let suite = "ReadViewTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReadingProfileStore(defaults: defaults)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: DocumentScreen(document: document, profileStore: store, initialMode: .read))
        window.isHidden = false
        self.window = window
        var readView: LineformReadView?
        let deadline = Date().addingTimeInterval(5)
        while readView?.renderedSourceText == nil, Date() < deadline {
            window.layoutIfNeeded()
            readView = Self.find(LineformReadView.self, in: window)
            try await Task.sleep(for: .milliseconds(50))
        }
        let view = try XCTUnwrap(readView)
        // The editor stays under the Read view (Write keeps its undo history), covered and out of
        // reach of touch and VoiceOver.
        let editor = try XCTUnwrap(Self.find(LineformTextView.self, in: window))
        XCTAssertEqual(view.convert(view.bounds, to: window), editor.convert(editor.bounds, to: window),
                       "Read covers the whole page")
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertEqual(view.renderedSourceText, document.text)
        let range = try XCTUnwrap(checkboxRanges(in: view).first)
        let rect = try XCTUnwrap(view.checkboxGlyphRect(forSourceRange: range))
        view.activateCheckbox(at: CGPoint(x: rect.midX, y: rect.midY))
        XCTAssertEqual(document.text, "# Title\n\n- [x] task\n", "the screen's toggle goes through the document")
    }

    // MARK: - Helpers

    private func preparedDocument(text: String) async -> OpenDocument {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: ReadTestUbiquitousItems())
        await document.prepare()
        document.edit(text)
        await document.flush()
        return document
    }

    /// A Read view in a portrait-sized window, wired to `document` the way `DocumentScreen` wires it.
    private func readView(
        for document: OpenDocument,
        editor: LineformTextView? = nil,
        onImageReconnect: @escaping (NSRange, String?) -> Void = { _, _ in }
    ) -> LineformReadView {
        let view = LineformReadView.make()
        host(view)
        configure(view, for: document, editor: editor, onImageReconnect: onImageReconnect)
        view.layoutIfNeeded()
        return view
    }

    private func configure(
        _ view: LineformReadView,
        for document: OpenDocument,
        editor: LineformTextView? = nil,
        onImageReconnect: @escaping (NSRange, String?) -> Void = { _, _ in },
        onVisibleTop: ((Int) -> Void)? = nil
    ) {
        ReadViewRepresentable(
            text: document.text,
            profile: .original,
            documentDirectory: document.documentDirectory,
            onCheckboxToggle: { range, renderedFrom in document.toggleCheckbox(at: range, renderedFrom: renderedFrom) },
            onImageReconnect: onImageReconnect,
            onVisibleTopSourceLocationChanged: onVisibleTop,
            undoManager: { [weak editor] in editor?.undoManager }
        ).configure(view)
    }

    /// The editor `DocumentScreen` keeps mounted under Read, wired to `document` the same way: it
    /// applies the Read edits, with its own undo. Hidden behind the Read view.
    private var editorCoordinators: [MarkdownEditor.Coordinator] = []

    private func attachedEditor(for document: OpenDocument) -> LineformTextView {
        let editor = LineformTextView.make()
        let coordinator = editorRepresentable(for: document).makeCoordinator()
        editorCoordinators.append(coordinator)
        editor.setDocumentText(document.text)
        editor.delegate = coordinator
        syncEditor(editor, to: document)
        host(editor)
        editor.isHidden = true
        return editor
    }

    private func syncEditor(_ editor: LineformTextView, to document: OpenDocument) {
        editorRepresentable(for: document).configure(editor)
    }

    private func editorRepresentable(for document: OpenDocument) -> MarkdownEditor {
        MarkdownEditor(
            text: Binding(get: { document.text }, set: { document.edit($0) }),
            profile: .original,
            imageHost: nil,
            readEditDocument: document
        )
    }

    private func host(_ view: UIView) {
        let window = self.window ?? {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.rootViewController = UIViewController()
            window.isHidden = false
            self.window = window
            return window
        }()
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        window.rootViewController?.view.addSubview(view)
        view.layoutIfNeeded()
    }

    private func blockAttachments(in view: LineformReadView) -> [BlockRenderedAttachment] {
        var found: [BlockRenderedAttachment] = []
        view.textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.textStorage.length)) { value, _, _ in
            if let attachment = value as? BlockRenderedAttachment { found.append(attachment) }
        }
        return found
    }

    private func checkboxRanges(in view: LineformReadView) -> [NSRange] {
        var ranges: [NSRange] = []
        view.textStorage.enumerateAttribute(.checkboxSourceRange, in: NSRange(location: 0, length: view.textStorage.length)) { value, _, _ in
            if let value = value as? NSValue { ranges.append(value.rangeValue) }
        }
        return ranges
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    private static func pngData(width: CGFloat, height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.pngData() ?? Data()
    }
}

/// Every file is local and current; real iCloud is never asked.
private struct ReadTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}
