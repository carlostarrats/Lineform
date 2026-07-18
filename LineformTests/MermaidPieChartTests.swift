import XCTest
import AppKit
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
}
