import XCTest
@testable import Lineform

final class EditorDisplayModeTests: XCTestCase {
    func testDisplayModesStaySmallAndOrdered() {
        XCTAssertEqual(EditorDisplayMode.allCases, [.write, .preview, .split])
        XCTAssertEqual(EditorDisplayMode.allCases.map(\.title), ["Write", "Preview", "Split"])
    }
}
