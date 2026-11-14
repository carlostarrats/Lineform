import XCTest
import AppKit
@testable import Lineform

final class HistorySidebarPresentationTests: XCTestCase {
    func testLevelSwitcherHiddenForSingleLevel() {
        XCTAssertFalse(HistorySidebarPresentation.showsLevelSwitcher([.sentence]))
        XCTAssertFalse(HistorySidebarPresentation.showsLevelSwitcher([]))
    }

    func testLevelSwitcherShownForNestedGroup() {
        XCTAssertTrue(HistorySidebarPresentation.showsLevelSwitcher([.sentence, .word]))
    }

    func testRowTextIsFirstLineCollapsed() {
        XCTAssertEqual(HistorySidebarRow.displayText(for: "A  b\nc"), "A b")
        XCTAssertEqual(HistorySidebarRow.displayText(for: "\n  lead \t space\nx"), "lead space")
    }

    func testLevelTitlesAreLocalizedNotRawValues() {
        XCTAssertEqual(HistoryLevel.paragraph.title, String(localized: "Paragraph"))
        XCTAssertEqual(HistoryLevel.allCases.map(\.title), ["Paragraph", "Sentence", "Word"])
        XCTAssertEqual(HistoryLevel.word.rawValue, "word")
    }

    func testHistoryTabTitleAndIcon() {
        XCTAssertEqual(OutlineSidebarTab.history.title, "History")
        XCTAssertEqual(OutlineSidebarTab.history.systemImage, "clock.arrow.circlepath")
    }

    func testRowAccessibilityLabel() {
        let row = HistorySidebarRow(id: 1, text: "Hello", author: .ai, isCurrent: true)
        XCTAssertEqual(row.accessibilityLabel(position: 2, of: 3), "Hello, by AI, version 2 of 3")
        let you = HistorySidebarRow(id: 0, text: "Hi", author: .you, isCurrent: false)
        XCTAssertEqual(you.accessibilityLabel(position: 1, of: 3), "Hi, by you, version 1 of 3")
    }

