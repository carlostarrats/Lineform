import Combine
import LineformCore
import SwiftUI
import UIKit

/// One button of the selection row, in the spec's order (§5.5).
enum SelectionRowItem: Equatable, CaseIterable {
    case askAI, heading, bold, italic, strikethrough, code, list, link, blockquote, replaceWith, anotherWord

    /// The button's name (its accessibility label; the text for the text buttons). Ask AI names the
    /// connected AI ("Ask Claude"), as the Mac's toolbar does.
    func title(aiName: String? = nil) -> String {
        switch self {
        case .askAI: return SelectionToolbarPresentation.commentTitle(aiName: aiName ?? SelectionToolbarPresentation.aiName(for: .other))
        case .heading: return SelectionToolbarPresentation.headingTitle
        case .bold: return String(localized: "Bold")
        case .italic: return String(localized: "Italic")
        case .strikethrough: return String(localized: "Strikethrough")
        case .code: return String(localized: "Code")
        case .list: return SelectionToolbarPresentation.listTitle
        case .link: return String(localized: "Link")
        case .blockquote: return String(localized: "Blockquote")
        case .replaceWith: return String(localized: "Replace With…")
        case .anotherWord: return AIAction.anotherWord.title
        }
    }

    var title: String { title() }

    /// The Mac toolbar's symbols where it has the button.
    var systemImage: String? {
        switch self {
        case .askAI: return "text.bubble"
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .heading: return "textformat.size"
        case .list: return "list.bullet"
        case .link: return "link"
        case .blockquote: return "text.quote"
        case .replaceWith, .anotherWord: return nil
        }
    }
}

/// Where the row and the comment field sit: above the keyboard when it is up, above the home
/// indicator when it is down. The editor's own insets are never touched; the row floats over the
/// bottom of the page, as the Menu and Aa buttons do.
enum SelectionRowPlacement {
    /// The gap between the row and the keyboard (or the home indicator).
    static let gap: CGFloat = 12

    /// Bottom padding inside the safe area (which already clears the home indicator), with the
    /// keyboard's own safe area ignored: the keyboard's overlap with the window, less the part the
    /// home indicator inset already covers.
    static func bottomPadding(keyboardOverlap: CGFloat, safeAreaBottom: CGFloat) -> CGFloat {
        max(0, keyboardOverlap - safeAreaBottom) + gap
    }
}

/// The selection row and comment field for one editor (spec §5.5).
///
/// - **Settle.** The row rises `settleDelay` (0.35 s) after a non-empty selection stops changing.
///   The Mac's toolbar has no delay value of its own (it shows on the next runloop turn after a
///   mouse-up), so the spec's value is used. A collapsed selection hides it at once.
/// - **Commands.** Each formatting button calls the editor's own command, which goes through its
///   one rule-edit path (`applyRuleEdit`): one button, one undo step. The row then adopts the
///   resulting selection as its own instead of hiding and rising again.
/// - **Comment.** Ask AI swaps the row for the comment field. Send runs the shared
///   `AIActionController` on the selection the row was shown for (`anchorRange`); nothing is sent
///   while the note's input method is composing.
/// - **Keyboard.** The keyboard's overlap with the window is tracked from its frame notifications
///   (`keyboardOverlap`), so the row and the field sit just above it.
///
/// Nothing here runs at launch: the connection store is reached through a closure, and the AI
/// controller is made on first use.
@MainActor
final class SelectionController: NSObject, ObservableObject {
    enum Phase: Equatable { case hidden, row, comment }

    static let settleDelay: TimeInterval = 0.35

    @Published private(set) var phase: Phase = .hidden
    @Published private(set) var items: [SelectionRowItem] = []
    /// How much of the window's bottom the keyboard covers (0 when it is down). Its own object,
    /// observed only by the bottom chrome: a keyboard frame change must not re-render the whole
    /// screen (it arrives while the editor resigns, and a screen update there broke the editor's
    /// undo grouping in the middle of an undo).
    let keyboard = SelectionKeyboardTracker()
    var keyboardOverlap: CGFloat { keyboard.overlap }
    /// The AI controller's status, shown while it runs or has something to say. Task 5 replaces the
    /// review's part of it with the review overlay and its cards.
    @Published private(set) var aiStatus: String?
    /// The note's input method is composing (marked text): Send is off.
    @Published private(set) var isNoteComposing = false

    /// The comment's note, action and the connected AI's name: the Mac toolbar's model.
    let model = SelectionToolbarModel()
    /// The selection the row was shown for; the comment sends against exactly this range.
    private(set) var anchorRange: NSRange?
    private(set) weak var editor: LineformTextView?

    /// Replace With…: opens the Menu sheet's Search with the selected text as the query.
    var onReplaceWith: (String) -> Void = { _ in }
    /// Reads the note's live marked-text state (the comment field sets it).
    var noteMarkedText: () -> Bool = { false }

