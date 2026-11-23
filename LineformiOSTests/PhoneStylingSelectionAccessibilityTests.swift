import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformCore
@testable import LineformiOS

/// The Styling sheet, the selection row and the comment field for VoiceOver and Dynamic Type users:
/// at the default size and at AX5 every element is inside the window, every control is labelled
/// and a 44 pt target, the sliders and switches are one stop each, the row says it appeared, and
/// the comment field cancels on escape and moves VoiceOver to its note. Runs in English and German.
@MainActor
final class PhoneStylingSelectionAccessibilityTests: XCTestCase {
    private var suites: [String] = []
    private var window: UIWindow?
    private static let sizes: [UIContentSizeCategory] = [.large, .accessibilityExtraExtraExtraLarge]
    private static let tallSheet = CGSize(width: 402, height: 3600)

    override func tearDown() {
        window?.isHidden = true
        window = nil
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    // MARK: - Styling sheet

    private func makeProfileStore() throws -> ReadingProfileStore {
        let suite = "PhoneStylingA11y-\(UUID().uuidString)"
        suites.append(suite)
        return ReadingProfileStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    func testStylingSheetFitsAndEveryControlIsALabelled44PointTarget() async throws {
        for size in Self.sizes {
            let store = try makeProfileStore()
            // The picker's button speaks its title and the chosen font.
            let fontName = try XCTUnwrap(
                FontOption.option(for: ReadingExperienceControls.visibleFontID(for: store.activeProfile))?.name
            )
            let fontPickerLabel = "\(StylingSheet.fontTitle), \(fontName)"
            // Tall enough for the whole sheet, so every row is laid out and measured.
            let host = try await PhoneAccessibilityHost(
                StylingSheet(store: store), contentSize: size, size: Self.tallSheet
            )
            defer { host.tearDown() }
            host.assertElementsInsideWindow()
            host.assertInteractiveElementsAreLabelledAndLargeEnough(allowlist: [
                // System controls at their own regular size, kept to match the Mac panel: the
                // bordered Reset button (about 30 pt tall at the default size) and the menu-style
                // Font picker (about 34 pt; a frame does not grow it). Both reach 44 pt at the
                // accessibility sizes.
                StylingSheet.resetTitle,
                fontPickerLabel,
            ])
            host.assertLabelsAreNotTruncated()
        }
    }

    func testStylingTextScalesWithDynamicType() async throws {
        let store = try makeProfileStore()
        func headerHeight(_ size: UIContentSizeCategory) async throws -> CGFloat {
            let host = try await PhoneAccessibilityHost(StylingSheet(store: store), contentSize: size)
            defer { host.tearDown() }
            let header = try XCTUnwrap(host.elements().first { $0.label == StylingSheet.headerTitle })
            return header.frame.height
        }
        let regular = try await headerHeight(.large)
        let large = try await headerHeight(.accessibilityExtraExtraExtraLarge)
        XCTAssertGreaterThan(large, regular * 2, "the header grows with the text size (\(regular) → \(large))")
    }

    func testSliderRowIsOneAdjustableStopThatStepsTheProfile() async throws {
        let store = try makeProfileStore()
        let host = try await PhoneAccessibilityHost(StylingSheet(store: store), contentSize: .large)
        defer { host.tearDown() }
        let elements = host.elements()
        let fontSize = elements.filter { $0.label == StylingSheet.fontSizeTitle }
        XCTAssertEqual(fontSize.count, 1, "one stop for the Font Size row: \(elements)")
        let row = try XCTUnwrap(fontSize.first)
        XCTAssertTrue(row.traits.contains(.adjustable))
        let valueText = ReadingExperienceControls.valueText(for: \.fontSize, in: store.activeProfile)
        XCTAssertEqual(row.object.accessibilityValue, valueText)
        // The value text is not a second stop.
        XCTAssertFalse(elements.contains { ($0.label ?? "").contains(valueText) }, "\(elements)")

        let before = store.activeProfile.fontSize
        row.object.accessibilityIncrement()
        await host.settle()
        XCTAssertEqual(store.activeProfile.fontSize, before.rounded(.down) + 1)
        row.object.accessibilityDecrement()
        row.object.accessibilityDecrement()
        await host.settle()
        XCTAssertEqual(store.activeProfile.fontSize, before.rounded(.down) - 1)

        // The qualifier is spoken with its title, as one name.
        let blockSpacing = StylingRowStyle.accessibilityTitle(
            title: StylingSheet.blockSpacingTitle, subtitle: StylingSheet.blockSpacingQualifier
        )
        XCTAssertEqual(elements.filter { $0.label == blockSpacing }.count, 1, "\(elements)")
    }

    func testToggleRowIsOneStopWithTheDescriptionAsHint() async throws {
        let store = try makeProfileStore()
        let host = try await PhoneAccessibilityHost(StylingSheet(store: store), contentSize: .large)
        defer { host.tearDown() }
        let elements = host.elements()
        XCTAssertFalse(elements.contains { $0.label == StylingSheet.readingRulerDescription }, "the description is the hint")
        let rows = elements.filter { $0.label == StylingSheet.readingRulerTitle }
        XCTAssertEqual(rows.count, 1, "\(elements)")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.object.accessibilityHint, StylingSheet.readingRulerDescription)
        XCTAssertEqual(row.object.accessibilityValue, StylingRowStyle.toggleAccessibilityValue(false))
        XCTAssertGreaterThanOrEqual(row.frame.height, 44)

        XCTAssertFalse(store.activeProfile.readingRulerEnabled)
        XCTAssertTrue(row.object.accessibilityActivate())
        await host.settle()
        XCTAssertTrue(store.activeProfile.readingRulerEnabled)
    }

    func testPresetGridUsesFewerColumnsAtAccessibilitySizes() {
        XCTAssertEqual(StylingSheet.presetGridColumnCount(for: .large), 3)
        XCTAssertEqual(StylingSheet.presetGridColumnCount(for: .xxxLarge), 3)
        XCTAssertEqual(StylingSheet.presetGridColumnCount(for: .accessibility1), 2)
        XCTAssertEqual(StylingSheet.presetGridColumnCount(for: .accessibility2), 2)
        XCTAssertEqual(StylingSheet.presetGridColumnCount(for: .accessibility3), 1)
        XCTAssertEqual(StylingSheet.presetGridColumnCount(for: .accessibility5), 1)
    }

    func testPresetCardsStayInsideTheWindowAtAX5() async throws {
        let store = try makeProfileStore()
        let host = try await PhoneAccessibilityHost(
            StylingSheet(store: store), contentSize: .accessibilityExtraExtraExtraLarge, size: Self.tallSheet
        )
        defer { host.tearDown() }
        let width = host.window.bounds.width
        let cards = host.elements().filter { element in
            ReadingPreset.builtIn.contains { StylingPresetCard.accessibilityLabel(for: $0) == element.label }
        }
        XCTAssertFalse(cards.isEmpty)
        for card in cards {
            XCTAssertGreaterThan(card.frame.width, width / 2, "one column at AX5: \(card)")
        }
    }

    func testAccessibilityTitleIsALocalizedFormat() {
        let joined = StylingRowStyle.accessibilityTitle(title: "A", subtitle: "B")
        XCTAssertTrue(joined.hasPrefix("A") && joined.hasSuffix("B"), joined)
        XCTAssertEqual(StylingRowStyle.accessibilityTitle(title: "A", subtitle: nil), "A")
    }

    func testAccessibilityStepsMoveToTheNextMultiple() {
        XCTAssertEqual(StylingRowStyle.adjusted(17, by: 1, increment: true, in: 12...48), 18)
        XCTAssertEqual(StylingRowStyle.adjusted(17.4, by: 1, increment: true, in: 12...48), 18)
        XCTAssertEqual(StylingRowStyle.adjusted(17.4, by: 1, increment: false, in: 12...48), 17)
        XCTAssertEqual(StylingRowStyle.adjusted(48, by: 1, increment: true, in: 12...48), 48)
        XCTAssertEqual(StylingRowStyle.adjusted(12, by: 1, increment: false, in: 12...48), 12)
        XCTAssertEqual(StylingRowStyle.adjusted(1.2, by: 0.05, increment: true, in: 0.5...1.8), 1.25, accuracy: 1e-9)
        XCTAssertEqual(StylingRowStyle.adjusted(1.2, by: 0.05, increment: false, in: 0.5...1.8), 1.15, accuracy: 1e-9)
        XCTAssertEqual(StylingSheet.accessibilityStep(for: \.fontSize), 1)
        XCTAssertEqual(StylingSheet.accessibilityStep(for: \.lineHeightMultiple), 0.05)
        XCTAssertEqual(StylingSheet.accessibilityStep(for: \.paragraphSpacing), 1)
        XCTAssertEqual(StylingSheet.accessibilityStep(for: \.letterSpacing), 0.1)
        XCTAssertEqual(StylingSheet.accessibilityStep(for: \.columnWidth), 20)
    }

    func testSecondaryStylingInkIsReadableOnEveryPreset() {
        for preset in ReadingPreset.builtIn {
            let theme = Theme.theme(for: preset.profile)
            let inks = PhoneInk(theme: theme, userInterfaceStyle: theme.usesDarkChrome ? .dark : .light)
            XCTAssertGreaterThanOrEqual(Theme.contrastRatio(inks.uiColor(.secondary), inks.page), 4.5, preset.title)
        }
    }

    // MARK: - Selection row

    private func makeController(_ text: String, connected: Bool) throws -> (SelectionController, LineformTextView) {
        let suite = "PhoneSelectionA11y-\(UUID().uuidString)"
        suites.append(suite)
        let store = AIConnectionStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), keychain: InMemoryAIKeychain())
        if connected { XCTAssertNil(store.connect(.claude, key: "sk-test")) }
        let client = FakeAIClient(.suspend)
        let ai = AIActionController(connectionStore: store, clientFactory: { _ in client })
        let controller = SelectionController(connectionStore: { store }, aiController: ai)
        let editor = LineformTextView.make(profile: .original)
        editor.setDocumentText(text)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        editor.frame = CGRect(x: 0, y: 0, width: 393, height: 400)
        root.view.addSubview(editor)
        window.makeKeyAndVisible()
        self.window = window
        editor.becomeFirstResponder()
        controller.attach(editor)
        editor.selectedRange = NSRange(location: 0, length: 5)
        controller.showRowNow()
        XCTAssertEqual(controller.phase, .row)
        return (controller, editor)
    }

    func testSelectionRowItemsAreLabelled44PointTargetsAtEverySize() async throws {
        let (controller, editor) = try makeController("Hello world\n", connected: true)
        _ = editor
        for size in Self.sizes {
            let row = SelectionRow(controller: controller, profile: .original)
                .padding(.horizontal, MarkdownEditor.chromeMargin)
            let host = try await PhoneAccessibilityHost(row, contentSize: size)
            defer { host.tearDown() }
            let items = host.elements().filter(\.isInteractive)
            XCTAssertGreaterThanOrEqual(items.count, 4, "\(host.elements())")
            let windowFrame = host.windowFrameOnScreen
            // The visible ones: the row scrolls sideways, so later items may sit past the edge.
            for item in items where item.frame.minX < windowFrame.maxX {
                XCTAssertEqual(item.frame.height, SelectionRow.itemTargetSide, accuracy: 0.5, "\(item) at \(size.rawValue)")
                XCTAssertGreaterThanOrEqual(item.frame.width, SelectionRow.itemTargetSide - 0.5, "\(item)")
                XCTAssertFalse((item.label ?? "").isEmpty)
            }
            let askAI = SelectionRowItem.askAI.title(aiName: controller.model.aiName)
            let ask = try XCTUnwrap(items.first { $0.label == askAI }, "\(items)")
            XCTAssertLessThanOrEqual(ask.frame.height, SelectionRow.height, "the text item fits the row at \(size.rawValue)")
            host.assertLabelsAreNotTruncated()
        }
    }

    func testSelectionRowAnnouncesItselfQuietlyOnceUnderVoiceOver() throws {
        let saved = SelectionRow.didAnnounceThisSession
        defer { SelectionRow.didAnnounceThisSession = saved }
        SelectionRow.didAnnounceThisSession = false
        var posted: [AttributedString] = []
        XCTAssertFalse(SelectionRow.announceAppearance(isVoiceOverRunning: false) { posted.append($0) })
        XCTAssertTrue(posted.isEmpty)
        XCTAssertTrue(SelectionRow.announceAppearance(isVoiceOverRunning: true) { posted.append($0) })
        let announcement = try XCTUnwrap(posted.first)
        XCTAssertEqual(String(announcement.characters), SelectionRow.appearanceAnnouncement)
        XCTAssertEqual(announcement.accessibilitySpeechAnnouncementPriority, .low, "queued, never interrupting")
        XCTAssertFalse(SelectionRow.appearanceAnnouncement.isEmpty)
        // The row comes back on every selection; VoiceOver hears it once per session.
        XCTAssertFalse(SelectionRow.announceAppearance(isVoiceOverRunning: true) { posted.append($0) })
        XCTAssertEqual(posted.count, 1)
    }

    func testSelectionRowAnnouncementIsEnglishSourceText() throws {
        try skipUnlessEnglishInterface()
        XCTAssertEqual(SelectionRow.appearanceAnnouncement, "Formatting options available at the bottom of the screen.")
    }

    // MARK: - Comment field

    private func openComment() throws -> (SelectionController, LineformTextView) {
        let (controller, editor) = try makeController("Hello there world\n", connected: true)
        controller.perform(.askAI)
        XCTAssertEqual(controller.phase, .comment)
        return (controller, editor)
    }

    func testCommentFieldControlsAreLabelled44PointTargetsAtEverySize() async throws {
        let (controller, editor) = try openComment()
        _ = editor
        for size in Self.sizes {
            let field = CommentField(controller: controller, profile: .original).padding(.horizontal, 8)
            let host = try await PhoneAccessibilityHost(field, contentSize: size)
            defer { host.tearDown() }
            host.assertElementsInsideWindow()
            host.assertInteractiveElementsAreLabelledAndLargeEnough()
            let elements = host.elements()
            let send = try XCTUnwrap(elements.first { $0.label == SelectionToolbarPresentation.sendTitle }, "\(elements)")
            XCTAssertGreaterThanOrEqual(send.frame.width, 44)
            XCTAssertGreaterThanOrEqual(send.frame.height, 44)
            let action = try XCTUnwrap(elements.first { $0.label == SelectionToolbarPresentation.actionLabel }, "\(elements)")
            XCTAssertEqual(action.object.accessibilityValue, SelectionToolbarPresentation.menuTitle(for: controller.model.action))
            XCTAssertTrue(elements.contains { $0.label == String(localized: "Cancel") && $0.isInteractive })
            if size.isAccessibilityCategory {
                // Stacked: Send sits below the Action menu, not beside it.
                XCTAssertGreaterThanOrEqual(send.frame.minY, action.frame.maxY - 0.5, "\(send) \(action)")
            } else {
                XCTAssertLessThan(abs(send.frame.midY - action.frame.midY), 4, "side by side at the default size")
            }
        }
    }

    func testCommentFieldEscapeCancels() async throws {
        let (controller, editor) = try openComment()
        _ = editor
        let host = try await PhoneAccessibilityHost(CommentField(controller: controller, profile: .original))
        defer { host.tearDown() }
        // VoiceOver sends escape to the focused element, then up its containers until one handles it.
        let send = try XCTUnwrap(host.elements().first { $0.label == SelectionToolbarPresentation.sendTitle })
        var current: NSObject? = send.object
        var handled = false
        var depth = 0
        while let object = current, !handled, depth < 40 {
            handled = object.accessibilityPerformEscape()
            if let element = object as? UIAccessibilityElement {
                current = element.accessibilityContainer as? NSObject
            } else if let view = object as? UIView {
                current = view.superview
            } else {
                current = (object.value(forKey: "accessibilityContainer") as? NSObject)
            }
            depth += 1
        }
        XCTAssertTrue(handled, "an element in the field handles escape")
        XCTAssertNotEqual(controller.phase, .comment)
    }

    func testNoteHeightCapScalesWithTextUpToTwice() {
        XCTAssertEqual(CommentNoteView.maximumHeight(for: UITraitCollection(preferredContentSizeCategory: .large)), 120, accuracy: 0.5)
        let ax5 = CommentNoteView.maximumHeight(for: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        XCTAssertEqual(ax5, 240, accuracy: 0.5)
        let xxl = CommentNoteView.maximumHeight(for: UITraitCollection(preferredContentSizeCategory: .extraExtraLarge))
        XCTAssertGreaterThan(xxl, 120)
        XCTAssertLessThan(xxl, 240)
    }

    func testNoteFocusMovesVoiceOverOnlyWhenRunning() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let note = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        window.addSubview(note)
        window.makeKeyAndVisible()
        self.window = window
        var posted: [(UIAccessibility.Notification, Any?)] = []
        CommentNoteView.focus(note, isVoiceOverRunning: false) { posted.append(($0, $1)) }
        XCTAssertTrue(note.isFirstResponder)
        XCTAssertTrue(posted.isEmpty)
        CommentNoteView.focus(note, isVoiceOverRunning: true) { posted.append(($0, $1)) }
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first?.0, .layoutChanged)
        XCTAssertTrue((posted.first?.1 as AnyObject?) === note)
    }
}
