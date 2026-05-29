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
        LineformTextFormatMenuState.shared.setTextFormat(.markdown)
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

        XCTAssertEqual(menu.allowsContextMenuPlugIns, LineformTextContextMenuPresentation.allowsContextMenuPlugIns)
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
            "Link"
        ])
        XCTAssertFalse(titles.contains("Convert to Plain Text"))
        XCTAssertFalse(titles.contains("Convert to Markdown"))

        XCTAssertFalse(titles.contains("Look Up"))
        XCTAssertFalse(titles.contains("Translate"))
        XCTAssertFalse(titles.contains("Search With Google"))
        XCTAssertFalse(titles.contains("Share..."))
        XCTAssertFalse(titles.contains("Font"))
        XCTAssertFalse(titles.contains("Show Writing Tools"))
        XCTAssertFalse(titles.contains("Writing Tools"))
        XCTAssertFalse(titles.contains("Autofill"))
        XCTAssertFalse(titles.contains("AutoFill"))
        XCTAssertFalse(titles.contains("Services"))
        XCTAssertFalse(titles.contains("Intelligence"))
    }

    func testContextMenuPresentationDisablesSystemPluginItems() {
        XCTAssertFalse(LineformTextContextMenuPresentation.allowsContextMenuPlugIns)
        XCTAssertFalse(LineformTextContextMenuPresentation.commandTitles.contains("Autofill"))
        XCTAssertFalse(LineformTextContextMenuPresentation.commandTitles.contains("AutoFill"))
        XCTAssertFalse(LineformTextContextMenuPresentation.commandTitles.contains("Services"))
        XCTAssertEqual(LineformTextContextMenuPresentation.excludedSystemPluginTitles, ["Autofill", "AutoFill", "Services"])
    }

    func testContextMenuKeepsOnlyRawTextEditingActionsWhenDocumentIsPlainText() throws {
        LineformTextFormatMenuState.shared.setTextFormat(.plainText)
        let textView = LineformTextView()
        textView.textFormat = .plainText
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
            "Paste"
        ])
        XCTAssertFalse(titles.contains("Convert to Markdown"))
        XCTAssertFalse(titles.contains("Convert to Plain Text"))
        XCTAssertFalse(titles.contains("Title"))
        XCTAssertFalse(titles.contains("Section"))
        XCTAssertFalse(titles.contains("Bold"))
        XCTAssertFalse(titles.contains("Italic"))
        XCTAssertFalse(titles.contains("Code"))
        XCTAssertFalse(titles.contains("Bulleted List"))
        XCTAssertFalse(titles.contains("Link"))
    }

    func testContextMenuUsesDocumentFormatStateWhenTextViewFormatIsStaleAfterPlainTextConversion() throws {
        LineformTextFormatMenuState.shared.setTextFormat(.plainText)
        let textView = LineformTextView()
        textView.textFormat = .markdown
        let event = try XCTUnwrap(Self.contextMenuEvent())

        let titles = try XCTUnwrap(textView.menu(for: event)).items.map(\.title)

        XCTAssertEqual(titles, [
            "Cut",
            "Copy",
            "Paste"
        ])
        XCTAssertEqual(textView.textFormat, .plainText)
    }

    func testContextMenuUsesDocumentFormatStateWhenTextViewFormatIsStaleAfterMarkdownRestore() throws {
        LineformTextFormatMenuState.shared.setTextFormat(.markdown)
        let textView = LineformTextView()
        textView.textFormat = .plainText
        let event = try XCTUnwrap(Self.contextMenuEvent())

        let titles = try XCTUnwrap(textView.menu(for: event)).items.map(\.title)

        XCTAssertTrue(titles.contains("Title"))
        XCTAssertTrue(titles.contains("Section"))
        XCTAssertTrue(titles.contains("Bold"))
        XCTAssertTrue(titles.contains("Link"))
        XCTAssertEqual(textView.textFormat, .markdown)
    }

    func testPlainTextConversionRoundTripReturnsTextViewToMarkdownState() throws {
        let textView = LineformTextView()
        textView.string = "# Title\n\nPortable **Markdown**.\n"
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
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

        textView.convertMarkdownToPlainText(nil)
        XCTAssertEqual(textView.string, "Title\n\nPortable Markdown.\n")
        XCTAssertEqual(textView.textFormat, .plainText)

        textView.restoreConvertedMarkdown(nil)

        XCTAssertEqual(textView.string, "# Title\n\nPortable **Markdown**.\n")
        XCTAssertEqual(textView.textFormat, .markdown)
        let titles = textView.menu(for: event)?.items.map(\.title) ?? []
        XCTAssertFalse(titles.contains("Convert to Plain Text"))
        XCTAssertFalse(titles.contains("Convert to Markdown"))
    }

    func testRepeatedPlainTextConversionDoesNotOverwriteStoredMarkdownRestore() {
        LineformTextFormatMenuState.shared.setTextFormat(.markdown)
        let textView = LineformTextView()
        textView.string = "# Title\n\nPortable **Markdown**.\n"
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))

        textView.convertMarkdownToPlainText(nil)
        let firstConversion = textView.lastPlainTextConversion
        XCTAssertEqual(LineformTextFormatMenuState.shared.textFormat, .plainText)

        textView.convertMarkdownToPlainText(nil)
        textView.restoreConvertedMarkdown(nil)

        XCTAssertEqual(firstConversion?.originalMarkdown, "# Title\n\nPortable **Markdown**.\n")
        XCTAssertEqual(textView.string, "# Title\n\nPortable **Markdown**.\n")
        XCTAssertEqual(textView.textFormat, .markdown)
        XCTAssertEqual(LineformTextFormatMenuState.shared.textFormat, .markdown)
    }

    func testMarkdownRestoreUsesStoredConversionEvenWhenLocalFormatStateIsStale() {
        let textView = LineformTextView()
        textView.string = "Title\n\nPortable Markdown.\n"
        textView.textFormat = .markdown
        textView.lastPlainTextConversion = MarkdownPlainTextConversion(
            originalMarkdown: "# Title\n\nPortable **Markdown**.\n",
            plainText: "Title\n\nPortable Markdown.\n",
            range: NSRange(location: 0, length: (textView.string as NSString).length)
        )

        textView.restoreConvertedMarkdown(nil)

        XCTAssertEqual(textView.string, "# Title\n\nPortable **Markdown**.\n")
        XCTAssertEqual(textView.textFormat, .markdown)
    }

    func testContextMenuDoesNotExposeIntelligenceSubmenu() throws {
        LineformTextFormatMenuState.shared.setTextFormat(.markdown)
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

        XCTAssertNil(menu.items.first { $0.title == "Intelligence" })
    }

    private static func contextMenuEvent() -> NSEvent? {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    func testMouseSelectionDoesNotScheduleAutomaticIntelligenceMenu() {
        let textView = LineformTextView()
        textView.string = "Selected text."
        textView.setSelectedRange(NSRange(location: 0, length: 8))

        textView.markSelectionChangeAsKeyboardDriven()
        XCTAssertFalse(textView.shouldOpenAutomaticIntelligenceMenuAfterMouseUp())
        XCTAssertFalse(textView.hasPendingAutomaticIntelligenceMenu)

        textView.markSelectionChangeAsMouseDriven()
        XCTAssertFalse(textView.shouldOpenAutomaticIntelligenceMenuAfterMouseUp())
        textView.scheduleAutomaticIntelligenceMenuIfNeeded()

        XCTAssertFalse(textView.shouldOpenAutomaticIntelligenceMenuAfterMouseUp())
        XCTAssertFalse(textView.hasPendingAutomaticIntelligenceMenu)
    }

    func testKeyboardSelectionKeepsAutomaticIntelligenceMenuCanceled() {
        let textView = LineformTextView()
        textView.string = "Selected text."
        textView.setSelectedRange(NSRange(location: 0, length: 8))
        textView.markSelectionChangeAsMouseDriven()
        textView.scheduleAutomaticIntelligenceMenuIfNeeded()

        XCTAssertFalse(textView.hasPendingAutomaticIntelligenceMenu)

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

    func testColumnWidthCapsLineWrappingInWideEditor() {
        let textView = LineformTextView()
        textView.setFrameSize(NSSize(width: 1_000, height: 500))
        var profile = ReadingProfile.original
        profile.columnWidth = 500
        profile.marginWidth = 40

        textView.applyTypography(profile)

        XCTAssertFalse(textView.textContainer?.widthTracksTextView ?? true)
        XCTAssertEqual(textView.textContainer?.containerSize.width, 500)
    }

    func testColumnWidthUsesAvailableWidthInNarrowEditor() {
        let textView = LineformTextView()
        textView.setFrameSize(NSSize(width: 560, height: 500))
        var profile = ReadingProfile.original
        profile.columnWidth = 500
        profile.marginWidth = 40

        textView.applyTypography(profile)

        XCTAssertEqual(textView.textContainerInset.width, 40)
        XCTAssertEqual(textView.textContainer?.containerSize.width, 480)
    }

    func testTextViewCanSmoothHorizontalInsetChangesForInspectorTransition() {
        let textView = LineformTextView()

        XCTAssertFalse(textView.smoothsHorizontalInsetChanges)

        textView.smoothsHorizontalInsetChanges = true

        XCTAssertTrue(textView.smoothsHorizontalInsetChanges)
        XCTAssertEqual(
            textView.horizontalInsetAnimationDuration,
            EditorInspectorTextResponse.horizontalInsetAnimationDuration,
            accuracy: 0.01
        )
    }

    func testHorizontalInsetSmoothingKeepsVisibleTextAnchoredDuringResize() throws {
        var profile = ReadingProfile.original
        profile.columnWidth = 420
        profile.marginWidth = 40

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 260))
        let textView = LineformTextView()
        textView.setFrameSize(NSSize(width: 640, height: 1_200))
        textView.string = Array(repeating: "A line of text that keeps the editor scrollable.", count: 80).joined(separator: "\n")
        textView.smoothsHorizontalInsetChanges = true
        scrollView.documentView = textView
        textView.applyTypography(profile)

        let originalScrollOrigin = NSPoint(x: 0, y: 220)
        scrollView.contentView.setBoundsOrigin(originalScrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let visibleRangeBeforeResize = try XCTUnwrap(textView.visibleCharacterRangeForLayoutPreservation())

        textView.setFrameSize(NSSize(width: 520, height: textView.frame.height))

        let visibleRangeAfterResize = try XCTUnwrap(textView.visibleCharacterRangeForLayoutPreservation())
        XCTAssertEqual(visibleRangeAfterResize.location, visibleRangeBeforeResize.location, accuracy: 8)
        RunLoop.current.run(until: Date().addingTimeInterval(textView.horizontalInsetAnimationDuration + 0.05))
        let visibleRangeAfterLayoutSettles = try XCTUnwrap(textView.visibleCharacterRangeForLayoutPreservation())
        XCTAssertEqual(visibleRangeAfterLayoutSettles.location, visibleRangeBeforeResize.location, accuracy: 8)
    }

    func testHorizontalResizeKeepsUnwrappedVisibleTextAtSameVerticalPositionWhenParentSendsViewportHeight() throws {
        var profile = ReadingProfile.original
        profile.columnWidth = 420
        profile.marginWidth = 40

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 260))
        let textView = LineformTextView()
        textView.setFrameSize(NSSize(width: 640, height: 1_200))
        textView.string = Array(repeating: "Short stable line.", count: 80).joined(separator: "\n")
        textView.smoothsHorizontalInsetChanges = true
        scrollView.documentView = textView
        textView.applyTypography(profile)

        let originalScrollOrigin = NSPoint(x: 0, y: 220)
        scrollView.contentView.setBoundsOrigin(originalScrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let visibleRangeBeforeResize = try XCTUnwrap(textView.visibleCharacterRangeForLayoutPreservation())
        let trackedRange = NSRange(location: visibleRangeBeforeResize.location, length: 1)
        let trackedYBeforeResize = try trackedCharacterY(
            trackedRange,
            in: textView,
            relativeTo: scrollView
        )
        textView.setFrameSize(NSSize(width: 520, height: 1_200))

        let trackedYAfterResize = try trackedCharacterY(
            trackedRange,
            in: textView,
            relativeTo: scrollView
        )
        XCTAssertEqual(trackedYAfterResize, trackedYBeforeResize, accuracy: 0.5)
    }

    func testTypographyRefreshAfterInspectorResizeKeepsVisibleTextAnchored() throws {
        var profile = ReadingProfile.original
        profile.columnWidth = 420
        profile.marginWidth = 40

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 260))
        let textView = LineformTextView()
        textView.setFrameSize(NSSize(width: 640, height: 1_200))
        textView.string = Array(repeating: "A line of text that keeps the editor scrollable.", count: 80).joined(separator: "\n")
        textView.smoothsHorizontalInsetChanges = true
        scrollView.documentView = textView
        textView.applyTypography(profile)

        let originalScrollOrigin = NSPoint(x: 0, y: 220)
        scrollView.contentView.setBoundsOrigin(originalScrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let visibleRangeBeforeResize = try XCTUnwrap(textView.visibleCharacterRangeForLayoutPreservation())

        textView.setFrameSize(NSSize(width: 520, height: 1_200))
        let visibleRangeAfterResize = try XCTUnwrap(textView.visibleCharacterRangeForLayoutPreservation())
        XCTAssertEqual(visibleRangeAfterResize.location, visibleRangeBeforeResize.location, accuracy: 8)

        textView.applyTypography(profile)

        let visibleRangeAfterTypographyRefresh = try XCTUnwrap(textView.visibleCharacterRangeForLayoutPreservation())
        XCTAssertEqual(visibleRangeAfterTypographyRefresh.location, visibleRangeBeforeResize.location, accuracy: 8)
    }

    func testTypographyAppliesFontSelectionAndRetainsStoredProfileMetadata() {
        let textView = LineformTextView()
        var profile = ReadingProfile.original
        profile.fontID = .jetBrainsMono
        profile.fontSize = 18
        profile.insertionPointWidth = 4

        textView.applyTypography(profile)

        XCTAssertEqual(textView.font?.fontName, NSFont.monospacedSystemFont(ofSize: 18, weight: .regular).fontName)
        XCTAssertEqual(textView.appliedReadingProfile.insertionPointWidth, 4)
    }

    func testCaretWidthSettingDoesNotOverrideNativeInsertionPointWidth() {
        let baseRect = NSRect(x: 20, y: 10, width: 1, height: 24)
        var profile = ReadingProfile.original
        profile.insertionPointWidth = 4

        let caretRect = LineformTextView.insertionPointRect(for: baseRect, profile: profile)

        XCTAssertEqual(caretRect.width, baseRect.width)
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

    private func trackedCharacterY(
        _ characterRange: NSRange,
        in textView: LineformTextView,
        relativeTo scrollView: NSScrollView
    ) throws -> CGFloat {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return textView.convert(rect, to: scrollView).midY
    }
}
