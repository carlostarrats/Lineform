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
