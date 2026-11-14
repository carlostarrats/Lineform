import XCTest
@testable import Lineform

/// The review overlay's text view, without a window (window-hosted checks belong in
/// LineformHosted; the controller does the hands-on pass).
@MainActor
final class AIReviewTextViewTests: XCTestCase {
    private let text = "A very big day.\n\nThe good night."
    private let profile = ReadingProfile.original

    private func composition() -> (AIReviewComposition, AIReviewSession) {
        let ns = text as NSString
        let changes = [
            AIChange(id: 0, range: ns.range(of: "very "), original: "very ", replacement: ""),
            AIChange(id: 1, range: ns.range(of: "big"), original: "big", replacement: "large"),
            AIChange(id: 2, range: ns.range(of: "good"), original: "good", replacement: "fine"),
        ]
        let session = AIReviewSession(action: .trim, changes: changes,
                                      selectionRange: NSRange(location: 0, length: ns.length), originalSelection: text)
        return (AIReviewComposition.build(text: text, session: session), session)
    }

    private func presented(currentID: Int? = 0) -> (AIReviewTextView, AIReviewComposition, [AIReviewCommand]) {
        let view = AIReviewTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.textContainer?.containerSize = NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude)
        let (composition, _) = composition()
        view.present(composition, currentID: currentID, profile: profile)
        return (view, composition, [])
    }

    func testIsReadOnlyWithNoMenuSpellingOrUndo() throws {
        let (view, _, _) = presented()
        XCTAssertFalse(view.isEditable)
        XCTAssertFalse(view.isSelectable)
        XCTAssertFalse(view.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
        if #available(macOS 15.0, *) {
            XCTAssertEqual(view.writingToolsBehavior, .none)
        }
        XCTAssertTrue(view.acceptsFirstResponder, "the overlay takes the keys during review")
        let manager = try XCTUnwrap(view.undoManager)
        XCTAssertFalse(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        XCTAssertNil(view.menu(for: event))
    }

    func testKeysBecomeReviewCommands() {
        let (view, _, _) = presented()
        var commands: [AIReviewCommand] = []
        view.commandHandler = { commands.append($0) }
        view.doCommand(by: #selector(NSResponder.moveRight(_:)))
        view.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(commands, [.acceptCurrent, .end, .typed("x")], "← / → decide nothing: there is one change")
        XCTAssertEqual(view.string, composition().0.string, "typing never lands in the overlay")
    }

    /// Real key events, not only selectors: a non-editable, non-selectable NSTextView still runs
    /// them through key binding (`interpretKeyEvents`) into `doCommand(by:)` / `insertText`.
    func testKeyEventsReachTheCommandPath() throws {
        let (view, _, _) = presented()
        var commands: [AIReviewCommand] = []
        view.commandHandler = { commands.append($0) }
        func key(_ characters: String, _ code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        view.keyDown(with: try key(String(UnicodeScalar(NSRightArrowFunctionKey)!), 124))
        view.keyDown(with: try key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123))
        view.keyDown(with: try key("\r", 36))
        view.keyDown(with: try key("\u{1b}", 53))
        view.keyDown(with: try key("q", 12))
        XCTAssertEqual(commands, [.acceptCurrent, .end, .typed("q")])
    }

    /// Option A: the original struck through in the receded ink, the replacement on the review
    /// highlight. All of it is drawing (layout-manager temporary attributes): the storage holds
    /// only text, with no attachment anywhere.
    func testPresentStrikesTheOriginalAndHighlightsTheReplacement() throws {
        let (view, composition, _) = presented(currentID: 1)
        let theme = Theme.theme(for: profile)
        XCTAssertEqual(view.string, composition.string)
        let storage = try XCTUnwrap(view.textStorage)
        let layoutManager = try XCTUnwrap(view.layoutManager)
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            XCTAssertNil(value, "no pills")
        }
        XCTAssertFalse(composition.removedRanges.isEmpty)
        for range in composition.removedRanges.values.flatMap({ $0 }) {
            for index in range.location..<NSMaxRange(range) {
                XCTAssertEqual(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor,
                               HistoryPalette.recededInk(for: theme))
                XCTAssertEqual(layoutManager.temporaryAttribute(.strikethroughStyle, atCharacterIndex: index, effectiveRange: nil) as? Int,
                               NSUnderlineStyle.single.rawValue)
                XCTAssertNil(layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil))
            }
        }
        XCTAssertFalse(composition.replacementRanges.isEmpty)
        for range in composition.replacementRanges.values.flatMap({ $0 }) {
            for index in range.location..<NSMaxRange(range) {
                XCTAssertEqual(layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor,
                               HistoryPalette.reviewInsertTint(for: theme))
                XCTAssertNil(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil),
                             "the replacement keeps the normal ink")
                XCTAssertNil(layoutManager.temporaryAttribute(.strikethroughStyle, atCharacterIndex: index, effectiveRange: nil))
            }
        }
        let plain = (composition.string as NSString).range(of: "night")
        XCTAssertNil(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: plain.location, effectiveRange: nil))
        XCTAssertNil(layoutManager.temporaryAttribute(.strikethroughStyle, atCharacterIndex: plain.location, effectiveRange: nil))
        XCTAssertNil(layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: plain.location, effectiveRange: nil))
    }

    /// A replacement's link and code are drawn readable ON the tint (≥ 4.5:1), on every theme —
    /// not at the page's ratio, which the tint takes them under.
    func testReplacementLinkAndCodeInksReadOnTheTint() throws {
        let doc = "Old line here.\nAfter."
        let ns = doc as NSString
        let change = AIChange(id: 0, range: ns.range(of: "Old line here."), original: "Old line here.",
                              replacement: "See [the guide](guide.md) and `make test` now.")
        let session = AIReviewSession(action: .rewrite, changes: [change],
                                      selectionRange: NSRange(location: 0, length: ns.length), originalSelection: doc)
        let composition = AIReviewComposition.build(text: doc, session: session)
        let shown = composition.string as NSString
        for preset in ReadingPreset.builtIn {
            let profile = preset.profile
            let theme = Theme.theme(for: profile)
            let tint = HistoryPalette.reviewInsertTint(for: theme)
            let view = AIReviewTextView.make()
            view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            view.present(composition, currentID: 0, profile: profile)
            let layoutManager = try XCTUnwrap(view.layoutManager)
            let storage = try XCTUnwrap(view.textStorage)
            for needle in ["the guide", "make test"] {
                let index = shown.range(of: needle).location
                let drawn = (layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor)
                    ?? (storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor)
                let ratio = Theme.contrastRatio(try XCTUnwrap(drawn), tint)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme.name) \(needle) on the tint was \(ratio)")
            }
            let plain = shown.range(of: " now.").location
            XCTAssertNil(layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: plain, effectiveRange: nil),
                         "\(theme.name): body text keeps the normal ink")
        }
    }

    /// Clicks decide nothing: there are no pills, and the original is no longer a keep toggle.
    func testClicksDecideNothing() throws {
        let (view, composition, _) = presented()
        var commands: [AIReviewCommand] = []
        view.commandHandler = { commands.append($0) }
        let layoutManager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layoutManager.ensureLayout(for: container)
        let origin = view.textContainerOrigin
        let targets = composition.removedRanges.values.flatMap { $0 } + composition.replacementRanges.values.flatMap { $0 }
            + [(composition.string as NSString).range(of: "night")]
        for range in targets {
            let rect = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                                  in: container).offsetBy(dx: origin.x, dy: origin.y)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: rect.midX, y: rect.midY),
                                                         modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1))
            view.mouseDown(with: event)
        }
        XCTAssertEqual(commands, [])
    }

    func testCustomActionsAreAcceptRejectAndEnd() throws {
        let (view, _, _) = presented()
        var commands: [AIReviewCommand] = []
        view.commandHandler = { commands.append($0) }
        let actions = view.accessibilityCustomActions() ?? []
        XCTAssertEqual(actions.map(\.name), ["Accept Change", "Reject Change", "End Review"])
        XCTAssertEqual(actions.map(\.name), AIReviewTextView.accessibilityActionTitles())
        for action in actions { _ = action.handler?() }
        XCTAssertEqual(commands, [.accept(0), .reject(0), .end])
    }

    func testWithNoCurrentChangeOnlyEndIsOffered() {
        let (view, _, _) = presented(currentID: nil)
        XCTAssertEqual((view.accessibilityCustomActions() ?? []).map(\.name), ["End Review"])
    }

    func testMatchGeometryCopiesTheEditorsLayout() throws {
        let editor = LineformTextView()
        editor.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        editor.applyTypography(profile)
        editor.string = text
        let overlay = AIReviewTextView.make()
        overlay.matchGeometry(of: editor)
        XCTAssertEqual(overlay.textContainerInset, editor.textContainerInset)
        XCTAssertEqual(overlay.textContainer?.lineFragmentPadding, editor.textContainer?.lineFragmentPadding)
        XCTAssertEqual(overlay.textContainer?.containerSize.width, editor.textContainer?.containerSize.width)
        XCTAssertEqual(overlay.frame.width, editor.frame.width)
        XCTAssertEqual(overlay.backgroundColor, editor.backgroundColor)
        XCTAssertEqual(overlay.defaultParagraphStyle, editor.defaultParagraphStyle)
    }

    // MARK: - Key routing to the editor (dead keys, input methods, plain text)

    private func key(_ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    func testOnlyNonReviewKeysWithoutCommandOrControlGoToTheEditor() throws {
        let arrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        XCTAssertTrue(AIReviewTextView.handsOffToEditor(try key("q", 12)))
        XCTAssertTrue(AIReviewTextView.handsOffToEditor(try key("e", 14, .option)), "⌥E starts a dead key")
        XCTAssertTrue(AIReviewTextView.handsOffToEditor(try key("^", 33, .shift)))
        XCTAssertTrue(AIReviewTextView.handsOffToEditor(try key("\u{7f}", 51)), "Delete edits, so it ends the review")
        XCTAssertFalse(AIReviewTextView.handsOffToEditor(try key(arrow, 124)))
        XCTAssertFalse(AIReviewTextView.handsOffToEditor(try key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123)))
        XCTAssertFalse(AIReviewTextView.handsOffToEditor(try key("\r", 36)))
        XCTAssertFalse(AIReviewTextView.handsOffToEditor(try key("\u{3}", 76)), "keypad Enter")
        XCTAssertFalse(AIReviewTextView.handsOffToEditor(try key("\u{1b}", 53)))
        XCTAssertFalse(AIReviewTextView.handsOffToEditor(try key(String(UnicodeScalar(NSPageDownFunctionKey)!), 121)))
        XCTAssertFalse(AIReviewTextView.handsOffToEditor(try key(String(UnicodeScalar(NSHomeFunctionKey)!), 115)))
        XCTAssertFalse(AIReviewTextView.handsOffToEditor(try key("z", 6, .command)), "⌘Z stays with the menus")
        XCTAssertFalse(AIReviewTextView.handsOffToEditor(try key("a", 0, .control)))
        XCTAssertFalse(AIReviewTextView.handsOffToEditor(try key(String(UnicodeScalar(NSF5FunctionKey)!), 96)))
    }

    func testATypedKeyEndsTheReviewAndIsHandledByTheEditor() throws {
        let (view, _, _) = presented()
        let editor = LineformTextView()
        editor.string = text
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.isAIReviewActive = true
        view.handOffEditor = editor
        var commands: [AIReviewCommand] = []
        view.commandHandler = { commands.append($0) }

        view.keyDown(with: try key(String(UnicodeScalar(NSRightArrowFunctionKey)!), 124))
        XCTAssertEqual(commands, [], "an arrow stays in the review and decides nothing")
        XCTAssertEqual(editor.string, text)

        view.keyDown(with: try key("q", 12))
        XCTAssertEqual(commands, [.end], "the review ends first, synchronously")
        XCTAssertFalse(editor.isAIReviewActive, "the backstop is down before the key arrives")
        XCTAssertEqual(view.string, composition().0.string, "nothing lands in the overlay")

        // The re-sent event is handled by the editor's OWN keyDown (its input context: plain
        // text, dead keys, input methods). LineformTextView's keyDown types nothing without a
        // window (a test-host limit; `interpretKeyEvents` does), so a plain text view stands in
        // to prove the event arrives and types.
        let plain = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        plain.string = "abc"
        plain.setSelectedRange(NSRange(location: 0, length: 0))
        view.handOffEditor = plain
        view.keyDown(with: try key("q", 12))
        XCTAssertEqual(plain.string, "qabc")
        XCTAssertEqual(commands, [.end, .end])

        // Without an editor to hand to, typing still ends the review through `insertText`.
        view.handOffEditor = nil
        view.keyDown(with: try key("w", 13))
        XCTAssertEqual(commands.last, .typed("w"))
    }

    /// Critical: ⌫ after a review must not delete the reviewed passage. It ends the review (the
    /// controller collapses the selection to the passage's end) and is NOT re-sent, so it deletes
    /// nothing — not the passage, and not its last character.
    func testDeleteEndsTheReviewWithoutDeletingThePassage() async throws {
        let (view, _, _) = presented()
        let backspace = try key("\u{7f}", 51)

        // Through the real controller and the real editor.
        let suite = "AIReviewTextViewTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = AIConnectionStore(defaults: UserDefaults(suiteName: suite)!, keychain: InMemoryAIKeychain())
        XCTAssertNil(store.connect(.claude, key: "test-key-not-real"))
        let fake = FakeAIClient(FakeAIClient.revising { _, segment in segment.replacingOccurrences(of: "big", with: "large") })
        let controller = AIActionController(connectionStore: store) { _ in fake }
        let editor = LineformTextView()
        editor.string = text
        controller.editor = editor
        let passage = (text as NSString).range(of: "A very big day.")
        controller.run(.rewrite, range: passage, text: text)
        await controller.runTask?.value
        guard case .reviewing = controller.state else { return XCTFail("expected a review, got \(controller.state)") }
        editor.setSelectedRange(passage)
        editor.isAIReviewActive = true
        view.handOffEditor = editor
        view.commandHandler = { controller.handle($0) }
        view.keyDown(with: backspace)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(editor.string, text, "the passage is intact")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: NSMaxRange(passage), length: 0))

        // The key is not re-sent: a plain text view (which DOES type without a window) proves it.
        let plain = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        plain.string = "abc"
        plain.setSelectedRange(NSRange(location: 0, length: 3))
        var commands: [AIReviewCommand] = []
        view.commandHandler = { commands.append($0) }
        view.handOffEditor = plain
        view.keyDown(with: backspace)
        XCTAssertEqual(commands, [.end])
        XCTAssertEqual(plain.string, "abc")
    }

    private func assertSameDrawing(_ a: AIReviewTextView, _ b: AIReviewTextView, _ label: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let sa = try XCTUnwrap(a.textStorage), sb = try XCTUnwrap(b.textStorage)
        XCTAssertEqual(sa.string, sb.string, label, file: file, line: line)
        guard sa.length == sb.length else { return }
        for index in 0..<sa.length {
            let x = sa.attributes(at: index, effectiveRange: nil), y = sb.attributes(at: index, effectiveRange: nil)
            XCTAssertEqual(x[.foregroundColor] as? NSColor, y[.foregroundColor] as? NSColor, "\(label) ink at \(index)", file: file, line: line)
            XCTAssertEqual(x[.font] as? NSFont, y[.font] as? NSFont, "\(label) font at \(index)", file: file, line: line)
            XCTAssertNil(x[.attachment], "\(label) attachment at \(index)", file: file, line: line)
            let ta = a.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
            let tb = b.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
            XCTAssertEqual(ta, tb, "\(label) dimming at \(index)", file: file, line: line)
            let sa = a.layoutManager?.temporaryAttribute(.strikethroughStyle, atCharacterIndex: index, effectiveRange: nil) as? Int
            let sb = b.layoutManager?.temporaryAttribute(.strikethroughStyle, atCharacterIndex: index, effectiveRange: nil) as? Int
            XCTAssertEqual(sa, sb, "\(label) strikethrough at \(index)", file: file, line: line)
            let ba = a.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
            let bb = b.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
            XCTAssertEqual(ba, bb, "\(label) highlight at \(index)", file: file, line: line)
            if x[.foregroundColor] as? NSColor != y[.foregroundColor] as? NSColor || ta != tb || sa != sb || ba != bb { return }
        }
    }

    /// Minor 8: a decision re-presents only the span that changed, and draws exactly what a
    /// whole pass draws (highlighting, strikethrough, dimming, the replacement highlight).
    func testADecisionRedrawsOnlyItsSpanAndMatchesAWholePass() throws {
        let doc = "# A *big* title\n\nThe big dog ran `far` away from **home**.\n\n- A good item\n- Last one here"
        let ns = doc as NSString
        let changes = [
            AIChange(id: 0, range: ns.range(of: "big dog"), original: "big dog", replacement: "dog"),
            AIChange(id: 1, range: ns.range(of: "away"), original: "away", replacement: "off"),
            AIChange(id: 2, range: ns.range(of: "good"), original: "good", replacement: "fine"),
        ]
        var session = AIReviewSession(action: .trim, changes: changes, selectionRange: NSRange(location: 0, length: ns.length),
                                      originalSelection: doc)
        let view = AIReviewTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.present(AIReviewComposition.build(text: doc, session: session), currentID: session.currentID, profile: profile)
        var text = doc
        for step in ["reject", "accept", "rejectLast"] {
            switch step {
            case "reject": session.reject(0)
            case "rejectLast": session.reject(2)
            default:
                let edit = try XCTUnwrap(session.accept(1).first)
                text = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            }
            let composition = AIReviewComposition.build(text: text, session: session)
            view.present(composition, currentID: session.currentID, profile: profile)
            let fresh = AIReviewTextView.make()
            fresh.frame = view.frame
            fresh.present(composition, currentID: session.currentID, profile: profile)
            try assertSameDrawing(view, fresh, step)
        }
    }

    func testDifferingSpan() {
        XCTAssertNil(AIReviewTextView.differingSpan(from: "abc", to: "abc"))
        XCTAssertEqual(AIReviewTextView.differingSpan(from: "abXYcd", to: "abcd").map { [$0.old, $0.new] },
                       [NSRange(location: 2, length: 2), NSRange(location: 2, length: 0)])
        XCTAssertEqual(AIReviewTextView.differingSpan(from: "aa", to: "aaa").map { [$0.old, $0.new] },
                       [NSRange(location: 2, length: 0), NSRange(location: 2, length: 1)])
        XCTAssertEqual(AIReviewTextView.differingSpan(from: "", to: "x").map { [$0.old, $0.new] },
                       [NSRange(location: 0, length: 0), NSRange(location: 0, length: 1)])
    }

    /// Minor 8, as a ratio (never wall clock): on a large document a decision costs a small
    /// fraction of the first, whole present. Measured at 700 KB: ~600 ms whole, ~11 ms per decision.
    func testADecisionOnALargeDocumentCostsAFractionOfTheWholePass() throws {
        var paragraphs: [String] = []
        var index = 0
        while paragraphs.joined(separator: "\n\n").utf16.count < 300_000 {
            paragraphs.append("## Section \(index)\n\nThe big dog ran **far** away from `home` and [a link](x.md) number \(index). It was a very good day.\n\n- item one\n- item two")
            index += 1
        }
        let big = paragraphs.joined(separator: "\n\n")
        let ns = big as NSString
        let changes = [AIChange(id: 0, range: ns.range(of: "big"), original: "big", replacement: "large"),
                       AIChange(id: 1, range: ns.range(of: "far"), original: "far", replacement: "near")]
        var session = AIReviewSession(action: .trim, changes: changes, selectionRange: NSRange(location: 0, length: 200),
                                      originalSelection: ns.substring(with: NSRange(location: 0, length: 200)))
        let view = AIReviewTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 800)
        view.textContainer?.containerSize = NSSize(width: 660, height: CGFloat.greatestFiniteMagnitude)
        // As in the app (AIReviewSurfaceRepresentable): the overlay is a scroll view's document.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
        scrollView.documentView = view
        let first = CFAbsoluteTimeGetCurrent()
        view.present(AIReviewComposition.build(text: big, session: session), currentID: 0, profile: profile)
        let whole = CFAbsoluteTimeGetCurrent() - first
        session.reject(0)
        let decided = AIReviewComposition.build(text: big, session: session)
        let second = CFAbsoluteTimeGetCurrent()
        view.present(decided, currentID: session.currentID, profile: profile)
        let decision = CFAbsoluteTimeGetCurrent() - second
        XCTAssertEqual(view.string, decided.string)
        XCTAssertLessThan(decision, whole / 5, "decision \(decision)s vs whole \(whole)s")
    }

    func testSpokenValueIsTheComposition() {
        let (view, composition, _) = presented()
        XCTAssertEqual(view.accessibilityValue(), composition.string)
        XCTAssertFalse(view.accessibilityValue()?.contains("\u{FFFC}") ?? true)
    }

    // MARK: - Scroll hand-over by character

    private func scrolled<T: NSTextView>(_ textView: T) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.sizeToFit()
        return scrollView
    }

    func testScrollHandOverKeepsTheTopCharacterNotThePixelOffset() throws {
        let lines = (0..<80).map { "Line \($0) has a big word." }
        let document = lines.joined(separator: "\n")
        let ns = document as NSString
        // Long replacements on the first lines wrap, so past them the overlay is TALLER.
        var changes: [AIChange] = []
        var searchFrom = 0
        for id in 0..<10 {
            let range = ns.range(of: "big", range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            changes.append(AIChange(id: id, range: range, original: "big",
                                    replacement: String(repeating: "considerably larger ", count: 4)))
            searchFrom = NSMaxRange(range)
        }
        let review = AIReviewSession(action: .rewrite, changes: changes,
                                     selectionRange: NSRange(location: 0, length: ns.length), originalSelection: document)
        let composition = AIReviewComposition.build(text: document, session: review)

        let editor = AIReviewTextView.make()
        editor.string = document
        editor.font = .systemFont(ofSize: 13)
        let editorScroll = scrolled(editor)
        let overlay = AIReviewTextView.make()
        overlay.present(composition, currentID: 0, profile: profile)
        overlay.font = .systemFont(ofSize: 13)
        let overlayScroll = scrolled(overlay)

        // The editor shows line 40 at the top.
        let line40 = ns.range(of: "Line 40 ").location
        let editorY = try XCTUnwrap(AIReviewSurfaceRepresentable.originY(in: editor, showing: line40, offset: 0))
        AIReviewSurfaceRepresentable.scroll(editorScroll, toY: editorY)
        let anchor = try XCTUnwrap(AIReviewSurfaceRepresentable.topAnchor(of: editor))
        XCTAssertEqual(anchor.index, line40)

        // Make: mapped by character into the overlay.
        let overlayIndex = composition.overlayIndex(forDocumentIndex: anchor.index)
        let overlayY = try XCTUnwrap(AIReviewSurfaceRepresentable.originY(in: overlay, showing: overlayIndex, offset: anchor.offset))
        XCTAssertGreaterThan(overlayY, editorY + 20, "the overlay is taller here: copying y would show other text")
        AIReviewSurfaceRepresentable.scroll(overlayScroll, toY: overlayY)
        let overlayAnchor = try XCTUnwrap(AIReviewSurfaceRepresentable.topAnchor(of: overlay))
        XCTAssertEqual((composition.string as NSString).substring(with: NSRange(location: overlayAnchor.index, length: 8)), "Line 40 ")

        // Dismantle: back to the same document character.
        AIReviewSurfaceRepresentable.scroll(editorScroll, toY: 0)
        let back = composition.documentIndex(forOverlayIndex: overlayAnchor.index)
        let backY = try XCTUnwrap(AIReviewSurfaceRepresentable.originY(in: editor, showing: back, offset: overlayAnchor.offset))
        AIReviewSurfaceRepresentable.scroll(editorScroll, toY: backY)
        XCTAssertEqual(try XCTUnwrap(AIReviewSurfaceRepresentable.topAnchor(of: editor)).index, line40)
    }

    // MARK: - Find & Replace during a review

    func testReplacementLandsOnceTheReviewHasEnded() throws {
        let ns = text as NSString
        let session = AIReviewSession(action: .trim,
                                      changes: [AIChange(id: 0, range: ns.range(of: "big"), original: "big", replacement: "large")],
                                      selectionRange: NSRange(location: 0, length: ns.length), originalSelection: text)
        XCTAssertTrue(MarkdownTextViewRepresentable.keepsReviewBackstop(.reviewing(session)))
        for state: AIActionController.State in [.idle, .running(.trim, .claude), .marking([]), .message("x")] {
            XCTAssertFalse(MarkdownTextViewRepresentable.keepsReviewBackstop(state), "\(state)")
        }
        XCTAssertFalse(MarkdownTextViewRepresentable.keepsReviewBackstop(nil))

        let editor = LineformTextView()
        editor.string = text
        let replaced = text.replacingOccurrences(of: "good", with: "fine")
        editor.isAIReviewActive = MarkdownTextViewRepresentable.keepsReviewBackstop(.reviewing(session))
        editor.applyExternalReplacement(MarkdownEdit(text: replaced, selectedRange: NSRange(location: 0, length: 0)))
        XCTAssertEqual(editor.string, text, "while a review is up the backstop refuses (why replace ends it first)")
        // Replace ends the review; the representable drops the backstop before applying the edit.
        editor.isAIReviewActive = MarkdownTextViewRepresentable.keepsReviewBackstop(.idle)
        editor.applyExternalReplacement(MarkdownEdit(text: replaced, selectedRange: NSRange(location: 0, length: 0)))
        XCTAssertEqual(editor.string, replaced)
    }
}

