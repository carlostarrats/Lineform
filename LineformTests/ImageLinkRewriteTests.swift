import XCTest
@testable import Lineform

final class ImageLinkRewriteTests: XCTestCase {

    // MARK: - rewritten(in:at:newPath:)

    func testRewriteReplacesPathPreservingAlt() {
        let text = "![cat](old.png)"
        let range = NSRange(location: 0, length: (text as NSString).length)
        let result = ImageLinkRewrite.rewritten(in: text, at: range, newPath: "new.png")
        XCTAssertEqual(result, "![cat](new.png)")
    }

    func testRewritePreservesSurroundingWhitespace() {
        let text = "  ![a](x.png)  "
        let range = NSRange(location: 0, length: (text as NSString).length)
        let result = ImageLinkRewrite.rewritten(in: text, at: range, newPath: "y.png")
        XCTAssertEqual(result, "  ![a](y.png)  ")
    }

    func testRewriteStaleRangeReturnsNil() {
        let text = "hello world"
        let range = NSRange(location: 0, length: (text as NSString).length)
        let result = ImageLinkRewrite.rewritten(in: text, at: range, newPath: "new.png")
        XCTAssertNil(result)
    }

    func testRewriteEmptyAltPreserved() {
        let text = "![](a.png)"
        let range = NSRange(location: 0, length: (text as NSString).length)
        let result = ImageLinkRewrite.rewritten(in: text, at: range, newPath: "b.png")
        XCTAssertEqual(result, "![](b.png)")
    }

    func testRewriteOutOfBoundsRangeReturnsNil() {
        let text = "![cat](old.png)"
        let range = NSRange(location: 0, length: (text as NSString).length + 10)
        let result = ImageLinkRewrite.rewritten(in: text, at: range, newPath: "new.png")
        XCTAssertNil(result)
    }

    // MARK: - linkPath(for:documentDirectory:)

    func testLinkPathRelativeWhenUnderDocumentDirectory() {
        let dir = URL(fileURLWithPath: "/Users/test/Documents/Project")
        let picked = dir.appendingPathComponent("img/pic.png")
        let result = ImageLinkRewrite.linkPath(for: picked, documentDirectory: dir)
        XCTAssertEqual(result, "img/pic.png")
    }

    func testLinkPathAbsoluteWhenOutsideDocumentDirectory() {
        let dir = URL(fileURLWithPath: "/Users/test/Documents/Project")
        let picked = URL(fileURLWithPath: "/elsewhere/pic.png")
        let result = ImageLinkRewrite.linkPath(for: picked, documentDirectory: dir)
        XCTAssertEqual(result, "/elsewhere/pic.png")
    }

    func testLinkPathAbsoluteWhenNilDirectory() {
        let picked = URL(fileURLWithPath: "/elsewhere/pic.png")
        let result = ImageLinkRewrite.linkPath(for: picked, documentDirectory: nil)
        XCTAssertEqual(result, "/elsewhere/pic.png")
    }
}
