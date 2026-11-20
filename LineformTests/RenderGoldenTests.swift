import XCTest
import AppKit
import CryptoKit
@testable import Lineform
@testable import LineformCore

/// Pins the Mac Markdown renderer's output (attributes and pixels) before the renderer moves into
/// `LineformCore`. The golden is recorded once and never re-recorded by the platform-layer plan:
/// a mismatch means the move changed what a Mac user sees.
///
/// - `golden.txt` line 1 is the macOS version it was recorded on, line 2 the main screen's
///   backing scale (the renderer reads `NSScreen.main` for diagram, math and image rasters).
///   On any other OS or scale both tests skip, so CI on a different macOS stays honest instead
///   of red, and the local gate stays strict.
/// - Record with `TEST_RUNNER_RECORD_RENDER_GOLDEN=1 xcodebuild test …` (xcodebuild strips the
///   prefix, the test sees `RECORD_RENDER_GOLDEN=1`). The Debug test host is sandboxed, so it
///   cannot write the source tree: it writes the app container's `tmp/golden.txt`
///   (`~/Library/Containers/com.lineform.app.debug/Data/tmp/`) and fails with that path; copy
///   it to `LineformTests/Fixtures/render-golden/golden.txt`.
/// - No network: the corpus has no remote image, and the providers only rasterize locally.
@MainActor
final class RenderGoldenTests: XCTestCase {
    private static let columnWidth: CGFloat = 680
    private static let pixelScale: CGFloat = 2
    private static let osLinePrefix = "os: "
    private static let scaleLinePrefix = "screen-scale: "
    private static let hashLinePrefix = "pixels "

    // MARK: - Tests

    func testRenderedAttributesMatchGolden() throws {
        if try recordIfRequested() { return }
        let golden = try loadGolden()
        let actual = Self.cases.map { renderCase in
            Self.attributeSection(for: renderCase, text: render(renderCase))
        }.joined()
        let expected = golden.lines.filter { !$0.hasPrefix(Self.hashLinePrefix) }.joined(separator: "\n") + "\n"
        if actual != expected {
            XCTFail("Rendered attributes differ from golden.txt.\n\(Self.firstDifference(expected, actual))")
        }
    }

    func testRenderedPixelsMatchGolden() throws {
        if try recordIfRequested() { return }
        let golden = try loadGolden()
        let expected = golden.lines.filter { $0.hasPrefix(Self.hashLinePrefix) }
        let actual = Self.cases.map { renderCase in
            Self.hashLine(for: renderCase, text: render(renderCase))
        }
        XCTAssertEqual(expected.count, Self.cases.count, "golden.txt has the wrong number of pixel hash lines")
        for (expectedLine, actualLine) in zip(expected, actual) {
            XCTAssertEqual(actualLine, expectedLine, "pixel hash differs")
        }
    }

    // MARK: - Cases

    private struct RenderCase {
        var name: String
        var profile: ReadingProfile
        var fitTablesToWidth = false
        var imagesAsText = false
        var highlightsCode = true
        var headingScale: CGFloat = 1.0
    }

    private static var cases: [RenderCase] {
        var cases: [RenderCase] = Theme.builtIn.map { theme in
            var profile = ReadingProfile.original
            profile.themeID = theme.id
            return RenderCase(name: "theme-\(theme.id.rawValue)", profile: profile)
        }
        var highContrast = ReadingProfile.original
        highContrast.highContrastEnabled = true
        cases.append(RenderCase(name: "high-contrast", profile: highContrast))
        for font in [FontID.newYork, .openDyslexic] {
            var profile = ReadingProfile.original
            profile.fontID = font
            cases.append(RenderCase(name: "font-\(font.rawValue)", profile: profile))
        }
        cases.append(RenderCase(
            name: "export-fit-mono-scale1.2",
            profile: .original,
            fitTablesToWidth: true,
            highlightsCode: false,
            headingScale: 1.2
        ))
        cases.append(RenderCase(name: "export-images-as-text", profile: .original, imagesAsText: true))
        return cases
    }

    private func render(_ renderCase: RenderCase) -> NSAttributedString {
        // Fresh real providers per render, so no case reads another case's cache.
        MarkdownPreviewRenderer().render(
            Self.corpus,
            profile: renderCase.profile,
            columnWidth: Self.columnWidth,
            mermaidProvider: MermaidImageProvider(),
            mathProvider: MathImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            appVersion: "0",
            fitTablesToWidth: renderCase.fitTablesToWidth,
            imagesAsText: renderCase.imagesAsText,
            highlightsCode: renderCase.highlightsCode,
            documentDirectory: Self.fixtureDirectory,
            imageProvider: ImageAttachmentProvider(),
            headingScale: renderCase.headingScale
        )
    }