    private let connectionStore: () -> AIConnectionStore
    private var aiControllerStorage: AIActionController?
    private var aiStateObservation: AnyCancellable?
    private var settleTask: Task<Void, Never>?
    /// Set while the row itself moves the selection (a formatting command, Cancel).
    private var isAdjustingSelection = false
    private var observesKeyboard = false

    init(connectionStore: @escaping () -> AIConnectionStore = { .shared }, aiController: AIActionController? = nil) {
        self.connectionStore = connectionStore
        aiControllerStorage = aiController
        super.init()
        if let aiController { observe(aiController) }
    }

    /// The shared AI controller for this screen's editor, made on first use.
    var aiController: AIActionController {
        if let aiControllerStorage { return aiControllerStorage }
        let controller = AIActionController(connectionStore: connectionStore())
        aiControllerStorage = controller
        observe(controller)
        return controller
    }

    /// The editor whose selection the row follows (`MarkdownEditor` calls it).
    func attach(_ editor: LineformTextView) {
        guard self.editor !== editor else { return }
        self.editor = editor
        hide()
        guard !observesKeyboard else { return }
        observesKeyboard = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    // MARK: - Which buttons

    /// The row's buttons, in order: Ask AI (only while connected), Heading, Bold, Italic,
    /// Strikethrough, Code, List, Link, Blockquote, Replace With…, and Another Word (one word only,
    /// and only while connected: it is an AI action).
    static func rowItems(aiConnected: Bool, selectedText: String) -> [SelectionRowItem] {
        var items: [SelectionRowItem] = aiConnected ? [.askAI] : []
        items += [.heading, .bold, .italic, .strikethrough, .code, .list, .link, .blockquote, .replaceWith]
        if aiConnected, AIMenuPresentation.isSingleWord(selectedText) { items.append(.anotherWord) }
        return items
    }

    // MARK: - When it shows

    /// The editor's selection changed (`textViewDidChangeSelection`). An empty selection hides the
    /// row at once; a non-empty one shows it once it has stayed the same for `settleDelay`.
    func editorSelectionDidChange() {
        guard !isAdjustingSelection, let editor else { return }
        // The comment holds its own range; the note field has focus.
        guard phase != .comment else { return }
        settleTask?.cancel()
        let range = editor.selectedRange
        guard range.length > 0 else { return hide() }
        if phase == .row, range == anchorRange { return }
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleDelay))
            guard !Task.isCancelled, let self, let editor = self.editor, editor.selectedRange == range else { return }
            self.showRowNow()
        }
    }

    /// Shows the row for the editor's current selection, now. The settle wait ends here.
    func showRowNow() {
        settleTask?.cancel()
        settleTask = nil
        guard let editor else { return }
        let range = editor.selectedRange
        guard range.length > 0, allowsRow else { return hide() }
        let provider = connectionStore().connectedProvider
        let aiName = provider.map { SelectionToolbarPresentation.aiName(for: $0) }
        if model.aiName != aiName { model.aiName = aiName }
        let dark = Theme.theme(for: editor.profile).usesDarkChrome
        if model.usesDarkChrome != dark { model.usesDarkChrome = dark }
        let newItems = Self.rowItems(aiConnected: provider != nil, selectedText: selectedText(in: range))
        if items != newItems { items = newItems }
        anchorRange = range
        if phase != .row { phase = .row }
    }

    /// No row while composing, outside an editable editor on screen, or while an AI request or
    /// review is in progress.
    private var allowsRow: Bool {
        guard let editor, editor.window != nil, editor.isEditable, editor.markedTextRange == nil else { return false }
        switch aiControllerStorage?.state {
        case .running, .reviewing: return false
        default: return true
        }
    }

    /// Writes a published value only when it changes: a selection change arrives in the middle of
    /// edits and undo, and a needless `objectWillChange` there re-renders the screen mid-undo.
    func hide() {
        settleTask?.cancel()
        settleTask = nil
        anchorRange = nil
        if isNoteComposing { isNoteComposing = false }
        if phase != .hidden { phase = .hidden }
    }

    private func selectedText(in range: NSRange) -> String {
        guard let editor else { return "" }
        let text = editor.textStorage.string as NSString
        return text.substring(with: NSIntersectionRange(range, NSRange(location: 0, length: text.length)))
    }

    // MARK: - Commands

    func perform(_ item: SelectionRowItem) {
        switch item {
        case .askAI: openComment()
        // Heading and List are menus (`setHeading`, `applyList`).
        case .heading, .list: break
        case .bold: runCommand { $0.apply(.bold) }
        case .italic: runCommand { $0.apply(.italic) }
        case .strikethrough: runCommand { $0.apply(.strikethrough) }
        case .code: runCommand { $0.apply(.inlineCode) }
        case .link: runCommand { $0.apply(.link) }
        case .blockquote: runCommand { $0.apply(.blockquote) }
        case .replaceWith:
            guard let range = anchorRange else { return }
            let text = selectedText(in: range)
            hide()
            onReplaceWith(text)
        case .anotherWord:
            guard let range = anchorRange, let editor else { return }
            let text = editor.textStorage.string
            hide()
            aiController.run(.anotherWord, range: range, text: text)
        }
    }

    /// Heading's menu: Title, Section, Heading 3–6, or Body (`nil`).
    func setHeading(_ level: Int?) {
        runCommand { $0.setHeadingLevel(level) }
    }

    /// List's menu: Bulleted or Numbered.
    func applyList(ordered: Bool) {
        runCommand { $0.apply(ordered ? .orderedList : .unorderedList) }
    }

    /// Runs one editor command with the row held still, then adopts the selection it left.
    private func runCommand(_ command: (LineformTextView) -> Void) {
        guard let editor, phase == .row else { return }
        isAdjustingSelection = true
        command(editor)
        isAdjustingSelection = false
        let range = editor.selectedRange
        guard range.length > 0 else { return hide() }
        anchorRange = range
        let newItems = Self.rowItems(aiConnected: model.aiName != nil, selectedText: selectedText(in: range))
        if items != newItems { items = newItems }
    }

    // MARK: - Comment

    func openComment() {
        guard phase == .row, anchorRange != nil, model.aiName != nil else { return }
        model.note = ""
        model.action = .custom
        isNoteComposing = false
        phase = .comment
        model.focusToken += 1
    }

    /// The note's text or marked-text state changed (the comment field calls it).
    func noteDidChange(_ text: String, composing: Bool) {
        if model.note != text { model.note = text }
        if isNoteComposing != composing { isNoteComposing = composing }
    }

    /// Send's state: a note when the action is Custom, and no input method composing.
    var canSendNow: Bool { phase == .comment && model.canSend && !isNoteComposing && !noteMarkedText() }

    /// Sends the comment: the shared controller runs the action on the selection the row was shown
    /// for. Refused while composing (Return then only confirms the candidate). True when it ran.
    @discardableResult
    func send() -> Bool {
        guard canSendNow, let range = anchorRange, let editor else { return false }
        let action = model.action
        let note = model.note
        let text = editor.textStorage.string
        hide()
        editor.becomeFirstResponder()
        aiController.run(action, range: range, text: text, note: note)
        return true
    }

    /// Cancel (the button, or a swipe down): back to the row, with the selection as it was.
    func cancelComment() {
        guard phase == .comment else { return }
        isNoteComposing = false
        phase = .row
        guard let editor, let anchor = anchorRange, NSMaxRange(anchor) <= editor.textStorage.length else { return }
        isAdjustingSelection = true
        editor.becomeFirstResponder()
        editor.selectedRange = anchor
        isAdjustingSelection = false
    }

    // MARK: - AI status

    private func observe(_ controller: AIActionController) {
        aiStateObservation = controller.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.aiStateChanged(state) }
        }
    }

    private func aiStateChanged(_ state: AIActionController.State) {
        let status: String?
        switch state {
        case .idle: status = nil
        case .running(let action, _): status = action.progressVerb
        case .message(let message): status = message
        case .marking(let ranges): status = AIActionController.markedMessage(ranges.count)
        case .reviewing(let session):
            status = session.action.reviewsPerCorrection
                ? AIActionController.correctionsSuggestedMessage(session.pending.count)
                : AIActionController.changeSuggestedMessage
        }
        if aiStatus != status { aiStatus = status }
        switch state {
        case .running, .reviewing: if phase == .row { hide() }
        default: break
        }
    }

    /// A tap on the status: a request stops, a message or marks go away.
    func dismissAIStatus() {
        guard let controller = aiControllerStorage else { return }
        switch controller.state {
        case .running: controller.cancel()
        case .message: controller.dismissMessage()
        case .marking: controller.dismissMarks()
        case .idle, .reviewing: break
        }
    }

    // MARK: - Keyboard

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let window = editor?.window
        let overlap: CGFloat
        if let window {
            let frame = window.convert(value.cgRectValue, from: window.screen.coordinateSpace)
            overlap = max(0, window.bounds.maxY - frame.minY)
        } else {
            overlap = 0
        }
        setKeyboardOverlap(overlap, notification: notification)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        setKeyboardOverlap(0, notification: notification)
    }

    private func setKeyboardOverlap(_ overlap: CGFloat, notification: Notification) {
        guard overlap != keyboard.overlap else { return }
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let animation = EditorMotionPolicy.animation(.easeOut(duration: duration),
                                                     reduceMotion: UIAccessibility.isReduceMotionEnabled)
        withAnimation(duration > 0 ? animation : nil) {
            keyboard.overlap = overlap
        }
    }
}

/// The keyboard's overlap with the window, for the selection row's placement.
@MainActor
final class SelectionKeyboardTracker: ObservableObject {
    @Published fileprivate(set) var overlap: CGFloat = 0
}
