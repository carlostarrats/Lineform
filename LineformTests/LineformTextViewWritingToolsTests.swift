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

    func testWritingToolsAreDisabledToAvoidAppleIntelligenceUI() {
        let textView = LineformTextView()

        if #available(macOS 15.0, *) {
            XCTAssertEqual(textView.writingToolsBehavior, .none)
            XCTAssertTrue(textView.allowedWritingToolsResultOptions.contains(.plainText))
            XCTAssertFalse(textView.allowedWritingToolsResultOptions.contains(.table))
        }
    }

    func testContextMenuKeepsOnlyFastMarkdownEditingActions() throws {
        let textView = LineformTextView()
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        let menu = try XCTUnwrap(textView.menu(for: event))
        let titles = menu.items.map(\.title)

        XCTAssertEqual(titles, [
            "Cut",
            "Copy",
            "Paste",
            "",
            "Title",
            "Section",
            "Bold",
            "Italic",
            "Code",
            "Bulleted List",
            "Link",
            "",
            "Intelligence"
        ])

        XCTAssertFalse(titles.contains("Look Up"))
        XCTAssertFalse(titles.contains("Translate"))
        XCTAssertFalse(titles.contains("Search With Google"))
        XCTAssertFalse(titles.contains("Share..."))
        XCTAssertFalse(titles.contains("Font"))
        XCTAssertFalse(titles.contains("Show Writing Tools"))
        XCTAssertFalse(titles.contains("Writing Tools"))
        XCTAssertFalse(titles.contains("Services"))
    }

    func testContextMenuIntelligenceSubmenuKeepsOnlyLineformActions() throws {
        let textView = LineformTextView()
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        let menu = try XCTUnwrap(textView.menu(for: event))
        let intelligenceItem = try XCTUnwrap(menu.items.first { $0.title == "Intelligence" })
        let submenu = try XCTUnwrap(intelligenceItem.submenu)

        XCTAssertEqual(submenu.items.map(\.title), [
            "Clean Markdown"
        ])
    }

    func testAutomaticIntelligenceMenuUsesContextualSuggestionsForCurrentSelection() throws {
        let textView = LineformTextView()
        textView.string = "# Title\n\n- rough item\n- second item"
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))

        let menu = try XCTUnwrap(textView.makeAutomaticIntelligenceMenuForCurrentSelection())

        XCTAssertEqual(menu.items.prefix(3).map(\.title), [
            "Clean Markdown",
            "Proofread",
            "Rewrite"
        ])
    }

    func testAutomaticIntelligenceMenuIsUnavailableWithoutSelection() {
        let textView = LineformTextView()
        textView.string = "No selection."
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertNil(textView.makeAutomaticIntelligenceMenuForCurrentSelection())
    }

    func testMouseSelectionSchedulesAutomaticIntelligenceMenuButKeyboardSelectionDoesNot() {
        let textView = LineformTextView()
        textView.string = "Selected text."
        textView.setSelectedRange(NSRange(location: 0, length: 8))

        textView.markSelectionChangeAsKeyboardDriven()
        XCTAssertFalse(textView.shouldOpenAutomaticIntelligenceMenuAfterMouseUp())
        XCTAssertFalse(textView.hasPendingAutomaticIntelligenceMenu)

        textView.markSelectionChangeAsMouseDriven()
        XCTAssertTrue(textView.shouldOpenAutomaticIntelligenceMenuAfterMouseUp())
        textView.scheduleAutomaticIntelligenceMenuIfNeeded()

        XCTAssertFalse(textView.shouldOpenAutomaticIntelligenceMenuAfterMouseUp())
        XCTAssertTrue(textView.hasPendingAutomaticIntelligenceMenu)
    }

    func testKeyboardSelectionCancelsPendingAutomaticIntelligenceMenu() {
        let textView = LineformTextView()
        textView.string = "Selected text."
        textView.setSelectedRange(NSRange(location: 0, length: 8))
        textView.markSelectionChangeAsMouseDriven()
        textView.scheduleAutomaticIntelligenceMenuIfNeeded()

        XCTAssertTrue(textView.hasPendingAutomaticIntelligenceMenu)

        textView.markSelectionChangeAsKeyboardDriven()

        XCTAssertFalse(textView.hasPendingAutomaticIntelligenceMenu)
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

    func testCaretWidthSettingChangesDrawnInsertionPointWidth() {
        let baseRect = NSRect(x: 20, y: 10, width: 1, height: 24)
        var profile = ReadingProfile.original
        profile.insertionPointWidth = 4

        let caretRect = LineformTextView.insertionPointRect(for: baseRect, profile: profile)

        XCTAssertEqual(caretRect.width, 4)
        XCTAssertEqual(caretRect.origin.x, baseRect.origin.x)
        XCTAssertEqual(caretRect.height, baseRect.height)
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
        XCTAssertFalse(colorsHaveSameRGB(normalColor, quieterColor))
    }

    func testQuietMarkdownNoiseUsesDarkMarkerContrastColorInsteadOfSystemBlack() throws {
        let textView = LineformTextView()
        textView.string = "# Title"

        var profile = ReadingPreset.quiet.profile
        profile.reduceMarkdownNoise = true
        textView.applyTypography(profile)

        let markerColor = try XCTUnwrap(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        assertSameRGB(markerColor, MarkdownSyntaxHighlighter.markdownMarkerColor(for: profile))
        XCTAssertNotEqual(markerColor, NSColor.black)
        XCTAssertEqual(markerColor.alphaComponent, 1, accuracy: 0.001)
    }

    func testMarkdownMarkersUseContrastColorForLightAndDarkThemes() throws {
        let textView = LineformTextView()
        textView.string = "# Title"

        textView.applyTypography(ReadingProfile.original)
        textView.refreshMarkdownHighlighting()
        let lightMarkerColor = try XCTUnwrap(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        assertSameRGB(lightMarkerColor, MarkdownSyntaxHighlighter.markdownMarkerColor(for: .original))

        textView.applyTypography(ReadingPreset.quiet.profile)
        let darkMarkerColor = try XCTUnwrap(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        assertSameRGB(darkMarkerColor, MarkdownSyntaxHighlighter.markdownMarkerColor(for: ReadingPreset.quiet.profile))

        XCTAssertFalse(colorsHaveSameRGB(lightMarkerColor, darkMarkerColor))
        XCTAssertFalse(colorsHaveSameRGB(MarkdownSyntaxHighlighter.markdownMarkerColor(for: .original), MarkdownSyntaxHighlighter.markdownMarkerColor(for: ReadingPreset.quiet.profile)))
    }

    func testInlineCodeUsesBlueAccentInsteadOfBrown() throws {
        let textView = LineformTextView()
        textView.string = "Open `.md` files"

        textView.refreshMarkdownHighlighting()

        let codeColor = try XCTUnwrap(textView.textStorage?.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor)
        assertSameRGB(codeColor, MarkdownSyntaxHighlighter.inlineCodeColor(for: .original))
        XCTAssertNotEqual(codeColor, NSColor.systemBrown)
    }

    func testInlineCodeUsesLightBlueAccentOnQuietTheme() throws {
        let textView = LineformTextView()
        textView.string = "Open `.md` files"

        textView.applyTypography(ReadingPreset.quiet.profile)

        let codeColor = try XCTUnwrap(textView.textStorage?.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor)
        assertSameRGB(codeColor, MarkdownSyntaxHighlighter.inlineCodeColor(for: ReadingPreset.quiet.profile))
        XCTAssertNotEqual(codeColor, MarkdownSyntaxHighlighter.inlineCodeColor(for: .original))
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

    func testReadingRulerUsesVisibleCurrentLineGuide() {
        XCTAssertGreaterThanOrEqual(LineformTextView.readingRulerFillOpacity, 0.12)
    }

    func testTypewriterModeScrollTargetCentersSelectedLine() {
        let lineRect = NSRect(x: 0, y: 420, width: 400, height: 24)
        let visibleBounds = NSRect(x: 12, y: 80, width: 420, height: 180)

        let targetOrigin = LineformTextView.typewriterScrollOrigin(for: lineRect, visibleBounds: visibleBounds)

        XCTAssertEqual(targetOrigin.x, visibleBounds.origin.x)
        XCTAssertEqual(targetOrigin.y, 342)
    }

    func testTurningTypewriterModeOffRestoresPreviousScrollPosition() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        let textView = LineformTextView()
        textView.setFrameSize(NSSize(width: 420, height: 1_600))
        textView.string = (0..<80).map { "Line \($0)" }.joined(separator: "\n")
        scrollView.documentView = textView
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: 120))
        let originalScrollY = scrollView.contentView.bounds.origin.y
        textView.setSelectedRange(NSRange(location: 280, length: 0))

        var typewriterProfile = ReadingProfile.original
        typewriterProfile.typewriterModeEnabled = true
        textView.applyTypography(typewriterProfile)

        var normalProfile = typewriterProfile
        normalProfile.typewriterModeEnabled = false
        textView.applyTypography(normalProfile)

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, originalScrollY, accuracy: 0.5)
    }

    private func assertSameRGB(_ first: NSColor, _ second: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        let firstRGB = first.usingColorSpace(.deviceRGB)
        let secondRGB = second.usingColorSpace(.deviceRGB)
        XCTAssertEqual(firstRGB?.redComponent ?? -1, secondRGB?.redComponent ?? -2, accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(firstRGB?.greenComponent ?? -1, secondRGB?.greenComponent ?? -2, accuracy: 0.005, file: file, line: line)
        XCTAssertEqual(firstRGB?.blueComponent ?? -1, secondRGB?.blueComponent ?? -2, accuracy: 0.005, file: file, line: line)
    }

    private func colorsHaveSameRGB(_ first: NSColor, _ second: NSColor) -> Bool {
        let firstRGB = first.usingColorSpace(.deviceRGB)
        let secondRGB = second.usingColorSpace(.deviceRGB)
        return abs((firstRGB?.redComponent ?? -1) - (secondRGB?.redComponent ?? -2)) < 0.005
            && abs((firstRGB?.greenComponent ?? -1) - (secondRGB?.greenComponent ?? -2)) < 0.005
            && abs((firstRGB?.blueComponent ?? -1) - (secondRGB?.blueComponent ?? -2)) < 0.005
    }
}