    // MARK: - Golden file

    private static var fixtureDirectory: URL {
        Bundle(for: RenderGoldenTests.self).resourceURL!
            .appendingPathComponent("Fixtures/render-golden", isDirectory: true)
    }

    private static var sourceGoldenURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/render-golden/golden.txt")
    }

    private static var corpus: String {
        let url = fixtureDirectory.appendingPathComponent("corpus.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fatalError("render-golden corpus missing from the test bundle at \(url.path)")
        }
        return text
    }

    private static var osLine: String { osLinePrefix + ProcessInfo.processInfo.operatingSystemVersionString }
    private static var scaleLine: String {
        scaleLinePrefix + String(format: "%.1f", NSScreen.main?.backingScaleFactor ?? 2)
    }

    private struct Golden { var lines: [String] }

    /// Reads the golden from the test bundle, skipping when it was recorded on another OS or
    /// screen scale. Returns every line after the two header lines.
    private func loadGolden() throws -> Golden {
        let url = Self.fixtureDirectory.appendingPathComponent("golden.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count > 2 else { throw XCTSkip("golden.txt is empty; record it with RECORD_RENDER_GOLDEN=1") }
        let recordedOS = String(lines[0].dropFirst(Self.osLinePrefix.count))
        if lines[0] != Self.osLine {
            throw XCTSkip("golden recorded on \(recordedOS); re-record on that OS")
        }
        if lines[1] != Self.scaleLine {
            throw XCTSkip("golden recorded at \(lines[1]), this Mac's main screen is \(Self.scaleLine); run on a display at the recorded scale")
        }
        return Golden(lines: Array(lines.dropFirst(2)))
    }

    /// With `RECORD_RENDER_GOLDEN=1`, writes the full golden (both tests' sections) once per
    /// process and returns true. Otherwise returns false.
    private static var didRecord = false
    private func recordIfRequested() throws -> Bool {
        guard ProcessInfo.processInfo.environment["RECORD_RENDER_GOLDEN"] == "1" else { return false }
        if Self.didRecord { return true }
        var output = Self.osLine + "\n" + Self.scaleLine + "\n"
        for renderCase in Self.cases {
            let text = render(renderCase)
            output += Self.attributeSection(for: renderCase, text: text)
            output += Self.hashLine(for: renderCase, text: text) + "\n"
        }
        do {
            try output.write(to: Self.sourceGoldenURL, atomically: true, encoding: .utf8)
            print("[render-golden] recorded \(Self.sourceGoldenURL.path)")
        } catch {
            // The sandboxed test host may not write into the source tree; leave it in the
            // container and fail with the path so it can be copied by hand.
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("golden.txt")
            try output.write(to: fallback, atomically: true, encoding: .utf8)
            XCTFail("[render-golden] could not write the source fixture (\(error.localizedDescription)); wrote \(fallback.path)")
        }
        Self.didRecord = true
        return true
    }

    private static func attributeSection(for renderCase: RenderCase, text: NSAttributedString) -> String {
        var section = "## case \(renderCase.name)\n"
        section += RenderFingerprint.describe(text)
            .replacingOccurrences(of: fixtureDirectory.path, with: "<fixtures>")
        return section
    }

    private static func hashLine(for renderCase: RenderCase, text: NSAttributedString) -> String {
        let theme = Theme.theme(for: renderCase.profile)
        return hashLinePrefix + renderCase.name + " " + RenderPixels.sha256(
            of: text,
            width: columnWidth,
            scale: pixelScale,
            background: theme.backgroundColor,
            dark: theme.usesDarkChrome
        )
    }

    private static func firstDifference(_ expected: String, _ actual: String) -> String {
        let expectedLines = expected.components(separatedBy: "\n")
        let actualLines = actual.components(separatedBy: "\n")
        for index in 0..<max(expectedLines.count, actualLines.count) {
            let expectedLine = index < expectedLines.count ? expectedLines[index] : "<end>"
            let actualLine = index < actualLines.count ? actualLines[index] : "<end>"
            if expectedLine != actualLine {
                return "First difference at line \(index + 3) of golden.txt:\n  expected: \(expectedLine)\n  actual:   \(actualLine)"
            }
        }
        return "(no line differs; trailing newline only)"
    }
}