    @MainActor
    func testRowLayoutReusesFilesConstants() {
        let l = HistorySidebarPresentation.rowLayout
        XCTAssertEqual(l.containerPadding, OutlineSidebarView.filesContentHorizontalPadding)
        XCTAssertEqual(l.chevronSlotWidth, OutlineSidebarView.filesChevronSlotWidth)
        XCTAssertEqual(l.backgroundInset, OutlineSidebarView.filesRowBackgroundHorizontalInset)
        XCTAssertEqual(l.height, OutlineSidebarView.filesChildRowHeight)
        // Icon lands at x = 6 + 6 + 12 + 2 = 26 and text at 26 + 18 + 4 = 48, as in Files.
        let iconX = l.containerPadding + l.rowLeading + l.chevronSlotWidth + l.iconLeading
        XCTAssertEqual(iconX, 26)
        XCTAssertEqual(iconX + l.iconWidth + l.textLeading, 48)
    }
    /// A version row's delete lives in a right-click menu; it must also be an accessibility
    /// action (repo invariant: hit-tested affordances carry an `.accessibilityActions` mirror).
    /// Both are built from `rowActions`, so they cannot drift apart.
    func testVersionRowDeleteIsAlsoAnAccessibilityAction() throws {
        XCTAssertEqual(HistorySidebarPresentation.rowActions.map(\.title), [String(localized: "Delete from History")])
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Lineform/Outline/HistorySidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".accessibilityActions {\n            rowActionButtons()"),
                      "the version row mirrors its context menu in the actions rotor")
        XCTAssertTrue(source.contains(".contextMenu {\n            rowActionButtons()"))
    }

    // MARK: - Exit, Add Alternative, hint (QA 1.8 follow-ups)

    func testExitAndAlternativeStrings() {
        XCTAssertEqual(HistorySidebarPresentation.exitTitle, "Exit")
        XCTAssertEqual(HistorySidebarPresentation.addAlternativeTitle, "Add Alternative")
        XCTAssertEqual(HistorySidebarPresentation.addAlternativeCommitLabel, "Add")
        XCTAssertEqual(HistorySidebarPresentation.addButtonTitle, "Add")
        XCTAssertEqual(HistorySidebarPresentation.versionsHeading, "Versions of selected text")
        XCTAssertNotNil(NSImage(systemSymbolName: HistorySidebarPresentation.addButtonSymbol, accessibilityDescription: nil))
        XCTAssertEqual(HistorySidebarPresentation.replacementPlaceholder, "Type an alternative")
        XCTAssertEqual(HistorySidebarPresentation.exitTitle, String(localized: "Exit"))
        XCTAssertNotNil(NSImage(systemSymbolName: HistorySidebarPresentation.addAlternativeCommitSymbol,
                                accessibilityDescription: nil))
        // The typed text stops 6–8pt before the return button.
        XCTAssertTrue((6...8).contains(HistorySidebarPresentation.commitButtonGap))
    }

    func testAlternativeStringsAreLocalized() throws {
        for language in ["es", "fr", "de", "ja", "zh-Hans"] {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for key in ["Add Alternative", "Add", "Versions of selected text", "Type an alternative"] {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: nil, table: nil), key, "\(language): \(key)")
            }
        }
    }

    /// The section row's Add is quieter than the Exit capsule's label — lighter in light chrome,
    /// darker in dark — yet still ≥ 3:1 on the sidebar background, hovered or not.
    @MainActor
    func testAddButtonIsQuieterThanExitAndStillLegible() {
        for usesDarkChrome in [false, true] {
            let exitInk = SidebarCapsuleButtonStyle.textWhite(usesDarkChrome: usesDarkChrome, emphasis: .quiet)
            let background = usesDarkChrome
                ? OutlineSidebarView.darkBackgroundNSColor
                : NSColor(calibratedWhite: OutlineSidebarView.lightBackgroundWhiteComponent, alpha: 1)
            for hovered in [false, true] {
                let white = HistorySidebarPresentation.addButtonWhite(usesDarkChrome: usesDarkChrome, isHovered: hovered)
                if usesDarkChrome {
                    XCTAssertLessThan(white, exitInk, "dark: a darker grey than Exit")
                } else {
                    XCTAssertGreaterThan(white, exitInk, "light: a lighter grey than Exit")
                }
                let ratio = Theme.contrastRatio(NSColor(calibratedWhite: white, alpha: 1), background)
                XCTAssertGreaterThanOrEqual(ratio, 3, "dark \(usesDarkChrome) hovered \(hovered): \(ratio):1")
            }
            // Hover brightens it toward the label ink.
            let rest = HistorySidebarPresentation.addButtonWhite(usesDarkChrome: usesDarkChrome, isHovered: false)
            let hover = HistorySidebarPresentation.addButtonWhite(usesDarkChrome: usesDarkChrome, isHovered: true)
            XCTAssertGreaterThan(Theme.contrastRatio(NSColor(calibratedWhite: hover, alpha: 1), background),
                                 Theme.contrastRatio(NSColor(calibratedWhite: rest, alpha: 1), background))
        }
    }

    /// Selecting a passage swaps the lead line's text IN PLACE: the empty state and the section
    /// row's label are one view (`leadLine(leadText(…))`) on shared constants — same size, colour,
    /// inset and distance under the tab divider — and Add is an overlay, so it cannot move it.
    @MainActor
    func testEmptyStateAndSectionLabelShareOnePlace() throws {
        XCTAssertEqual(HistorySidebarPresentation.leadTextTopInset, OutlineSidebarView.sidebarLeadLineTop)
        XCTAssertEqual(HistorySidebarPresentation.leadTextFontSize, 12)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Lineform/Outline/HistorySidebarView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("leadLine(leadText(HistorySidebarPresentation.emptySelectionText))"))
        XCTAssertTrue(source.contains("leadLine(\n            leadText(HistorySidebarPresentation.versionsHeading)"))
        XCTAssertTrue(source.contains(".overlay(alignment: .trailing) {\n                    HistoryAddAlternativeButton"))
    }

    /// Every sidebar tab puts its lead line and its first row at the same two shared distances, so
    /// switching tabs never shifts either (source-level: no window in the default plan).
    @MainActor
    func testEveryTabUsesTheSharedLeadLineSpacing() throws {
        XCTAssertEqual(OutlineSidebarView.sidebarLeadLineTop, 20)
        XCTAssertEqual(OutlineSidebarView.sidebarLeadToFirstRow, 12)
        XCTAssertEqual(HistorySidebarPresentation.leadTextTopInset, OutlineSidebarView.sidebarLeadLineTop)
        XCTAssertEqual(HistorySidebarPresentation.leadTextFontSize, OutlineSidebarView.sidebarLeadLabelFontSize)
        func source(_ name: String) throws -> String {
            try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Lineform/Outline/\(name)"), encoding: .utf8)
        }
        let sidebar = try source("OutlineSidebarView.swift")
        // Outline: empty text and the heading list.
        XCTAssertEqual(sidebar.components(separatedBy: ".padding(.top, Self.sidebarLeadLineTop)").count - 1, 2)
        // Files: the sort row's own inset taken out of both gaps.
        XCTAssertTrue(sidebar.contains(".padding(.top, OutlineSidebarView.sidebarLeadLineTop - OutlineSidebarView.filesSortRowVerticalPadding)"))
        XCTAssertTrue(sidebar.contains("spacing: OutlineSidebarView.sidebarLeadToFirstRow - OutlineSidebarView.filesSortRowVerticalPadding"))
        XCTAssertTrue(sidebar.contains(".padding(.vertical, OutlineSidebarView.filesSortRowVerticalPadding)"))
        XCTAssertTrue(sidebar.contains(".font(.system(size: OutlineSidebarView.sidebarLeadLabelFontSize, weight: .medium))"))
        // Markdown Basics.
        let basics = try source("OutlineMarkdownBasicsTabView.swift")
        XCTAssertTrue(basics.contains(".padding(.top, OutlineSidebarView.sidebarLeadLineTop)"))
        XCTAssertTrue(basics.contains("Spacer().frame(height: OutlineSidebarView.sidebarLeadToFirstRow)"))
        // History: the lead line, then the first row (level switcher or versions).
        let history = try source("HistorySidebarView.swift")
        XCTAssertTrue(history.contains(".padding(.top, HistorySidebarPresentation.leadTextTopInset)"))
        XCTAssertTrue(history.contains(".padding(.top, OutlineSidebarView.sidebarLeadToFirstRow)"))
        XCTAssertTrue(history.contains("? 6 : OutlineSidebarView.sidebarLeadToFirstRow)"))
    }

    /// The hover pill is a faint fill — quieter than the Exit capsule — and the hovered ink still
    /// reads at ≥ 3:1 on it.
    @MainActor
    func testAddButtonHoverPillKeepsContrast() {
        for usesDarkChrome in [false, true] {
            let alpha = HistorySidebarPresentation.addButtonHoverFillOpacity(usesDarkChrome: usesDarkChrome)
            XCTAssertGreaterThan(alpha, 0)
            XCTAssertLessThanOrEqual(alpha, 0.12)
            let background = (usesDarkChrome
                ? OutlineSidebarView.darkBackgroundNSColor
                : NSColor(calibratedWhite: OutlineSidebarView.lightBackgroundWhiteComponent, alpha: 1))
                .usingColorSpace(.sRGB)!
            let overlay: CGFloat = usesDarkChrome ? 1 : 0
            func mix(_ c: CGFloat) -> CGFloat { c * (1 - alpha) + overlay * alpha }
            let pill = NSColor(srgbRed: mix(background.redComponent), green: mix(background.greenComponent),
                               blue: mix(background.blueComponent), alpha: 1)
            let ink = NSColor(calibratedWhite: HistorySidebarPresentation.addButtonWhite(
                usesDarkChrome: usesDarkChrome, isHovered: true), alpha: 1)
            let ratio = Theme.contrastRatio(ink, pill)
            XCTAssertGreaterThanOrEqual(ratio, 3, "dark \(usesDarkChrome): \(ratio):1 on the pill")
            // Quieter than Exit: the pill sits closer to the sidebar than Exit's capsule does.
            let exitFill = NSColor(calibratedWhite: SidebarCapsuleButtonStyle.backgroundWhite(
                usesDarkChrome: usesDarkChrome, emphasis: .quiet, isHovered: false), alpha: 1)
            XCTAssertLessThan(Theme.contrastRatio(pill, background), Theme.contrastRatio(exitFill, background))
        }
    }

    /// The field's return button is enabled only for text that would add something.
    func testReturnButtonNeedsText() {
        var field = HistoryReplacementFieldState()
        XCTAssertFalse(field.canCommit, "closed")
        XCTAssertTrue(field.open(for: UUID()))
        XCTAssertFalse(field.canCommit, "empty")
        field.draft = "  \n\t "
        XCTAssertFalse(field.canCommit, "whitespace")
        field.draft = " gentle "
        XCTAssertTrue(field.canCommit)
        _ = field.close()
        XCTAssertFalse(field.canCommit)
    }

    /// Exit rides the History row of the tab picker, and only while History is on screen — the
    /// History content draws no header, so "History" appears once.
    func testExitSitsOnTheHistoryTabRowOnlyWhileHistoryIsShown() {
        for tab in OutlineSidebarTab.allCases {
            for effective in OutlineSidebarTab.allCases {
                XCTAssertEqual(OutlineSidebarTab.showsHistoryExit(on: tab, effectiveTab: effective),
                               tab == .history && effective == .history, "\(tab) \(effective)")
            }
        }
    }

    /// The hint sits on the empty-state text's 14pt inset (left-aligned, not centred).
    func testHintSharesTheEmptyStateInset() {
        XCTAssertEqual(HistorySidebarPresentation.textInset, 14)
    }

    /// Leaving History (Exit, Esc, typing) returns the sidebar to the tab it came from;
    /// entering it from another tab remembers that tab.
    func testExitReturnsToPreviousTab() {
        let entered = OutlineSidebarTab.historyModeTransition(isActive: true, selected: .files, previous: nil)
        XCTAssertEqual(entered.selected, .history)
        XCTAssertEqual(entered.previous, .files)
        let left = OutlineSidebarTab.historyModeTransition(isActive: false, selected: entered.selected, previous: entered.previous)
        XCTAssertEqual(left.selected, .files)
        XCTAssertNil(left.previous)
        // Already on History (the tab click remembered where it came from): nothing is overwritten.
        let clicked = OutlineSidebarTab.historyModeTransition(isActive: true, selected: .history, previous: .markdownBasics)
        XCTAssertEqual(clicked.selected, .history)
        XCTAssertEqual(clicked.previous, .markdownBasics)
        XCTAssertEqual(OutlineSidebarTab.historyModeTransition(isActive: false, selected: .history, previous: nil).selected, .outline)
    }

    /// One capsule for Files' Change/Choose and History's Exit/Add Alternative: the colours are
    /// the Files values, unchanged.
    @MainActor
    func testSidebarCapsuleColoursAreTheFilesValues() {
        typealias S = SidebarCapsuleButtonStyle
        XCTAssertEqual(S.backgroundWhite(usesDarkChrome: false, emphasis: .quiet, isHovered: false), 0.91)
        XCTAssertEqual(S.backgroundWhite(usesDarkChrome: false, emphasis: .quiet, isHovered: true), 0.86)
        XCTAssertEqual(S.backgroundWhite(usesDarkChrome: true, emphasis: .quiet, isHovered: false), 0.40)
        XCTAssertEqual(S.backgroundWhite(usesDarkChrome: true, emphasis: .quiet, isHovered: true), 0.48)
        XCTAssertEqual(S.backgroundWhite(usesDarkChrome: false, emphasis: .prominent, isHovered: false), 0.20)
        XCTAssertEqual(S.backgroundWhite(usesDarkChrome: true, emphasis: .prominent, isHovered: true), 1.0)
        XCTAssertEqual(S.textWhite(usesDarkChrome: false, emphasis: .quiet), 0.34)
        XCTAssertEqual(S.textWhite(usesDarkChrome: true, emphasis: .quiet), 0.98)
        XCTAssertEqual(S.textWhite(usesDarkChrome: false, emphasis: .prominent), 1.0)
        XCTAssertEqual(S.textWhite(usesDarkChrome: true, emphasis: .prominent), 0.10)
        XCTAssertEqual(S.fontSize, 11)
        XCTAssertEqual(S.horizontalPadding, 10)
        XCTAssertEqual(S.height, 22)
    }

    /// The field's focus is requested a runloop turn AFTER it is inserted: a focus write in the
    /// same pass as the insertion is dropped on macOS, and keystrokes then reach the editor.
    func testReplacementFieldFocusIsRequestedAfterInsertion() {
        var scheduled: [() -> Void] = []
        var focused = false
        HistorySidebarPresentation.requestReplacementFieldFocus(schedule: { scheduled.append($0) }) { focused = true }
        XCTAssertFalse(focused, "not in the insertion pass")
        XCTAssertEqual(scheduled.count, 1)
        scheduled.forEach { $0() }
        XCTAssertTrue(focused)
    }
    /// The replacement field belongs to the passage it was opened for: when the selected passage
    /// changes (a level button, which takes no focus from the field) it closes, and Return can
    /// only ever commit for that passage.
    func testReplacementFieldClosesWhenTheSelectedPassageChanges() throws {
        let sentence = UUID()
        let paragraph = UUID()
        var field = HistoryReplacementFieldState()
        XCTAssertFalse(field.open(for: nil), "nothing selected, nothing to replace")
        XCTAssertFalse(field.isOpen)
        XCTAssertTrue(field.open(for: sentence))
        field.draft = "Sentence text."
        XCTAssertFalse(field.selectionChanged(to: sentence), "same passage: stays open")
        XCTAssertTrue(field.isOpen)
        XCTAssertTrue(field.selectionChanged(to: paragraph), "another passage: closes, and reports it ended")
        XCTAssertFalse(field.isOpen)
        XCTAssertEqual(field.draft, "")
        XCTAssertNil(field.commit(), "nothing to commit once closed")

        XCTAssertTrue(field.open(for: paragraph))
        field.draft = "Whole paragraph."
        let committed = try XCTUnwrap(field.commit())
        XCTAssertEqual(committed.text, "Whole paragraph.")
        XCTAssertEqual(committed.passageID, paragraph)
        XCTAssertFalse(field.isOpen)
    }

    /// Torn down while open (sidebar hidden with History still on): closing reports the end once,
    /// so the editor's `historyReplacementFieldIsOpen` cannot stay stuck.
    func testReplacementFieldCloseReportsOnlyWhenOpen() {
        var field = HistoryReplacementFieldState()
        XCTAssertFalse(field.close())
        _ = field.open(for: UUID())
        XCTAssertTrue(field.close())
        XCTAssertFalse(field.close(), "a second close (focus loss after disappear) reports nothing")
    }
}
