import Combine
import LineformCore
import SwiftUI
import UIKit

/// One button of the selection row, in the spec's order (§5.5).
enum SelectionRowItem: Equatable, CaseIterable {
    case askAI, heading, bold, italic, strikethrough, code, list, link, blockquote, image, insertTable, reformatTable
    case replaceWith, anotherWord

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
        case .image: return String(localized: "Image")
        case .insertTable: return String(localized: "Insert Table")
        case .reformatTable: return String(localized: "Reformat Table")
        case .replaceWith: return String(localized: "Replace With…")
        case .anotherWord: return AIAction.anotherWord.title
        }
    }

    var title: String { title() }

    /// What the row SHOWS for Ask: the short "Ask" beside the sparkle (§21, "A · Native row").
    /// `title` (its VoiceOver label) still names the AI: "Ask Claude".
    static var askShortTitle: String { String(localized: "Ask") }

    /// The Mac toolbar's symbols where it has the button; the tables use the Mac's Format-menu
    /// symbols (`MainMenuIconDecorator`).
    var systemImage: String? {
        switch self {
        case .askAI: return "sparkles"
        case .image: return "photo"
        case .insertTable: return "tablecells"
        case .reformatTable: return "tablecells.badge.ellipsis"
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
/// - **Whole document.** The Menu's Ask AI… (`askAIForWholeDocument`) opens the same comment
///   field for the whole document, after the shared `WholeDocumentAIPolicy`: up to 1,500 words at
///   once, above that after "Send the whole document (N words) to …?" (Send / Cancel, Cancel the
///   default), and past `AILimits` it is refused on the AI's message card. Nothing is sent and the
///   Keychain is not read until Send.
/// - **Any change closes the comment.** An edit in the editor, a new selection, or an outside
///   replacement (a live reload, Open, Save As, Convert) closes the field, as the Mac's card closes
///   on any click: the range it holds would no longer name the text the writer commented on. As a
///   backstop, Send refuses a selection's comment when the text differs from the one the field
///   opened on, and a whole-document Send runs `WholeDocumentAIPolicy` again (asking again above
///   the confirmed count, refusing past the limit).
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
    /// The row shows the heading levels in place of its buttons (Heading's second row, with ‹ to
    /// go back). Picking a level applies it and returns to the buttons.
    @Published private(set) var showsHeadingLevels = false
    /// How much of the window's bottom the keyboard covers (0 when it is down). Its own object,
    /// observed only by the bottom chrome: a keyboard frame change must not re-render the whole
    /// screen (it arrives while the editor resigns, and a screen update there broke the editor's
    /// undo grouping in the middle of an undo).
    let keyboard = SelectionKeyboardTracker()
    var keyboardOverlap: CGFloat { keyboard.overlap }
    /// The AI controller's status in words (what it is doing, its message, what it found or
    /// suggested), nil while idle. Spoken again when an edit is refused during a review.
    @Published private(set) var aiStatus: String?
    /// The AI controller's state, mirrored so the cards and the review overlay follow it without
    /// making the controller (nothing is made at launch).
    @Published private(set) var aiState: AIActionController.State = .idle
    /// History for AI actions: the document's `PhoneHistoryController`, assigned by
    /// `DocumentScreen` (the ONE assignment; nil only in tests without History). Weak: the
    /// document owns it.
    weak var aiHistory: (any AIHistoryRecording)? {
        didSet { aiControllerStorage?.history = aiHistory }
    }
    /// Edits refused during a review, and the status said for the last one (for tests; the card
    /// pulses through `refusalPulse`).
    private(set) var refusedEditCount = 0
    private(set) var refusedEditMessage: String?
    @Published private(set) var refusalPulse = 0
    /// Composes the review overlay's text, reusing the last composition between renders.
    let compositionCache = AIReviewCompositionCache()
    /// The AI card's top in the window (`.infinity` without one): the overlay reveals the current
    /// change above it.
    var aiCardTopInWindow: CGFloat = .infinity
    /// Read is on screen: no AI there (Read has no editor to hold a review).
    private(set) var isReadMode = false
    /// The note's input method is composing (marked text): Send is off.
    @Published private(set) var isNoteComposing = false

    /// The comment's note, action and the connected AI's name: the Mac toolbar's model.
    let model = SelectionToolbarModel()
    /// The selection the row was shown for; the comment sends against exactly this range (the
    /// whole document's range for the Menu's Ask AI…).
    private(set) var anchorRange: NSRange?
    /// The comment field is for the whole document (the Menu's Ask AI…), not a selection.
    @Published private(set) var isWholeDocument = false
    /// Where the caret was when the whole-document field opened: Cancel puts it back.
    private var wholeDocumentCaret: NSRange?
    /// The word count the confirmation asks about while it is up (nil otherwise). Cleared when the
    /// alert goes away by ANY path (Send, Cancel, or dismissed under it).
    private(set) var pendingWholeDocumentWords: Int?
    /// Which confirmation `pendingWholeDocumentWords` belongs to: an older alert going away never
    /// clears a newer one's count.
    private var pendingConfirmationID: UUID?
    /// The word count the writer confirmed for this whole-document field (nil when it opened
    /// without asking). Send asks again for more.
    private var confirmedWholeDocumentWords: Int?
    /// The document's text when the comment field opened: a selection's Send refuses when it differs.
    private var commentSnapshot: String?
    /// Shows the confirmation. By default, from the top of the editor's window; tests capture it.
    var presentAlert: (UIAlertController) -> Void = { _ in }
    private(set) weak var editor: LineformTextView?

    /// Reads the note's live marked-text state (the comment field sets it).
    var noteMarkedText: () -> Bool = { false }

    private let connectionStore: () -> AIConnectionStore
    private var aiControllerStorage: AIActionController?
    private var aiStateObservation: AnyCancellable?
    private var settleTask: Task<Void, Never>?
    /// Set while the row itself moves the selection (a formatting command, Cancel).
    private var isAdjustingSelection = false
    private var observesKeyboard = false
    /// Where the keyboard's frame notifications come from: the default center, which UIKit posts
    /// to. Tests give their own, so the simulator's real keyboard (going down when the review
    /// overlay takes the focus) never moves the chrome they place from a frame they posted.
    private let keyboardNotifications: NotificationCenter

    init(connectionStore: @escaping () -> AIConnectionStore = { .shared }, aiController: AIActionController? = nil,
         keyboardNotifications: NotificationCenter = .default) {
        self.connectionStore = connectionStore
        aiControllerStorage = aiController
        self.keyboardNotifications = keyboardNotifications
        super.init()
        presentAlert = { [weak self] alert in self?.presentFromEditorWindow(alert) }
        if let aiController { observe(aiController) }
    }

    /// The shared AI controller for this screen's editor, made on first use.
    var aiController: AIActionController {
        if let aiControllerStorage { return aiControllerStorage }
        let controller = AIActionController(connectionStore: connectionStore())
        aiControllerStorage = controller
        observe(controller)
        wireAI(controller)
        return controller
    }

    /// History is about to open from Menu ▸ History (the Mac's History tab): History mode and AI
    /// never overlap. A review ends (keeping what was accepted, which History records), then a
    /// request is cancelled and marks or a message are dropped. Makes no controller when none ran.
    func endAIForHistory() {
        guard let controller = aiControllerStorage else { return }
        controller.endReview()
        controller.abandon()
    }

    /// The editor and History the controller works on. History is `aiHistory`'s single assignment.
    private func wireAI(_ controller: AIActionController) {
        controller.editor = editor
        controller.history = aiHistory
    }

    /// The editor whose selection the row follows (`MarkdownEditor` calls it).
    func attach(_ editor: LineformTextView) {
        guard self.editor !== editor else { return }
        self.editor = editor
        hide()
        editor.aiRefusalHandler = { [weak self] in self?.editRefusedDuringReview() }
        editor.aiDismissMarksHandler = { [weak self] in self?.aiControllerStorage?.dismissMarks() }
        editor.writerInteractionHandler = { [weak self] in self?.writerTookAppSelection() }
        if let controller = aiControllerStorage {
            wireAI(controller)
            editor.isAIReviewActive = { if case .reviewing = controller.state { return true }; return false }()
        }
        guard !observesKeyboard else { return }
        observesKeyboard = true
        let center = keyboardNotifications
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    // MARK: - Which buttons

    /// The row's buttons, in order: Ask AI (only while connected), Heading, Bold, Italic,
    /// Strikethrough, Code, List, Link, Blockquote, Insert Table, Reformat Table (only when the
    /// selection starts on a table row: elsewhere it would do nothing), Replace With… (only where
    /// History can keep the selection: `offersReplaceWith`), and Another Word (one word only, and
    /// only while connected: it is an AI action). Insert and Reformat Table moved here from the
    /// Menu; on the Mac they live in Format.
    static func rowItems(aiConnected: Bool, selectedText: String, offersReplaceWith: Bool,
                         startsOnTableRow: Bool = false) -> [SelectionRowItem] {
        var items: [SelectionRowItem] = aiConnected ? [.askAI] : []
        // (Read mode passes `aiConnected: false`: Read allows no AI.)
        items += [.heading, .bold, .italic, .strikethrough, .code, .list, .link, .blockquote, .image, .insertTable]
        if startsOnTableRow { items.append(.reformatTable) }
        if offersReplaceWith { items.append(.replaceWith) }
        if aiConnected, AIMenuPresentation.isSingleWord(selectedText) { items.append(.anotherWord) }
        return items
    }

    // MARK: - When it shows

    /// The editor's selection changed (`textViewDidChangeSelection`). An empty selection hides the
    /// row at once; a non-empty one shows it once it has stayed the same for `settleDelay`.
    func editorSelectionDidChange() {
        guard !isAdjustingSelection, let editor else { return }
        // A new selection closes the comment (the Mac's card closes on any click); the new
        // selection is then the writer's like any other.
        if phase == .comment { closeCommentForChange() }
        settleTask?.cancel()
        // The app's own selection (a Search or Outline jump, a position restore, a review's end)
        // never raises the row.
        if editor.isSelectionProgrammatic { return hide() }
        editor.forgetProgrammaticSelection()
        let range = editor.selectedRange
        guard range.length > 0 else { return hide() }
        if phase == .row, range == anchorRange { return }
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleDelay))
            guard !Task.isCancelled, let self, let editor = self.editor, editor.selectedRange == range,
                  !editor.isSelectionProgrammatic else { return }
            self.showRowNow()
        }
    }

    /// The writer touched the app's own selection, or pressed a key (the editor has already
    /// forgotten that the app set it): the selection is theirs now, and the row may rise for it.
    private func writerTookAppSelection() {
        guard phase != .comment else { return }
        editorSelectionDidChange()
    }

    /// The editor's text changed (`textViewDidChange`: typing, a formatting command, Read's
    /// checkbox, Search's Replace). An open comment closes: its range no longer names the same text.
    func editorTextDidChange() {
        guard phase == .comment else { return }
        closeCommentForChange()
    }

    /// Something changed under the open comment field: it closes, sending nothing and putting no
    /// selection back (the text or the selection is no longer the one it was opened for).
    private func closeCommentForChange() {
        guard phase == .comment else { return }
        hide()
    }

    /// The Menu, Aa (and Preview's link) buttons show unless the row or the comment field has the
    /// bottom, or a request or review is running. A message or Find's marks leave them reachable:
    /// their card sits above the buttons.
    static func showsBottomButtons(phase: Phase, aiState: AIActionController.State) -> Bool {
        guard phase == .hidden else { return false }
        switch aiState {
        case .running, .reviewing: return false
        case .idle, .message, .marking: return true
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
        let newItems = Self.rowItems(aiConnected: provider != nil && !isReadMode, selectedText: selectedText(in: range),
                                     offersReplaceWith: editor.offersReplaceWith(for: range),
                                     startsOnTableRow: startsOnTableRow(range))
        if items != newItems { items = newItems }
        anchorRange = range
        if phase != .row {
            // A new row always opens on the formatting buttons, never on the heading levels.
            if showsHeadingLevels { showsHeadingLevels = false }
            phase = .row
        }
    }

    /// Whether the line `range` starts on is a table row (it starts with `|`): line-local, so it
    /// costs nothing on a large document.
    private func startsOnTableRow(_ range: NSRange) -> Bool {
        guard let editor else { return false }
        let text = editor.textStorage.string as NSString
        guard range.location <= text.length else { return false }
        let line = text.lineRange(for: NSRange(location: range.location, length: 0))
        let content = text.substring(with: line).trimmingCharacters(in: markdownLineTrimCharacters)
        return content.hasPrefix("|")
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
        wholeDocumentCaret = nil
        confirmedWholeDocumentWords = nil
        commentSnapshot = nil
        if isNoteComposing { isNoteComposing = false }
        if isWholeDocument { isWholeDocument = false }
        if model.isWholeDocument { model.isWholeDocument = false }
        if showsHeadingLevels { showsHeadingLevels = false }
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
        // Heading opens the levels in place (`setHeading`); List is a menu (`applyList`).
        case .heading: showHeadingLevels(true)
        // Image is a menu (`pickImage`).
        case .image: break
        case .list: break
        case .insertTable: runCommand { $0.insertTable() }
        case .reformatTable: runCommand { $0.reformatTable() }
        case .bold: runCommand { $0.apply(.bold) }
        case .italic: runCommand { $0.apply(.italic) }
        case .strikethrough: runCommand { $0.apply(.strikethrough) }
        case .code: runCommand { $0.apply(.inlineCode) }
        case .link: runCommand { $0.apply(.link) }
        case .blockquote: runCommand { $0.apply(.blockquote) }
        case .replaceWith:
            // History's Replace With… (the Mac's meaning): the selection becomes a passage and
            // History mode opens on it with "Type a replacement". History and AI never overlap:
            // a request or review ends first, and Find's wash goes (`yieldToHistory`, as the
            // Mac's show-History path).
            guard let range = anchorRange, let editor else { return }
            hide()
            aiControllerStorage?.yieldToHistory()
            editor.performReplaceWith(range)
        case .anotherWord:
            guard let range = anchorRange, let editor else { return }
            let text = editor.textStorage.string
            hide()
            aiController.run(.anotherWord, range: range, text: text)
        }
    }

    /// Heading's second row: Title, Section, Heading 3–6, or Body (`nil`), the Mac's Format ▸
    /// Heading items. Applies the level (one undo step), then the row returns to its buttons.
    func setHeading(_ level: Int?) {
        runCommand { $0.setHeadingLevel(level) }
        showHeadingLevels(false)
    }

    /// Swaps the row between its buttons and the heading levels (Heading, and ‹).
    func showHeadingLevels(_ shows: Bool) {
        guard phase == .row || !shows else { return }
        if showsHeadingLevels != shows { showsHeadingLevels = shows }
    }

    /// The heading levels, in the Mac's order, with Body (`nil`) last.
    static var headingLevels: [(level: Int?, title: String)] {
        [
            (1, String(localized: "Title")),
            (2, String(localized: "Section")),
            (3, String(localized: "Heading 3")),
            (4, String(localized: "Heading 4")),
            (5, String(localized: "Heading 5")),
            (6, String(localized: "Heading 6")),
            (nil, String(localized: "Body")),
        ]
    }

    /// Image's menu: Photos or Files. The row goes while the picker is up; the picked image goes
    /// in through the editor's paste path (one undo step).
    func pickImage(from source: LineformTextView.ImagePickerSource) {
        guard let editor, phase == .row else { return }
        hide()
        // After the menu has finished closing: UIKit refuses a presentation while the menu's own
        // dismissal is still running.
        Task { @MainActor [weak editor] in
            try? await Task.sleep(for: .seconds(Self.menuDismissalDelay))
            editor?.presentImagePicker(source)
        }
    }

    static let menuDismissalDelay: TimeInterval = 0.4

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
        let newItems = Self.rowItems(aiConnected: model.aiName != nil, selectedText: selectedText(in: range),
                                     offersReplaceWith: editor.offersReplaceWith(for: range),
                                     startsOnTableRow: startsOnTableRow(range))
        if items != newItems { items = newItems }
    }

    // MARK: - Comment

    func openComment() {
        guard phase == .row, anchorRange != nil, model.aiName != nil, !isReadMode, let editor else { return }
        model.note = ""
        model.action = .custom
        if model.isWholeDocument { model.isWholeDocument = false }
        commentSnapshot = editor.textStorage.string
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
    ///
    /// The backstops behind "any change closes the field": a selection's comment is refused (and
    /// the field closed) when the text is no longer the one it opened on. A whole-document comment
    /// runs the length policy again: past the limit it is refused on the message card; above the
    /// count the writer confirmed (or above 1,500 words when nothing was asked) the writer is asked
    /// again, and the field stays with its note until they answer.
    @discardableResult
    func send() -> Bool {
        guard canSendNow, let range = anchorRange, let editor else { return false }
        let action = model.action
        let note = model.note
        let text = editor.textStorage.string
        let wholeDocument = isWholeDocument
        if wholeDocument {
            guard pendingWholeDocumentWords == nil else { return false }
            switch WholeDocumentAIPolicy.decision(for: text) {
            case .run:
                break
            case .confirm(let words):
                if let confirmed = confirmedWholeDocumentWords, words <= confirmed { break }
                presentWholeDocumentConfirmation(words: words)
                return false
            case .refuse:
                hide()
                aiController.refuseWholeDocument()
                return false
            }
        } else if text != commentSnapshot {
            hide()
            return false
        }
        hide()
        editor.becomeFirstResponder()
        if wholeDocument {
            aiController.runWholeDocument(action, text: text, note: note)
        } else {
            aiController.run(action, range: range, text: text, note: note)
        }
        return true
    }

    /// Cancel (the button, or a swipe down): back to the row, with the selection as it was. For
    /// the whole document the field closes and the caret goes back where it was.
    func cancelComment() {
        guard phase == .comment else { return }
        if isWholeDocument {
            let caret = wholeDocumentCaret
            hide()
            guard let editor, let caret, NSMaxRange(caret) <= editor.textStorage.length else { return }
            isAdjustingSelection = true
            editor.becomeFirstResponder()
            editor.selectedRange = caret
            isAdjustingSelection = false
            return
        }
        isNoteComposing = false
        phase = .row
        guard let editor, let anchor = anchorRange, NSMaxRange(anchor) <= editor.textStorage.length else { return }
        isAdjustingSelection = true
        editor.becomeFirstResponder()
        editor.selectedRange = anchor
        isAdjustingSelection = false
    }

    // MARK: - Whole document

    /// The connection store, for the Menu's Ask AI… row (reached only when the sheet shows it).
    var aiConnectionStore: AIConnectionStore { connectionStore() }

    /// The Menu's Ask AI… row: connected, an editor on screen (Read allows no AI), and text to
    /// send (`DocumentSection.hasText`).
    var allowsWholeDocumentAI: Bool {
        guard connectionStore().isConnected, !isReadMode, let editor, editor.isEditable,
              DocumentSection.hasText(editor.textStorage.string) else { return false }
        switch aiControllerStorage?.state {
        case .running, .reviewing: return false
        default: return true
        }
    }

    /// The Menu's Ask AI… (after the sheet has closed): the shared length policy decides, before
    /// anything is read or sent. Up to 1,500 words the comment field opens for the whole document;
    /// above that the writer confirms first; past `AILimits` the refusal shows on the message card.
    func askAIForWholeDocument() {
        guard allowsWholeDocumentAI, let editor, pendingWholeDocumentWords == nil,
              connectionStore().connectedProvider != nil else { return }
        switch WholeDocumentAIPolicy.decision(for: editor.textStorage.string) {
        case .run:
            openWholeDocumentComment(confirmedWords: nil)
        case .refuse:
            hide()
            aiController.refuseWholeDocument()
        case .confirm(let words):
            hide()
            presentWholeDocumentConfirmation(words: words)
        }
    }

    /// "Send the whole document (N words) to …?", for the Menu's Ask AI… or again at Send. The
    /// pending count is cleared however the alert goes away.
    private func presentWholeDocumentConfirmation(words: Int) {
        let store = connectionStore()
        guard let provider = store.connectedProvider else { return }
        let id = UUID()
        pendingWholeDocumentWords = words
        pendingConfirmationID = id
        let recipient = WholeDocumentAIPolicy.recipient(for: provider, otherEndpoint: store.otherEndpoint)
        let alert = Self.wholeDocumentConfirmation(
            words: words, recipient: recipient,
            onSend: { [weak self] in self?.confirmWholeDocument(words: words) },
            onCancel: { [weak self] in self?.cancelWholeDocumentConfirmation() }
        )
        alert.onGone = { [weak self] in self?.confirmationWentAway(id) }
        presentAlert(alert)
    }

    /// The alert left the screen (after Send or Cancel, or dismissed under them): its count no
    /// longer stands, unless a newer alert has replaced it.
    private func confirmationWentAway(_ id: UUID) {
        guard pendingConfirmationID == id else { return }
        pendingConfirmationID = nil
        pendingWholeDocumentWords = nil
    }

    /// "Send the whole document (N words) to …?": Send, then Cancel, which is the default (Return
    /// on a hardware keyboard never sends a whole document by accident), as on the Mac.
    static func wholeDocumentConfirmation(words: Int, recipient: String, onSend: @escaping () -> Void,
                                          onCancel: @escaping () -> Void) -> WholeDocumentConfirmationAlert {
        let alert = WholeDocumentConfirmationAlert(
            title: WholeDocumentAIPolicy.confirmationTitle(words: words, recipient: recipient),
            message: nil, preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: WholeDocumentAIPolicy.sendTitle, style: .default) { _ in onSend() })
        let cancel = UIAlertAction(title: WholeDocumentAIPolicy.cancelTitle, style: .cancel) { _ in onCancel() }
        alert.addAction(cancel)
        alert.preferredAction = cancel
        return alert
    }

    /// The confirmation's Send. From the Menu's Ask AI…, the comment field opens for the whole
    /// document (nothing is sent yet). Asked again at Send, the comment goes. `words` is the count
    /// the alert asked about (the pending count when nil, as tests answer it).
    func confirmWholeDocument(words: Int? = nil) {
        guard let words = words ?? pendingWholeDocumentWords else { return }
        pendingWholeDocumentWords = nil
        pendingConfirmationID = nil
        if phase == .comment, isWholeDocument {
            confirmedWholeDocumentWords = words
            send()
        } else {
            openWholeDocumentComment(confirmedWords: words)
        }
    }

    /// The confirmation's Cancel: nothing opens, nothing is sent (a field already open stays).
    func cancelWholeDocumentConfirmation() {
        pendingWholeDocumentWords = nil
        pendingConfirmationID = nil
    }

    /// The comment field, for the whole document: its range is the whole text, nothing is
    /// highlighted, and the caret is remembered for Cancel.
    private func openWholeDocumentComment(confirmedWords: Int?) {
        guard allowsWholeDocumentAI, let editor, let provider = connectionStore().connectedProvider else { return }
        let caret = editor.selectedRange
        hide()
        let aiName = SelectionToolbarPresentation.aiName(for: provider)
        if model.aiName != aiName { model.aiName = aiName }
        let dark = Theme.theme(for: editor.profile).usesDarkChrome
        if model.usesDarkChrome != dark { model.usesDarkChrome = dark }
        model.note = ""
        model.action = .custom
        wholeDocumentCaret = caret
        confirmedWholeDocumentWords = confirmedWords
        commentSnapshot = editor.textStorage.string
        anchorRange = NSRange(location: 0, length: editor.textStorage.length)
        isWholeDocument = true
        model.isWholeDocument = true
        isNoteComposing = false
        phase = .comment
        model.focusToken += 1
    }

    private func presentFromEditorWindow(_ alert: UIAlertController) {
        var top = editor?.window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        guard let top else {
            pendingWholeDocumentWords = nil
            pendingConfirmationID = nil
            return
        }
        top.present(alert, animated: true)
    }

    // MARK: - AI status

    private func observe(_ controller: AIActionController) {
        aiStateObservation = controller.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.aiStateChanged(state) }
        }
    }

    /// Called as the controller's state is about to change (`@Published` delivers in `willSet`):
    /// the editor's read-only backstop and Mark's wash follow it before the controller's own
    /// `didSet` collapses the selection.
    private func aiStateChanged(_ state: AIActionController.State) {
        if let editor {
            if case .reviewing = state { editor.isAIReviewActive = true } else { editor.isAIReviewActive = false }
            if case .marking(let ranges) = state { editor.applyAIMarkRanges(ranges) } else { editor.applyAIMarkRanges([]) }
        }
        if aiState != state { aiState = state }
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

    /// An edit was refused while a review is up: the review's status is said again, and the card
    /// pulses. Published on the next turn: a refusal can arrive in the middle of an edit, and a
    /// screen update there broke the editor's undo grouping before (Task 4).
    func editRefusedDuringReview() {
        guard case .reviewing(let session) = aiState else { return }
        let message = session.action.reviewsPerCorrection
            ? AIActionController.correctionsSuggestedMessage(session.pending.count)
            : AIActionController.changeSuggestedMessage
        refusedEditCount += 1
        refusedEditMessage = message
        editor?.announceAI(message)
        DispatchQueue.main.async { [weak self] in self?.refusalPulse += 1 }
    }

    /// The editor's text is about to be replaced from outside (a live reload, another document):
    /// reload wins. A request, review or marks for the old text are abandoned, applying and
    /// recording nothing.
    func editorTextWillBeReplaced() {
        // The comment field (and the row) were for the old text.
        if phase != .hidden { hide() }
        guard let controller = aiControllerStorage else { return }
        switch controller.state {
        case .running, .reviewing, .marking: controller.abandon()
        case .idle, .message: break
        }
    }

    /// The mode on screen changed. Read allows no AI: the row goes, a review ends (keeping what was
    /// accepted, as the Mac does), and a request or marks are dropped.
    func displayModeDidChange(to mode: EditorDisplayMode) {
        isReadMode = mode == .read
        guard isReadMode else { return }
        hide()
        guard let controller = aiControllerStorage else { return }
        switch controller.state {
        case .reviewing, .running, .marking:
            controller.endReview()
            controller.abandon()
        case .idle, .message:
            break
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

/// The whole-document confirmation. It says when it leaves the screen by ANY path (Send, Cancel,
/// or dismissed under them), so the pending count never outlives it. No stored properties: UIKit
/// builds alert controllers through a class factory, where Swift's property initializers may not
/// run (see `LineformTextView.State`); the handler lives in an associated object.
final class WholeDocumentConfirmationAlert: UIAlertController {
    private final class Handler {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }

    nonisolated(unsafe) private static var handlerKey: UInt8 = 0

    var onGone: (() -> Void)? {
        get { (objc_getAssociatedObject(self, &Self.handlerKey) as? Handler)?.action }
        set { objc_setAssociatedObject(self, &Self.handlerKey, newValue.map(Handler.init), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onGone?()
    }
}

/// The keyboard's overlap with the window, for the selection row's placement.
@MainActor
final class SelectionKeyboardTracker: ObservableObject {
    @Published fileprivate(set) var overlap: CGFloat = 0
}
