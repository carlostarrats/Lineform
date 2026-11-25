import Combine
import LineformCore
import SwiftUI
import UIKit

/// One button of the format row, in the order of the owner's mockup A (§5.5, 2026-11-24).
enum SelectionRowItem: Equatable, CaseIterable {
    case askAI, heading, bold, italic, strikethrough, code, list, link, blockquote, image, insertTable, reformatTable
    case replaceWith, anotherWord, checkSpelling

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
        case .checkSpelling: return String(localized: "Check Spelling")
        }
    }

    var title: String { title() }

    /// The word on the key, as in the mockup: short words ("Quote", "Table"). B, I and S draw
    /// their letters in their own style.
    var keyText: String {
        switch self {
        case .askAI: return Self.askShortTitle
        case .bold: return "B"
        case .italic: return "I"
        case .strikethrough: return "S"
        case .blockquote: return String(localized: "Quote")
        case .insertTable: return String(localized: "Table")
        default: return title
        }
    }

    /// The Large Content Viewer's symbol for the key (the row itself draws words).
    var largeContentSymbol: String? { systemImage }

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
        case .checkSpelling: return "textformat.abc.dottedunderline"
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
///   mouse-up), so the spec's value is used.
/// - **Caret.** While the editor is first responder with the SOFTWARE keyboard up
///   (`minimumSoftwareKeyboardOverlap`), the row also shows for a caret (2026-11-24, the owner's
///   decision): it goes with the keyboard, and a hardware keyboard alone raises none. A collapsed
///   selection then turns the row into the caret's at once; without the keyboard it hides at once,
///   as before. Its published values change on the next main-actor turn (`scheduleCaretRefresh`),
///   never in the middle of an edit, an undo or a resign, and never while an input method is
///   composing (the row stays exactly as it was until the composition ends).
/// - **Commands.** Each formatting button calls the editor's own command, which goes through its
///   one rule-edit path (`applyRuleEdit`): one button, one undo step. The row then adopts the
///   resulting selection as its own instead of hiding and rising again. With a caret, Bold, Italic,
///   Strikethrough and Code act on the word at the caret (else the Mac's empty-selection edit:
///   the paired markers with the caret between), List and Blockquote on the caret's line, and Ask
///   opens the AI sheet for the whole document (`askAIForWholeDocument`).
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
    /// The keyboard's overlap from which it counts as the software keyboard. A hardware keyboard
    /// leaves at most the shortcuts bar (well under this); the smallest iPhone keyboard is over
    /// 200 pt.
    static let minimumSoftwareKeyboardOverlap: CGFloat = 150

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
    /// The AI conversation for the document on screen (2026-11-24): the AI sheet's. Memory only;
    /// it goes when another document replaces this one (`documentWillSwap`).
    let conversation = AIConversation()
    /// The AI sheet is up. Ask AI on the row and the Menu's Ask AI… open it. The decisions on a
    /// review live only in the sheet, so the sheet never goes while one is up: it cannot be swiped
    /// away while a request runs or a suggestion waits (`AISheetView`), it comes back if a request
    /// or review starts without it (`aiStateChanged`), and if it goes by any other path while a
    /// review is up, the review ends as the sheet's End does (`sheetDidClose`).
    @Published var isShowingAISheet = false {
        didSet { if oldValue, !isShowingAISheet { sheetDidClose() } }
    }
    /// Bumped whenever the format row shows afresh: it opens, or it changes between a caret's row
    /// and a selection's (the writer's own selection). The row starts at its leading edge only
    /// then, never when a command (Check Spelling, Link, Table) merely changes its buttons, so a
    /// repeated tap stays under the finger.
    @Published private(set) var rowGeneration = 0
    /// A Check Spelling that found nothing: the screen's calm notice says so for a few seconds.
    @Published private(set) var spellingNotice: String?
    private var spellingNoticeTask: Task<Void, Never>?
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
    /// The caret's row, brought up to date on the next main-actor turn.
    private var caretRefreshTask: Task<Void, Never>?
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
        conversation.attach(controller)
        conversation.target = { [weak self] in
            guard let editor = self?.editor, editor.isEditable, self?.isReadMode == false else { return nil }
            return AIConversation.Target(range: editor.selectedRange, text: editor.textStorage.string)
        }
        conversation.confirmWholeDocument = { [weak self] words, proceed in
            self?.presentConversationConfirmation(words: words, proceed: proceed)
        }
    }

    // MARK: - The AI sheet

    /// Opens the AI sheet for the selection (Ask AI on the row). The selection stays in the editor:
    /// the sheet's requests go to it.
    func openAISheet() {
        guard connectionStore().isConnected, !isReadMode, editor != nil else { return }
        wireAI(aiController)
        hide()
        isShowingAISheet = true
    }

    /// Another document replaces this one: its conversation goes. A review is left to the
    /// replacement itself (`editorTextWillBeReplaced` abandons it, applying nothing to the outgoing
    /// text once it has been saved), never ended here.
    func documentWillSwap() {
        isSwappingDocument = true
        isShowingAISheet = false
        isSwappingDocument = false
        conversation.reset()
    }

    /// Set while `documentWillSwap` closes the sheet.
    private var isSwappingDocument = false

    /// The sheet went (a swipe it allowed, Read). A review still up would leave the
    /// read-only overlay with no Accept or Reject anywhere: it ends, as the sheet's End does
    /// (undecided changes rejected, accepted ones kept and recorded).
    private func sheetDidClose() {
        guard !isSwappingDocument, let controller = aiControllerStorage, case .reviewing = controller.state else { return }
        controller.handle(.end)
    }

    /// A request or review started while the sheet was not up (it can come no other way now, but
    /// the decisions must never be out of reach): the sheet comes back, on the next turn (this
    /// arrives as the controller's state is about to change).
    private func presentSheetIfWorking() {
        Task { @MainActor [weak self] in
            guard let self, !self.isShowingAISheet, !self.isReadMode, self.editor != nil,
                  let controller = self.aiControllerStorage else { return }
            switch controller.state {
            case .running, .reviewing:
                self.wireAI(controller)
                self.isShowingAISheet = true
            default:
                break
            }
        }
    }

    /// A whole-document request from the sheet above `WholeDocumentAIPolicy.confirmWordCount`.
    private func presentConversationConfirmation(words: Int, proceed: @escaping () -> Void) {
        let store = connectionStore()
        guard let provider = store.connectedProvider else { return }
        let recipient = WholeDocumentAIPolicy.recipient(for: provider, otherEndpoint: store.otherEndpoint)
        presentAlert(Self.wholeDocumentConfirmation(words: words, recipient: recipient, onSend: proceed, onCancel: {}))
    }

    /// The format row's home on the keyboard (`FormatBarAccessoryView`), made with the first editor.
    private(set) lazy var formatBar = FormatBarAccessoryView(controller: self)

    /// The editor's display profile changed (a theme, Automatic Dark Mode): the bar follows it
    /// (its keyboard colour and ink), also while it shows.
    func editorProfileDidChange(_ profile: ReadingProfile) {
        let old = formatBar.style.profile
        guard old != profile else { return }
        formatBar.style.profile = profile
        // The keyboard takes a new appearance only when its input views reload: without this, a
        // switch to dark while typing kept a light keyboard under a dark bar (and the mirror).
        if Theme.theme(for: old).usesDarkChrome != Theme.theme(for: profile).usesDarkChrome,
           let editor, editor.isFirstResponder {
            editor.reloadInputViews()
        }
    }

    /// The editor whose selection the row follows (`MarkdownEditor` calls it). The row becomes
    /// the editor's input accessory, so it rides on the keyboard.
    func attach(_ editor: LineformTextView) {
        guard self.editor !== editor else { return }
        self.editor = editor
        editor.inputAccessoryView = formatBar
        if editor.isFirstResponder { editor.reloadInputViews() }
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
    /// Strikethrough, Code, List, Link, Blockquote, Image, Insert Table, Reformat Table (only when
    /// the selection starts on a table row: elsewhere it would do nothing), Replace With… (only
    /// where History can keep the selection: `offersReplaceWith`), Another Word (one word only,
    /// and only while connected: it is an AI action), and Check Spelling, always last (the one
    /// whole-document spelling pass; it left Settings on 2026-11-24). Insert and Reformat Table
    /// moved here from the Menu; on the Mac they live in Format.
    ///
    /// For a caret (`hasSelection: false`) Replace With… and Another Word never show: both need a
    /// selection. Ask then asks about the whole document (the caller passes `aiConnected` only when
    /// there is text to send).
    static func rowItems(aiConnected: Bool, selectedText: String, offersReplaceWith: Bool,
                         startsOnTableRow: Bool = false, hasSelection: Bool = true) -> [SelectionRowItem] {
        var items: [SelectionRowItem] = aiConnected ? [.askAI] : []
        // (Read mode passes `aiConnected: false`: Read allows no AI.)
        items += [.heading, .bold, .italic, .strikethrough, .code, .list, .link, .blockquote, .image, .insertTable]
        if startsOnTableRow { items.append(.reformatTable) }
        if hasSelection {
            if offersReplaceWith { items.append(.replaceWith) }
            if aiConnected, AIMenuPresentation.isSingleWord(selectedText) { items.append(.anotherWord) }
        }
        items.append(.checkSpelling)
        return items
    }

    /// The row's buttons for `range` in the editor now (a caret or a selection).
    private func currentItems(for range: NSRange, aiConnected: Bool) -> [SelectionRowItem] {
        guard let editor else { return [] }
        guard range.length > 0 else {
            return Self.rowItems(aiConnected: aiConnected && ExportPrintSection.hasText(editor.textStorage.string),
                                 selectedText: "", offersReplaceWith: false,
                                 startsOnTableRow: startsOnTableRow(range), hasSelection: false)
        }
        return Self.rowItems(aiConnected: aiConnected, selectedText: selectedText(in: range),
                             offersReplaceWith: editor.offersReplaceWith(for: range),
                             startsOnTableRow: startsOnTableRow(range))
    }

    // MARK: - When it shows

    /// The editor's selection changed (`textViewDidChangeSelection`). A caret shows the caret's
    /// row while the software keyboard is up and hides the row at once otherwise; a non-empty
    /// selection shows its row once it has stayed the same for `settleDelay`.
    func editorSelectionDidChange() {
        guard !isAdjustingSelection, let editor else { return }
        // A new selection closes the comment (the Mac's card closes on any click); the new
        // selection is then the writer's like any other.
        if phase == .comment { closeCommentForChange() }
        // Composing: the caret's row stays exactly as it is until the composition ends.
        if editor.markedTextRange != nil, isCaretRow { return }
        settleTask?.cancel()
        let range = editor.selectedRange
        // The app's own selection (a Search or Outline jump, a position restore, a review's end)
        // never raises the selection's row; a caret it leaves is still a caret.
        if editor.isSelectionProgrammatic { return range.length == 0 ? caretDidChange() : hide() }
        editor.forgetProgrammaticSelection()
        guard range.length > 0 else { return caretDidChange() }
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
        if phase == .hidden {
            // A composition that hid the selection's row has ended: the caret's row may show.
            if editor?.markedTextRange == nil, editor?.selectedRange.length == 0 { scheduleCaretRefresh() }
            return
        }
        guard phase == .comment else { return }
        closeCommentForChange()
    }

    /// The editor became or stopped being first responder (`textViewDidBeginEditing` /
    /// `textViewDidEndEditing`): the caret's row follows on the next turn.
    func editorFocusDidChange() {
        scheduleCaretRefresh()
    }

    // MARK: - The caret's row

    /// The row is showing for a caret (not a selection).
    private var isCaretRow: Bool { phase == .row && anchorRange?.length == 0 }

    /// The editor is first responder with the software keyboard up.
    private var editorHasSoftwareKeyboard: Bool {
        guard let editor else { return false }
        return editor.isFirstResponder && keyboard.overlap >= Self.minimumSoftwareKeyboardOverlap
    }

    /// The caret's row may show: the selection's rules, plus the software keyboard for this editor,
    /// and never in Read or under the AI sheet.
    private var allowsCaretRow: Bool {
        allowsRow && !isReadMode && !isShowingAISheet && editorHasSoftwareKeyboard
    }

    /// The selection collapsed to a caret (or the caret moved). Without the software keyboard the
    /// row hides at once, as it always has; with it, the caret's row is brought up to date on the
    /// next turn. `anchorRange` is not published, so it follows at once.
    private func caretDidChange() {
        guard let editor, allowsCaretRow else { return hide() }
        if phase == .row { anchorRange = editor.selectedRange }
        scheduleCaretRefresh()
    }

    /// Brings the caret's row up to date on the next main-actor turn: never in the middle of an
    /// edit, an undo or a resign (a screen update there broke the editor's undo grouping), and
    /// coalesced when several changes arrive together.
    private func scheduleCaretRefresh() {
        caretRefreshTask?.cancel()
        caretRefreshTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.refreshCaretRow()
        }
    }

    /// Shows, updates or hides the caret's row. The comment field is never touched, and nothing
    /// changes while an input method is composing. A selection's row is left to its own rules
    /// while the editor keeps its keyboard; once the editor stops being first responder or the
    /// keyboard goes down, the row goes whatever the selection (it rides on the keyboard, so it
    /// would otherwise stay `.row` with nothing on screen).
    private func refreshCaretRow() {
        caretRefreshTask = nil
        updatePageKeyboardOverlap()
        guard let editor, phase != .comment, editor.markedTextRange == nil else { return }
        guard editor.selectedRange.length == 0 else {
            if phase == .row, !editor.isFirstResponder { hide() }
            return
        }
        if allowsCaretRow {
            showRowNow()
        } else if phase == .row {
            hide()
        }
    }

    /// Something changed under the open comment field: it closes, sending nothing and putting no
    /// selection back (the text or the selection is no longer the one it was opened for).
    private func closeCommentForChange() {
        guard phase == .comment else { return }
        hide()
    }

    /// The ⋯ (and Preview's link) button and the Read Aloud pill show unless the comment field has
    /// the bottom, or a request or review is running. While the row shows they float just above it
    /// (`DocumentScreen`), so the menu stays reachable whenever the keyboard is up. A message or
    /// Find's marks leave them reachable: their card sits above the buttons.
    static func showsBottomButtons(phase: Phase, aiState: AIActionController.State) -> Bool {
        guard phase != .comment else { return false }
        switch aiState {
        case .running, .reviewing: return false
        case .idle, .message, .marking, .answer: return true
        }
    }

    /// Shows the row for the editor's current selection, now (for a caret, only while the caret's
    /// row is allowed: `allowsCaretRow`). The settle wait ends here.
    func showRowNow() {
        settleTask?.cancel()
        settleTask = nil
        guard let editor else { return }
        let range = editor.selectedRange
        guard range.length > 0 ? allowsRow : allowsCaretRow else { return hide() }
        let provider = connectionStore().connectedProvider
        let aiName = provider.map { SelectionToolbarPresentation.aiName(for: $0) }
        if model.aiName != aiName { model.aiName = aiName }
        let dark = Theme.theme(for: editor.profile).usesDarkChrome
        if model.usesDarkChrome != dark { model.usesDarkChrome = dark }
        if formatBar.style.profile != editor.profile { formatBar.style.profile = editor.profile }
        let newItems = currentItems(for: range, aiConnected: provider != nil && !isReadMode)
        // A fresh row, or the writer's switch between a caret and a selection: the row starts at
        // its leading edge. A command's own change of buttons keeps it where it is (`runCommand`).
        if phase != .row || (anchorRange?.length == 0) != (range.length == 0) { rowGeneration += 1 }
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

    /// No row while composing, outside an editable editor on screen, under the AI sheet (a
    /// selection made behind it must not raise the row and keyboard over it), or while an AI
    /// request or review is in progress.
    private var allowsRow: Bool {
        guard let editor, editor.window != nil, editor.isEditable, editor.markedTextRange == nil,
              !isShowingAISheet else { return false }
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
        caretRefreshTask?.cancel()
        caretRefreshTask = nil
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
        // With a caret, Ask is for the whole document, through the shared length policy.
        case .askAI:
            guard let editor, editor.markedTextRange == nil else { return }
            if editor.selectedRange.length == 0 { askAIForWholeDocument() } else { openAISheet() }
        // Heading opens the levels in place (`setHeading`); List is a menu (`applyList`).
        case .heading: showHeadingLevels(true)
        // Image is a menu (`pickImage`).
        case .image: break
        case .list: break
        case .insertTable: runCommand { $0.insertTable() }
        case .reformatTable: runCommand { $0.reformatTable() }
        case .bold: runCommand { Self.applyInline(.bold, in: $0) }
        case .italic: runCommand { Self.applyInline(.italic, in: $0) }
        case .strikethrough: runCommand { Self.applyInline(.strikethrough, in: $0) }
        case .code: runCommand { Self.applyInline(.inlineCode, in: $0) }
        // Link with a caret is the Mac's: `[](https://example.com)`, the address selected.
        case .link: runCommand { $0.apply(.link) }
        case .blockquote: runCommand { Self.applyToLine(.blockquote, in: $0) }
        // Check Document Now: the first misspelling after the selection is selected (the row
        // stays, for that selection); no edit, so no undo step.
        case .checkSpelling:
            // Nothing found (with a dictionary, and no composition in the way): the writer hears
            // so, rather than a tap that seems to do nothing.
            guard let editor, editor.markedTextRange == nil else { return }
            var found = false
            runCommand { found = $0.checkDocumentNow() }
            if !found, editor.spellCheckLanguage != nil { showSpellingNotice() }
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
            // Its Accept and Reject live in the AI sheet: the sheet opens first (as Ask does),
            // then the request runs and lands in the conversation.
            guard let range = anchorRange, let editor, !isReadMode, connectionStore().isConnected else { return }
            let text = editor.textStorage.string
            wireAI(aiController)
            hide()
            isShowingAISheet = true
            aiController.run(.anotherWord, range: range, text: text)
        }
    }

    /// What the notice and VoiceOver say when Check Spelling finds nothing.
    static var noSpellingMistakesMessage: String { String(localized: "No spelling mistakes found.") }

    /// "No spelling mistakes found." in the screen's calm notice, for as long as the other notices
    /// stay (`OpenDocument.noticeDuration()`); the screen announces it as it appears.
    private func showSpellingNotice() {
        spellingNoticeTask?.cancel()
        // Already showing (a second tap): the notice stays, and VoiceOver hears it again.
        if spellingNotice != nil { ChromeAnnouncer.announce(Self.noSpellingMistakesMessage) }
        spellingNotice = Self.noSpellingMistakesMessage
        spellingNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: OpenDocument.noticeDuration())
            guard !Task.isCancelled else { return }
            self?.spellingNotice = nil
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
        guard let editor, phase == .row, editor.markedTextRange == nil else { return }
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
        runCommand { Self.applyToLine(ordered ? .orderedList : .unorderedList, in: $0) }
    }

    /// Runs one editor command with the row held still, then adopts the selection (or caret) it
    /// left. Refused while an input method is composing: the composition is never disturbed.
    private func runCommand(_ command: (LineformTextView) -> Void) {
        guard let editor, phase == .row, editor.markedTextRange == nil else { return }
        isAdjustingSelection = true
        command(editor)
        isAdjustingSelection = false
        let range = editor.selectedRange
        guard range.length > 0 || allowsCaretRow else { return hide() }
        anchorRange = range
        let newItems = currentItems(for: range, aiConnected: model.aiName != nil && !isReadMode)
        if items != newItems { items = newItems }
    }

    // MARK: - Caret commands

    /// Bold, Italic, Strikethrough or Code. A selection is formatted as on the Mac. A caret in a
    /// word formats that word (and keeps the caret where it was in it, so a second tap removes the
    /// markers again); a caret outside a word gets the Mac's empty-selection edit, the paired
    /// markers with the caret between. One edit, so one undo step.
    static func applyInline(_ command: MarkdownFormattingCommand, in editor: LineformTextView) {
        let caret = editor.selectedRange
        let text = editor.textStorage.string
        guard caret.length == 0, let word = wordRange(at: caret.location, in: text as NSString) else {
            return editor.apply(command)
        }
        let edit = command.apply(to: text, selectedRange: word)
        // The word moved by the markers added (or removed) before it.
        let shift = edit.selectedRange.location - word.location
        let location = max(0, min(caret.location + shift, (edit.text as NSString).length))
        editor.applyMarkdownEdit(MarkdownEdit(text: edit.text, selectedRange: NSRange(location: location, length: 0)))
    }

    /// List or Blockquote. A selection is prefixed line by line as on the Mac; a caret prefixes
    /// (or un-prefixes) its whole line, the caret moving with its text. One edit, one undo step.
    static func applyToLine(_ command: MarkdownFormattingCommand, in editor: LineformTextView) {
        let caret = editor.selectedRange
        guard caret.length == 0 else { return editor.apply(command) }
        let text = editor.textStorage.string
        let line = lineContentRange(at: caret.location, in: text as NSString)
        let edit = command.apply(to: text, selectedRange: line)
        let shift = edit.selectedRange.length - line.length
        let location = max(line.location, min(caret.location + shift, (edit.text as NSString).length))
        editor.applyMarkdownEdit(MarkdownEdit(text: edit.text, selectedRange: NSRange(location: location, length: 0)))
    }

    /// The word the caret at `location` is in or touches (the system's word boundaries, so
    /// apostrophes and CJK follow the language), or nil between words. Line-local.
    static func wordRange(at location: Int, in text: NSString) -> NSRange? {
        guard location <= text.length else { return nil }
        let line = lineContentRange(at: location, in: text)
        var found: NSRange?
        text.enumerateSubstrings(in: line, options: [.byWords]) { word, range, _, stop in
            if range.location > location { stop.pointee = true; return }
            // The tokenizer can report a lone space between scripts as a "word".
            guard word?.rangeOfCharacter(from: .alphanumerics) != nil else { return }
            if location <= NSMaxRange(range) {
                found = range
                // Inside it: done. At its end: a word starting right here would not exist (words
                // are separated), so this one stands.
                if location < NSMaxRange(range) { stop.pointee = true }
            }
        }
        guard let found, found.length > 0 else { return nil }
        return found
    }

    /// The line `location` is on, without its line ending (`\n`, or `\r\n`). Lines split on
    /// `\n` only, as every line-anchored construct does.
    static func lineContentRange(at location: Int, in text: NSString) -> NSRange {
        let newline = unichar(10)
        var start = min(location, text.length)
        while start > 0, text.character(at: start - 1) != newline { start -= 1 }
        var end = min(location, text.length)
        while end < text.length, text.character(at: end) != newline { end += 1 }
        if end > start, text.character(at: end - 1) == unichar(13) { end -= 1 }
        return NSRange(location: start, length: end - start)
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
    /// send (`ExportPrintSection.hasText`).
    var allowsWholeDocumentAI: Bool {
        guard connectionStore().isConnected, !isReadMode, let editor, editor.isEditable,
              ExportPrintSection.hasText(editor.textStorage.string) else { return false }
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
            wireAI(aiController)
            isShowingAISheet = true
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

    /// The AI sheet, for the whole document (2026-11-24; it was the comment field): the selection
    /// collapses to a caret, so the sheet's requests go to the whole text, and the count the
    /// writer confirmed is not asked about again.
    private func openWholeDocumentComment(confirmedWords: Int?) {
        guard allowsWholeDocumentAI, let editor, connectionStore().connectedProvider != nil else { return }
        hide()
        let selected = editor.selectedRange
        if selected.length > 0 {
            isAdjustingSelection = true
            editor.selectedRange = NSRange(location: selected.location, length: 0)
            isAdjustingSelection = false
        }
        wireAI(aiController)
        conversation.confirmedWholeDocumentWords = confirmedWords
        isShowingAISheet = true
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
        case .answer(let answer): status = answer
        case .marking(let ranges): status = AIActionController.markedMessage(ranges.count)
        case .reviewing(let session):
            status = session.action.reviewsPerCorrection
                ? AIActionController.correctionsSuggestedMessage(session.pending.count)
                : AIActionController.changeSuggestedMessage
        }
        if aiStatus != status { aiStatus = status }
        switch state {
        case .running, .reviewing:
            if phase == .row { hide() }
            if !isShowingAISheet { presentSheetIfWorking() }
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
        case .idle, .message, .answer: break
        }
    }

    /// The mode on screen changed. Read allows no AI: the row goes, a review ends (keeping what was
    /// accepted, as the Mac does), and a request or marks are dropped.
    func displayModeDidChange(to mode: EditorDisplayMode) {
        isReadMode = mode == .read
        guard isReadMode else { return }
        hide()
        isShowingAISheet = false
        guard let controller = aiControllerStorage else { return }
        switch controller.state {
        case .reviewing, .running, .marking:
            controller.endReview()
            controller.abandon()
        case .idle, .message, .answer:
            break
        }
    }

    // MARK: - Keyboard

    /// The keyboard on screen is the editor's: the editor is first responder, or the review
    /// overlay it hands the focus to is. The AI sheet's field, Files' search and History's field
    /// bring up their own keyboards, which must not resize the page (`pageOverlap`).
    var editorOwnsKeyboard: Bool {
        guard let editor else { return false }
        if editor.isFirstResponder { return true }
        return UIResponder.lineformCurrentFirstResponder is AIReviewOverlayTextView
    }

    /// The page's share of the keyboard, after a focus change (no frame notification comes when
    /// one field hands the same keyboard to another).
    private func updatePageKeyboardOverlap() {
        let pageOverlap = editorOwnsKeyboard ? keyboard.overlap : 0
        if keyboard.pageOverlap != pageOverlap { keyboard.pageOverlap = pageOverlap }
    }

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
        // The keyboard (and the row on it) went down: a selection's row goes too, on the next
        // turn (this arrives while the editor may be resigning).
        Task { @MainActor [weak self] in
            guard let self, self.phase == .row, self.keyboard.overlap == 0,
                  self.editor?.markedTextRange == nil else { return }
            self.hide()
        }
    }

    private func setKeyboardOverlap(_ overlap: CGFloat, notification: Notification) {
        let pageOverlap = editorOwnsKeyboard ? overlap : 0
        guard overlap != keyboard.overlap || pageOverlap != keyboard.pageOverlap else { return }
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let animation = EditorMotionPolicy.animation(.easeOut(duration: duration),
                                                     reduceMotion: UIAccessibility.isReduceMotionEnabled)
        let wasSoftware = keyboard.overlap >= Self.minimumSoftwareKeyboardOverlap
        withAnimation(duration > 0 ? animation : nil) {
            if keyboard.overlap != overlap { keyboard.overlap = overlap }
            if keyboard.pageOverlap != pageOverlap { keyboard.pageOverlap = pageOverlap }
        }
        // The bar adds the home indicator's band only with a hardware keyboard.
        if wasSoftware != (overlap >= Self.minimumSoftwareKeyboardOverlap) { formatBar.invalidateIntrinsicContentSize() }
        // The caret's row comes and goes with the software keyboard (on the next turn: this
        // arrives while the editor resigns).
        scheduleCaretRefresh()
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
    /// The part the page makes room for (`KeyboardClearance`): the overlap while the keyboard is
    /// the editor's (`SelectionController.editorOwnsKeyboard`), 0 for any other field's keyboard.
    @Published fileprivate(set) var pageOverlap: CGFloat = 0
}

extension UIResponder {
    /// The first responder in this app, found the system's way (an action sent to nil reaches it).
    @MainActor static var lineformCurrentFirstResponder: UIResponder? {
        FirstResponderProbe.found = nil
        UIApplication.shared.sendAction(#selector(lineformCaptureFirstResponder(_:)), to: nil, from: nil, for: nil)
        defer { FirstResponderProbe.found = nil }
        return FirstResponderProbe.found
    }

    @objc fileprivate func lineformCaptureFirstResponder(_ sender: Any?) {
        MainActor.assumeIsolated { FirstResponderProbe.found = self }
    }
}

@MainActor
private enum FirstResponderProbe {
    static weak var found: UIResponder?
}
