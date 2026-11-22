import XCTest
@testable import Lineform
@testable import LineformCore

/// The reference's pure tests moved to the package (`MarkdownReferenceSectionsTests`). These two
/// need the app: its own catalog bundle, and the Mac view's pasteboard write.
final class MarkdownReferenceTests: XCTestCase {
    private static let languages = ["en", "es", "fr", "de", "ja", "zh-Hans"]

    /// The reference's strings live in LineformCore's catalog, so its `.lproj` folders answer. Xcode
    /// emits no `en.lproj` there (English is the development language and the key is the English
    /// text), so English falls back to the test host's `en.lproj`, which holds none of these keys
    /// and so returns the key — the same bundle these tests used before the strings moved.
    private func bundle(_ language: String) throws -> Bundle {
        let path = Bundle.lineformCore.path(forResource: language, ofType: "lproj")
            ?? (language == "en" ? Bundle.main.path(forResource: language, ofType: "lproj") : nil)
        return try XCTUnwrap(path.flatMap(Bundle.init(path:)), "\(language).lproj missing from LineformCore's bundle")
    }

    /// Explicitly the ENGLISH rendering. `.module` is NOT the fix — `MarkdownReference.sections`
    /// is *defined* as `sections(in: .module)`, so on a Mac or CI runner configured for German
    /// `.module` resolves German and every English-asserting test below fails. The English
    /// bundle carries none of these keys, so a lookup there returns the key — which is the
    /// English text.
    private func englishBundle() throws -> Bundle { try bundle("en") }

    /// Guards the mechanism the whole per-language reference rests on. `String(localized:…locale:)`
    /// formats interpolated VALUES for a locale; it does not choose which .lproj answers. Only a
    /// bundle does. If this ever inverts, `sections(in:)` is silently English everywhere.
    func testLanguageResolutionComesFromTheBundleNotTheLocale() throws {
        let german = try XCTUnwrap(
            Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)),
            "de.lproj missing from the test host — the app's own catalog should ship it"
        )

        // The positive: a German bundle resolves German.
        XCTAssertEqual(german.localizedString(forKey: "Don't Save", value: nil, table: nil), "Nicht sichern")

        // The negative: locale: does NOT.
        XCTAssertEqual(String(localized: "Don't Save", locale: Locale(identifier: "de_DE")), "Don't Save")

        // The form sections(in:) will use.
        XCTAssertEqual(String(localized: "Don't Save", bundle: german), "Nicht sichern")
    }

    /// What the action actually DOES. The pasteboard write is factored out of the button's closure
    /// precisely so the accessibility mirror and the button share it — and so it can be exercised
    /// here, against a scratch pasteboard, with no window and no `NSPasteboard.general` clobbering.
    /// `@MainActor` because the view type is — the pasteboard is created and read on the same
    /// actor that writes it. No window is constructed; this stays in the DEFAULT test plan.
    @MainActor
    func testCopyWritesTheRowsLiteralSyntaxToThePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.lineform.tests.markdown-basics-copy"))
        defer { pasteboard.releaseGlobally() }

        for row in MarkdownReference.sections(in: try englishBundle()).flatMap(\.rows) {
            guard let affordance = row.copyAffordance(in: try englishBundle()) else { continue }
            OutlineMarkdownBasicsTabView.writeToPasteboard(affordance.text, to: pasteboard)
            XCTAssertEqual(pasteboard.string(forType: .string), row.syntax,
                           "\(row.id) put something other than its literal syntax on the pasteboard")
        }

        // And it REPLACES rather than appends — the button can be pressed twice.
        OutlineMarkdownBasicsTabView.writeToPasteboard("# Title", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "# Title")
    }

}
