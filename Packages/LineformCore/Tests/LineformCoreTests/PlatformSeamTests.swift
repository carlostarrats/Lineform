import XCTest
@testable import LineformCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Mac/iPhone seam: the macOS branch must be today's AppKit call, and the iOS branch must
/// land on the same design values. The render golden in LineformTests proves the Mac side
/// pixel for pixel; these pin the values both platforms share.
final class PlatformSeamTests: XCTestCase {

    // MARK: - Colours

    #if os(macOS)
    /// iOS has no calibrated colour space, so it draws Quiet and Night from a table of the sRGB
    /// values macOS converts those whites to. This keeps the table honest.
    func testCalibratedWhiteTableMatchesMacConversion() throws {
        for white in [0.86, 0.19, 0.90, 0.88, 0.09] as [CGFloat] {
            let converted = try XCTUnwrap(NSColor(calibratedWhite: white, alpha: 1).usingColorSpace(.sRGB))
            let entry = try XCTUnwrap(CalibratedWhiteTable.sRGB[white], "no iOS table entry for \(white)")
            XCTAssertEqual(converted.redComponent, entry, accuracy: 0.5 / 255, "red for \(white)")
            XCTAssertEqual(converted.greenComponent, entry, accuracy: 0.5 / 255, "green for \(white)")
            XCTAssertEqual(converted.blueComponent, entry, accuracy: 0.5 / 255, "blue for \(white)")
            XCTAssertEqual(converted.alphaComponent, 1, accuracy: 0.5 / 255, "alpha for \(white)")
        }
    }
    #endif

    func testThemeValuesAreTheDesktopValues() throws {
        let expected: [(Theme, page: String, ink: String)] = [
            (.system, "#FFFFFF", "#1F1F1F"),
            (.paper, "#F6F3ED", "#1F1F1F"),
            (.calm, "#F2F4F5", "#1F1F1F"),
            // The sRGB conversion of NSColor(calibratedWhite:) 0.19/0.86 and 0.09/0.88 on macOS.
            (.quiet, "#3F3F3F", "#E2E2E2"),
            (.night, "#1E1E1E", "#E6E6E6"),
        ]
        XCTAssertEqual(expected.map(\.0.id), Theme.builtIn.map(\.id))
        for (theme, page, ink) in expected {
            XCTAssertEqual(try Self.hex(theme.backgroundColor), page, "\(theme.name) page")
            XCTAssertEqual(try Self.hex(theme.textColor), ink, "\(theme.name) ink")
        }
    }

    func testEveryBuiltInThemeInkIsAA() {
        for theme in Theme.builtIn {
            let ratio = Theme.contrastRatio(theme.textColor, theme.backgroundColor)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme.name) body text is \(ratio):1")
        }
    }

    func testReadableInkLiftsLinkOnQuiet() {
        let ink = Theme.quiet.readableInk(.lineformLink)
        XCTAssertGreaterThanOrEqual(Theme.contrastRatio(ink, Theme.quiet.backgroundColor), 4.5)
    }

    // MARK: - Fonts

    func testBoldTraitIsAdded() {
        let font = lineformFont(.systemFont(ofSize: 17), adding: .bold)
        XCTAssertTrue(Self.hasTrait(font, .bold), "\(font) is not bold")
        XCTAssertEqual(font.pointSize, 17)
    }

    func testItalicTraitIsAdded() {
        let font = lineformFont(.systemFont(ofSize: 17), adding: .italic)
        XCTAssertTrue(Self.hasTrait(font, .italic), "\(font) is not italic")
        XCTAssertEqual(font.pointSize, 17)
    }

    #if os(iOS)
    /// iOS does not ship Comic Sans MS, so the picker must not offer it there.
    func testComicSansIsNotOfferedOnIPhone() {
        let offered = FontOption.availableGroupedOptions.flatMap(\.options).map(\.id)
        XCTAssertFalse(offered.contains(.comicSans))
        XCTAssertFalse(offered.isEmpty)
    }
    #endif

    /// The font group names moved into the package catalog with `FontOption`. Each language must
    /// still read the translation the app catalog carried before the move.
    func testFontGroupNamesAreTranslated() throws {
        let appCatalogTranslations: [String: [String: String]] = [
            "System": [
                "es": "Sistema", "fr": "Système", "de": "System", "ja": "システム", "zh-Hans": "系统",
            ],
            "Monospaced": [
                "es": "Monoespaciada", "fr": "À chasse fixe", "de": "Dicktengleich", "ja": "等幅", "zh-Hans": "等宽",
            ],
            "Reading & Accessibility": [
                "es": "Lectura y accesibilidad", "fr": "Lecture et accessibilité",
                "de": "Lesen und Bedienungshilfen", "ja": "閲覧とアクセシビリティ", "zh-Hans": "阅读与辅助功能",
            ],
        ]
        for language in ["es", "fr", "de", "ja", "zh-Hans"] {
            let bundle = try XCTUnwrap(
                Bundle.lineformCore.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)),
                "\(language).lproj missing from LineformCore's bundle"
            )
            for (key, translations) in appCatalogTranslations {
                let localized = bundle.localizedString(forKey: key, value: "\u{1}missing", table: nil)
                let expected = try XCTUnwrap(translations[language])
                XCTAssertTrue(localized != key || localized == expected,
                              "\(key) is untranslated in \(language)")
                XCTAssertEqual(localized, expected, "\(key) in \(language)")
            }
        }
    }

    // MARK: - Helpers

    private static func hex(_ color: PlatformColor) throws -> String {
        let rgb = try XCTUnwrap(color.lineformSRGBComponents)
        func byte(_ component: CGFloat) -> Int { Int((component * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.red), byte(rgb.green), byte(rgb.blue))
    }

    private static func hasTrait(_ font: PlatformFont, _ trait: PlatformFontTrait) -> Bool {
        let traits = font.fontDescriptor.symbolicTraits
        #if os(macOS)
        return traits.contains(trait == .bold ? .bold : .italic)
        #else
        return traits.contains(trait == .bold ? .traitBold : .traitItalic)
        #endif
    }
}
