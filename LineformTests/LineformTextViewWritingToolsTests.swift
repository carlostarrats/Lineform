import AppKit
import XCTest
@testable import Lineform

@MainActor
final class LineformTextViewWritingToolsTests: XCTestCase {
    func testTextViewRemainsNativeNSTextViewWithTextKit2APISurface() {
        let textView = LineformTextView()

        XCTAssertTrue(textView is NSTextView)
        if #available(macOS 12.0, *) {
            _ = textView.textLayoutManager
        }
    }

    func testWritingToolsAreConfiguredForPlainMarkdown() {
        let textView = LineformTextView()

        if #available(macOS 15.0, *) {
            XCTAssertEqual(textView.writingToolsBehavior, .complete)
            XCTAssertTrue(textView.allowedWritingToolsResultOptions.contains(.plainText))
            XCTAssertFalse(textView.allowedWritingToolsResultOptions.contains(.table))
        }
    }

    func testColumnWidthCentersTextContainerInWideEditor() {
        let textView = LineformTextView()
        textView.setFrameSize(NSSize(width: 1_000, height: 500))
        var profile = ReadingProfile.original
        profile.columnWidth = 500
        profile.marginWidth = 40

        textView.applyTypography(profile)

        XCTAssertEqual(textView.textContainerInset.width, 250)
    }

    func testTypographyAppliesFontSelectionAndCaretWidthSetting() {
        let textView = LineformTextView()
        var profile = ReadingProfile.original
        profile.fontID = .jetBrainsMono
        profile.fontSize = 18
        profile.insertionPointWidth = 4

        textView.applyTypography(profile)

        XCTAssertEqual(textView.font?.fontName, NSFont.monospacedSystemFont(ofSize: 18, weight: .regular).fontName)
        XCTAssertEqual(textView.appliedReadingProfile.insertionPointWidth, 4)
    }

    func testReduceMarkdownNoiseChangesMarkdownMarkerStyling() throws {
        let textView = LineformTextView()
        textView.string = "# Title"

        var normalProfile = ReadingProfile.original
        normalProfile.reduceMarkdownNoise = false
        textView.applyTypography(normalProfile)
        let normalColor = try XCTUnwrap(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)

        var quieterProfile = normalProfile
        quieterProfile.reduceMarkdownNoise = true
        textView.applyTypography(quieterProfile)
        let quieterColor = try XCTUnwrap(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)

        XCTAssertNotEqual(normalColor, quieterColor)
    }

    func testReadingAssistSettingsAreAppliedToEditorProfile() {
        let textView = LineformTextView()
        var profile = ReadingProfile.original
        profile.readingRulerEnabled = true
        profile.typewriterModeEnabled = true
        profile.insertionPointWidth = 3

        textView.applyTypography(profile)

        XCTAssertTrue(textView.appliedReadingProfile.readingRulerEnabled)
        XCTAssertTrue(textView.appliedReadingProfile.typewriterModeEnabled)
        XCTAssertEqual(textView.appliedReadingProfile.insertionPointWidth, 3)
    }
}
