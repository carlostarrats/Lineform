import XCTest
@testable import Lineform

final class ImageInsertionTextTests: XCTestCase {

    // MARK: - insertingOnLine (drop on a line / paste — unchanged behavior)

    func testInsertingOnLineSnapsToLineStartAndPushesLineDown() {
        let edit = ImageInsertionText.insertingOnLine(into: "line1\nline2", at: 8, path: "images/p.png")
        // Index 8 is inside "line2" (starts at 6) → snaps to that line's start (6).
        XCTAssertEqual(edit.location, 6)
        XCTAssertEqual(edit.snippet, "![](images/p.png)\n")
        XCTAssertEqual(edit.applied(to: "line1\nline2"), "line1\n![](images/p.png)\nline2")
    }

    func testInsertingOnLineIntoEmptyDocument() {
        let edit = ImageInsertionText.insertingOnLine(into: "", at: 0, path: "p.png")
        XCTAssertEqual(edit.location, 0)
        XCTAssertEqual(edit.applied(to: ""), "![](p.png)\n")
        XCTAssertEqual(edit.caret, ("![](p.png)\n" as NSString).length)
    }

    // MARK: - appendingAtEnd (drop BELOW the last line — the bug being fixed)

    func testAppendingBelowTrailingImageWithoutNewlineAddsLeadingNewline() {
        // Document whose last (and only) line is an image, no trailing newline. Dropping below it
        // must place the new image AFTER it, not snap above it.
        let edit = ImageInsertionText.appendingAtEnd(into: "![](a.png)", path: "b.png")
        XCTAssertEqual(edit.location, ("![](a.png)" as NSString).length)
        XCTAssertEqual(edit.snippet, "\n![](b.png)\n")
        XCTAssertEqual(edit.applied(to: "![](a.png)"), "![](a.png)\n![](b.png)\n")
    }

    func testAppendingBelowTrailingImageWithNewlineDoesNotDoubleTheNewline() {
        let edit = ImageInsertionText.appendingAtEnd(into: "![](a.png)\n", path: "b.png")
        XCTAssertEqual(edit.location, ("![](a.png)\n" as NSString).length)
        XCTAssertEqual(edit.snippet, "![](b.png)\n")
        XCTAssertEqual(edit.applied(to: "![](a.png)\n"), "![](a.png)\n![](b.png)\n")
    }

    func testAppendingBelowTextParagraphPutsImageOnItsOwnLine() {
        let edit = ImageInsertionText.appendingAtEnd(into: "Hello world", path: "b.png")
        XCTAssertEqual(edit.applied(to: "Hello world"), "Hello world\n![](b.png)\n")
    }

    func testAppendedImageComesAfterTheExistingImage() {
        // The literal statement of the bug: the new reference must appear AFTER the existing one.
        let result = ImageInsertionText.appendingAtEnd(into: "![](first.png)", path: "second.png")
            .applied(to: "![](first.png)")
        let firstRange = (result as NSString).range(of: "first.png")
        let secondRange = (result as NSString).range(of: "second.png")
        XCTAssertLessThan(firstRange.location, secondRange.location)
    }
}