// MARK: - Attribute fingerprint

/// A stable, human-readable dump of an attributed string: one line per attribute run. The
/// enumeration uses longest effective ranges (the default; `.longestEffectiveRangeNotRequired`
/// is not passed), so the dump does not depend on how the string was assembled.
enum RenderFingerprint {
    static func describe(_ text: NSAttributedString) -> String {
        var output = ""
        let whole = NSRange(location: 0, length: text.length)
        let string = text.string as NSString
        text.enumerateAttributes(in: whole, options: []) { attributes, range, _ in
            var fields: [String] = ["{\(range.location),\(range.length)}", "\"\(escape(string.substring(with: range)))\""]
            if let font = attributes[.font] as? NSFont {
                fields.append("font=\(font.familyName ?? "?") \(number(font.pointSize)) traits=\(font.fontDescriptor.symbolicTraits.rawValue)")
            }
            if let color = attributes[.foregroundColor] as? NSColor {
                fields.append("fg=\(describe(color))")
            }
            if let color = attributes[.backgroundColor] as? NSColor {
                fields.append("bg=\(describe(color))")
            }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle {
                fields.append("para=\(describe(style))")
            }
            if let kern = attributes[.kern] as? NSNumber {
                fields.append("kern=\(number(kern.doubleValue))")
            }
            if let strike = attributes[.strikethroughStyle] as? NSNumber {
                fields.append("strike=\(strike.intValue)")
            }
            if let underline = attributes[.underlineStyle] as? NSNumber {
                fields.append("underline=\(underline.intValue)")
            }
            if let baseline = attributes[.baselineOffset] as? NSNumber {
                fields.append("baseline=\(number(baseline.doubleValue))")
            }
            if let link = attributes[.link] {
                fields.append("link=\(link)")
            }
            for key in attributes.keys.map(\.rawValue).filter({ $0.hasPrefix("lineform.") }).sorted() {
                fields.append("\(key)=\(describeValue(attributes[NSAttributedString.Key(key)]!))")
            }
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                fields.append("attachment=\(describe(attachment))")
            }
            let described: Set<NSAttributedString.Key> = [
                .font, .foregroundColor, .backgroundColor, .paragraphStyle, .kern, .strikethroughStyle,
                .underlineStyle, .baselineOffset, .link, .attachment
            ]
            let others = attributes.keys
                .filter { !described.contains($0) && !$0.rawValue.hasPrefix("lineform.") }
                .map(\.rawValue)
                .sorted()
            if !others.isEmpty {
                fields.append("other=[\(others.joined(separator: ","))]")
            }
            output += fields.joined(separator: " ") + "\n"
        }
        return output
    }

    private static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            default:
                if scalar.value < 0x20 || scalar.value == 0xFFFC || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    result += String(format: "\\u{%04X}", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    static func number(_ value: CGFloat) -> String { String(format: "%.4f", Double(value)) }
    static func number(_ value: Double) -> String { String(format: "%.4f", value) }

    private static let namedColorSpaces: [(NSColorSpace, String)] = [
        (.sRGB, "sRGB"),
        (.extendedSRGB, "extendedSRGB"),
        (.displayP3, "displayP3"),
        (.genericRGB, "genericRGB"),
        (.deviceRGB, "deviceRGB"),
        (.adobeRGB1998, "adobeRGB1998"),
        (.genericGray, "genericGray"),
        (.genericGamma22Gray, "genericGamma22Gray"),
        (.extendedGenericGamma22Gray, "extendedGenericGamma22Gray"),
        (.deviceGray, "deviceGray"),
        (.genericCMYK, "genericCMYK"),
        (.deviceCMYK, "deviceCMYK")
    ]

    static func describe(_ color: NSColor) -> String {
        switch color.type {
        case .catalog:
            return "catalog(\(color.catalogNameComponent)/\(color.colorNameComponent))"
        case .pattern:
            return "pattern"
        case .componentBased:
            let space = color.colorSpace
            let name = namedColorSpaces.first { $0.0 == space }?.1
                ?? (space.cgColorSpace?.name as String?)
                ?? space.localizedName
                ?? "unknown"
            var components = [CGFloat](repeating: 0, count: color.numberOfComponents)
            color.getComponents(&components)
            return "\(name)(\(components.map { number($0) }.joined(separator: ",")))"
        @unknown default:
            return "unknownType(\(color.type.rawValue))"
        }
    }

    private static func describe(_ style: NSParagraphStyle) -> String {
        var parts = [
            "align=\(style.alignment.rawValue)",
            "lhm=\(number(style.lineHeightMultiple))",
            "minLH=\(number(style.minimumLineHeight))",
            "maxLH=\(number(style.maximumLineHeight))",
            "lineSp=\(number(style.lineSpacing))",
            "before=\(number(style.paragraphSpacingBefore))",
            "after=\(number(style.paragraphSpacing))",
            "head=\(number(style.headIndent))",
            "first=\(number(style.firstLineHeadIndent))",
            "tail=\(number(style.tailIndent))",
            "break=\(style.lineBreakMode.rawValue)",
            "tabs=[\(style.tabStops.map { "\(number($0.location)):\($0.alignment.rawValue)" }.joined(separator: ","))]"
        ]
        if !style.textBlocks.isEmpty {
            parts.append("blocks=[\(style.textBlocks.map(describe).joined(separator: ";"))]")
        }
        return parts.joined(separator: " ")
    }

    private static func describe(_ block: NSTextBlock) -> String {
        let width = "width=\(number(block.contentWidth))/\(block.contentWidthValueType.rawValue)"
        if let cell = block as? NSTextTableBlock {
            return "table row=\(cell.startingRow) rowSpan=\(cell.rowSpan) col=\(cell.startingColumn) colSpan=\(cell.columnSpan) cols=\(cell.table.numberOfColumns) \(width)"
        }
        return "\(String(describing: type(of: block))) \(width)"
    }

    private static func describe(_ attachment: NSTextAttachment) -> String {
        var parts = [String(describing: type(of: attachment))]
        let bounds = attachment.bounds
        parts.append("bounds={\(number(bounds.origin.x)),\(number(bounds.origin.y)),\(number(bounds.width)),\(number(bounds.height))}")
        if let cell = attachment.attachmentCell as? NSCell {
            parts.append("cell=\(String(describing: type(of: cell)))")
        }
        let image = attachment.image ?? (attachment.attachmentCell as? NSTextAttachmentCell)?.image
        if let image {
            let pixelWidth = image.representations.map(\.pixelsWide).max() ?? 0
            let pixelHeight = image.representations.map(\.pixelsHigh).max() ?? 0
            parts.append("image=\(number(image.size.width))x\(number(image.size.height)) px=\(pixelWidth)x\(pixelHeight)")
        }
        return parts.joined(separator: " ")
    }

    private static func describeValue(_ value: Any) -> String {
        if let value = value as? NSValue, String(cString: value.objCType).hasPrefix("{_NSRange") {
            let range = value.rangeValue
            return "{\(range.location),\(range.length)}"
        }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }
}

