import XCTest
@testable import Lineform

/// The "a new construct without a protection rule fails" gate. `MarkdownStructureMap`'s
/// `protection(of:)` switches are exhaustive with no `default`, so a new `MarkdownTokenKind` or
/// `MarkdownBlock` case stops the BUILD; these tests pin what each existing case is classified as.
final class MarkdownStructureInventoryTests: XCTestCase {
    func testEveryTokenKindIsClassified() {
        for kind in MarkdownTokenKind.allCases {
            let expected: MarkdownStructureMap.TokenProtection = kind == .linkText ? .prose : .structure
            XCTAssertEqual(MarkdownStructureMap.protection(of: kind), expected, kind.rawValue)
        }
        XCTAssertEqual(MarkdownTokenKind.allCases.count, 10)
        XCTAssertEqual(MarkdownStructureMap.protection(of: .imageText), .structure)
    }

    func testEveryBlockKindIsClassified() {
        let fixture = """
        Paragraph line

        $$x = 1$$

        $$
        y = 2
        $$

        ```mermaid
        graph TD
        A-->B
        ```

        ---

        > quoted

        > [!NOTE] Title
        > body

        - item

        | a | b |
        |---|---|
        | 1 | 2 |

        ```swift
        let z = 3
        ```

        ![alt](image.png)
        """
        let source = markdownSourceLines(in: fixture)
        let blocks = markdownBlocks(in: source.lines, lineRanges: source.ranges)

        var seen: Set<String> = []
        for block in blocks {
            // Exhaustive on purpose: a new block case must be added here AND classified.
            let name: String
            let expected: MarkdownStructureMap.BlockProtection
            switch block {
            case .lines: name = "lines"; expected = .markersOnly
            case .singleLineMath: name = "singleLineMath"; expected = .whole
            case .fencedMath: name = "fencedMath"; expected = .whole
            case .mermaid: name = "mermaid"; expected = .whole
            case .horizontalRule: name = "horizontalRule"; expected = .whole
            case .blockquote: name = "blockquote"; expected = .markersOnly
            case .callout: name = "callout"; expected = .markersOnly
            case .list: name = "list"; expected = .markersOnly
            case .table: name = "table"; expected = .markersOnly
            case .fencedCode: name = "fencedCode"; expected = .whole
            case .image: name = "image"; expected = .whole
            }
            seen.insert(name)
            XCTAssertEqual(MarkdownStructureMap.protection(of: block), expected, name)
        }
        XCTAssertEqual(seen, [
            "lines", "singleLineMath", "fencedMath", "mermaid", "horizontalRule", "blockquote",
            "callout", "list", "table", "fencedCode", "image",
        ])

        // And every whole block contributes no prose at all.
        XCTAssertEqual(
            MarkdownStructureMap.proseSegments(in: fixture, selection: NSRange(location: 0, length: (fixture as NSString).length)).map(\.text),
            ["Paragraph line", "quoted", "Title", "body", "item", "a", "b", "1", "2"]
        )
    }
}
