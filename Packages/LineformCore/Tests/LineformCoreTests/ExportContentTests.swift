import XCTest
@testable import LineformCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The export content both apps write: the Styled render, the Normal raw source, RTF and HTML.
/// Runs on macOS and iOS, so the iPhone exporter and the Mac produce the same document content.
@MainActor
final class ExportContentTests: XCTestCase {
    private func styled(_ text: String) -> NSAttributedString {
        ExportContent.styled(
            text: text,
            profile: .original,
            paper: .usLetter,
            preset: .styled,
            documentDirectory: nil,
            imageProvider: DisabledImageAttachmentProvider(),
            appVersion: "test",
            displayMetrics: RenderDisplayMetrics(scale: 2, visibleViewportHeight: 648)
        )
    }

    func testRawSourceKeepsMarkersVerbatim() throws {
        let source = "# Title\n**b**"
        let raw = ExportContent.rawSource(text: source, preset: .standard)
        XCTAssertEqual(raw.string, source)
        let font = try XCTUnwrap(raw.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)
        XCTAssertEqual(font.pointSize, 10)
        #if os(macOS)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
        #else
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        #endif
        let paragraph = try XCTUnwrap(raw.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.lineHeightMultiple, 1.2)
        let ink = try XCTUnwrap(raw.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? PlatformColor)
        XCTAssertEqual(ink, DiagramPalette.ink(isDark: false))
    }

    func testStyledStripsMarkersAndKeepsWords() {
        let rendered = styled("# Title\n\nSome **bold** words.").string
        XCTAssertTrue(rendered.contains("Title"))
        XCTAssertTrue(rendered.contains("bold"))
        XCTAssertFalse(rendered.contains("#"))
        XCTAssertFalse(rendered.contains("**"))
    }

    func testStyledCodeIsMonochrome() throws {
        let rendered = styled("Body text.\n\n```swift\nlet answer = \"forty-two\" // note\nfunc f() {}\n```")
        let string = rendered.string as NSString
        let bodyInk = try XCTUnwrap(rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? PlatformColor)
        let codeStart = string.range(of: "let answer").location
        let codeEnd = NSMaxRange(string.range(of: "func f() {}"))
        XCTAssertNotEqual(codeStart, NSNotFound)
        var colors: [PlatformColor] = []
        rendered.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: codeStart, length: codeEnd - codeStart)
        ) { value, _, _ in
            if let color = value as? PlatformColor { colors.append(color) }
        }
        XCTAssertFalse(colors.isEmpty)
        for color in colors {
            XCTAssertEqual(color, bodyInk, "exported code must stay monochrome")
        }
    }

    func testRTFMathBecomesCaptionAndSource() throws {
        let attributed = ExportContent.rtfAttributedString(
            text: "Before\n\n$$x^2$$\n\nAfter", profile: .original, paper: .usLetter, preset: .styled, appVersion: "test"
        )
        XCTAssertTrue(attributed.string.contains("x^2"))
        var attachments = 0
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(attachments, 0)

        let data = try ExportContent.rtfData(
            text: "Before\n\n$$x^2$$\n\nAfter", profile: .original, paper: .usLetter, preset: .styled, appVersion: "test"
        )
        XCTAssertTrue(data.starts(with: Data("{\\rtf".utf8)))
    }

    /// A bare `)` ends a Markdown destination, so `p (1).png` is written the way the app writes
    /// it (`ImageLinkRewrite.markdownDestination`); the HTML must carry that destination exactly
    /// as written — never decoded, resolved or rewritten.
    func testHTMLTitleAndOneToOnePaths() {
        let destination = ImageLinkRewrite.markdownDestination(for: "images/p (1).png")
        XCTAssertNotEqual(destination, "images/p (1).png", "the destination must be escaped to parse")
        let html = String(decoding: ExportContent.htmlData(text: "![a](\(destination))", title: "Doc"), as: UTF8.self)
        XCTAssertTrue(html.contains("<title>Doc</title>"))
        XCTAssertTrue(html.contains("src=\"\(destination)\""), html)
    }

    func testHTMLMathEmbedsPNG() {
        let html = String(decoding: ExportContent.htmlData(text: "$$x^2$$", title: "Doc"), as: UTF8.self)
        XCTAssertTrue(html.contains("data:image/png;base64,"))
    }
}