// MARK: - Pixel hash

/// Draws an attributed string off-screen (no window) with TextKit 1 into an 8-bit RGBA bitmap in
/// a fixed sRGB space, at a fixed appearance, with font smoothing off, and hashes the bytes.
@MainActor
enum RenderPixels {
    static func sha256(of text: NSAttributedString, width: CGFloat, scale: CGFloat, background: NSColor, dark: Bool) -> String {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        let glyphs = layoutManager.glyphRange(for: container)
        let height = ceil(max(layoutManager.usedRect(for: container).maxY, 1))

        let pixelsWide = Int(width * scale)
        let pixelsHigh = Int(height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bitmapFormat: [],
            bytesPerRow: pixelsWide * 4,
            bitsPerPixel: 32
        ), let data = rep.bitmapData,
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
        let cgContext = CGContext(
            data: data,
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: pixelsWide * 4,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return "bitmap-allocation-failed"
        }
        memset(data, 0, pixelsWide * pixelsHigh * 4)
        cgContext.setShouldSmoothFonts(false)
        cgContext.setAllowsFontSmoothing(false)
        cgContext.setShouldAntialias(true)
        cgContext.interpolationQuality = .high
        // Flip to TextKit's top-left origin at the requested scale.
        cgContext.translateBy(x: 0, y: CGFloat(pixelsHigh))
        cgContext.scaleBy(x: scale, y: -scale)

        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let graphics = NSGraphicsContext(cgContext: cgContext, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        appearance.performAsCurrentDrawingAppearance {
            background.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            layoutManager.drawBackground(forGlyphRange: glyphs, at: .zero)
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        }
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let digest = SHA256.hash(data: Data(bytes: data, count: pixelsWide * pixelsHigh * 4))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(pixelsWide)x\(pixelsHigh) \(hex)"
    }
}
