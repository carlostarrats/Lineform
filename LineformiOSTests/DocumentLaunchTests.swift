import UIKit
import XCTest
@testable import LineformiOS

/// The hosted app's own launch: a fresh launch shows one empty, editable document that fills the
/// window.
@MainActor
final class DocumentLaunchTests: XCTestCase {
    func testFreshLaunchShowsEmptyDocument() throws {
        let textView = try XCTUnwrap(waitForEditor(), "the launched app shows no editor")
        XCTAssertEqual(textView.text, "")
        XCTAssertTrue(textView.isEditable)
        XCTAssertNil(textView.textLayoutManager)
        let window = try XCTUnwrap(textView.window)
        let frame = textView.convert(textView.bounds, to: window)
        XCTAssertEqual(frame.width, window.bounds.width, "the document spans the window's width")
        XCTAssertEqual(frame.minY, window.bounds.minY, "no bar sits above the document")
    }

    private func waitForEditor(timeout: TimeInterval = 5) -> EditorTextView? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = Self.editors().first { return found }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return nil
    }

    private static func editors() -> [EditorTextView] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .flatMap { find(in: $0) }
    }

    private static func find(in view: UIView) -> [EditorTextView] {
        if let editor = view as? EditorTextView { return [editor] }
        return view.subviews.flatMap { find(in: $0) }
    }
}
