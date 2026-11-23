import LineformCore
import UIKit
import XCTest
@testable import LineformiOS

/// Every quiet chrome ink `PhoneInk` vends reaches its WCAG floor (text 4.5:1, non-text 3:1) on the
/// surface it is drawn on, in every theme the iPhone can display: the five built-in themes, the
/// high-contrast theme in light and dark, and every theme as Automatic Dark Mode draws it. The
/// iPhone counterpart of the Mac's `ThemeTests.testEveryReaderInkMeetsAAOnEveryTheme`, measured
/// with `Theme.contrastRatio`, the one production definition.
@MainActor
final class PhoneInkContrastTests: XCTestCase {
    private struct DisplayTheme {
        var label: String
        var theme: Theme
        var style: UIUserInterfaceStyle
    }

    private var displayThemes: [DisplayTheme] {
        var result: [DisplayTheme] = []
        for style in [UIUserInterfaceStyle.light, .dark] {
            let styleName = style == .dark ? "dark" : "light"
            for theme in Theme.builtIn {
                result.append(DisplayTheme(label: "\(theme.name) (\(styleName))", theme: theme, style: style))
            }
            var highContrast = ReadingProfile.original
            highContrast.highContrastEnabled = true
            result.append(DisplayTheme(label: "High Contrast (\(styleName))", theme: Theme.theme(for: highContrast), style: style))
        }
        // Automatic Dark Mode: what each theme draws as while the iPhone is in Dark appearance.
        for theme in Theme.builtIn {
            for highContrastEnabled in [false, true] {
                var profile = ReadingProfile.original
                profile.themeID = theme.id
                profile.highContrastEnabled = highContrastEnabled
                let display = AppSettings.displayProfile(profile, automaticDarkMode: true, userInterfaceStyle: .dark)
                let name = "automatic dark from \(theme.name)\(highContrastEnabled ? " + High Contrast" : "")"
                result.append(DisplayTheme(label: name, theme: Theme.theme(for: display), style: .dark))
            }
        }
        return result
    }

    func testEveryInkMeetsItsFloorOnItsSurfaceInEveryDisplayTheme() {
        var lowest: [String: (ratio: CGFloat, where: String)] = [:]
        for display in displayThemes {
            let entries = PhoneInk.allInks(for: display.theme, userInterfaceStyle: display.style)
            XCTAssertEqual(entries.count, PhoneInk.Role.allCases.count)
            for entry in entries {
                XCTAssertEqual(entry.color.cgColor.alpha, 1, "\(entry.name) on \(display.label) is flattened")
                XCTAssertEqual(entry.surface.cgColor.alpha, 1, "\(entry.name)'s surface on \(display.label) is opaque")
                let ratio = Theme.contrastRatio(entry.color, entry.surface)
                XCTAssertGreaterThanOrEqual(
                    ratio, entry.minimumRatio,
                    "\(entry.name) on \(display.label): \(String(format: "%.2f", ratio)):1"
                )
                if ratio < (lowest[entry.name]?.ratio ?? .infinity) {
                    lowest[entry.name] = (ratio, display.label)
                }
            }
        }
        let report = lowest.keys.sorted().map { name in
            "\(name) \(String(format: "%.2f", lowest[name]!.ratio)) (\(lowest[name]!.where))"
        }
        print("PhoneInk minimum ratios: " + report.joined(separator: "; "))
    }

    /// Text inks are never the non-text floor, and the floors are the WCAG numbers.
    func testFloorsAreTheWCAGNumbers() {
        for role in PhoneInk.Role.allCases {
            switch role {
            case .icon, .controlEdge: XCTAssertEqual(role.minimumRatio, 3, role.rawValue)
            default: XCTAssertEqual(role.minimumRatio, 4.5, role.rawValue)
            }
        }
    }

    /// Readable, not replaced: the accent stays blue where the page allows it, so it does not
    /// collapse into body ink (the reason `readableInk` blends by the smallest step).
    func testAccentKeepsItsHueOnTheDefaultTheme() {
        let accent = PhoneInk(theme: .system, userInterfaceStyle: .light).uiColor(.accent)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        accent.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertGreaterThan(b, r + 0.2, "the accent is still blue")
    }

    /// The composite surfaces are the wash flattened over the page, not the page itself.
    func testWashSurfacesAreFlattenedOverThePage() {
        let inks = PhoneInk(theme: .paper, userInterfaceStyle: .light)
        XCTAssertNotEqual(inks.commentFieldWash, inks.page)
        XCTAssertNotEqual(inks.searchFieldWash, inks.page)
        XCTAssertLessThan(Theme.contrastRatio(inks.commentFieldWash, inks.page), 1.2, "a wash is a faint tint")
    }
}
