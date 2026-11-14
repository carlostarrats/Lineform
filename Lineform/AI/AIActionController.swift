import Combine
import Foundation

/// The editor as an AI action sees it. The text view implements it: `applyAIEdits` goes through
/// the normal edit path (`shouldChangeText` → `textStorage.replaceCharacters` → `didChangeText`)
/// as ONE undo group named `actionName`, so History hears every edit from its single user-edit
/// source and one decision is one ⌘Z.
@MainActor
protocol AIEditorSurface: AnyObject {
    var string: String { get }
    /// Applies `edits` IN ORDER, each in the coordinates of the text the previous one left.
    /// False when any edit was skipped (it would split a character or touch structure): the
    /// review's ranges no longer describe the text, so the controller ends the review.
    @discardableResult
    func applyAIEdits(_ edits: [AIReviewEdit], actionName: String) -> Bool
    func insertTypedText(_ text: String)
    /// A review just ended, or marks are shown: the passage must not stay selected — the next
    /// keystroke (typing, Delete, Tab, dictation) would replace it, and a selection draws over
    /// Mark's wash. Collapses the selection to `location` (`caretEnd`: the passage's text end).
    func collapseSelectionForAI(at location: Int)
    /// Spoken status (`.announcementRequested`), never written into the text view's AX value.
    func announceAI(_ message: String)
}

/// One action is one change, so a review has one decision: accept it (by id, or the current change
/// with Return), reject it (by id; the card's Reject, Esc and ✕ send `end`, which rejects what is
/// pending), or type (end, then type).
enum AIReviewCommand: Equatable {
    case accept(Int), reject(Int)
    case acceptCurrent, end
    case typed(String)
    /// The card's Try Again: drop this suggestion (nothing was applied) and run the same action
    /// on the same text again, asking for a different result.
    case retry
}

/// Runs one AI action on a selection and holds its review (spec §4, §4.1, §4.3).
///
/// Hard rules, all enforced here:
/// - No request unless connected AND the writer chose an action (`run`). The Keychain is read
///   then, once, through `resolvedConnection()`.
/// - Nothing reaches the document until a change is accepted. Mark changes nothing.
/// - One action is ONE change (`AIChangeBuilder.change`): whatever was selected is a single
///   Accept / Reject decision, applied as one edit per changed segment.
/// - The decision's resulting text must keep the document's Markdown structure byte-for-byte
///   (`MarkdownStructureGuard.verify`) or it is not applied. The whole change is verified when the
///   reply arrives and again, against the current text, when it is accepted.
/// - A reply for text that changed while the request ran is discarded (exact UTF-16 compare).
/// - History records when the review ends, if anything was accepted (one passage per changed
///   paragraph). Live reload abandons
///   the review and records nothing.
@MainActor
final class AIActionController: ObservableObject {
    enum State: Equatable {
        case idle
        case running(AIAction, AIProvider)
        case reviewing(AIReviewSession)
        case marking([NSRange])
        case message(String)
    }

    /// Leaving `.reviewing` — by ANY path (Esc, the card's buttons or ✕, Return, a typed key,
    /// a document swap, abandon, disconnect) — collapses the editor's selection to the end of the
    /// reviewed passage. This is the one choke point: the passage stays selected in the editor
    /// under the overlay, and a keystroke after the review would otherwise replace it.
    @Published private(set) var state: State = .idle {
        didSet {
            guard case .reviewing(let ended) = oldValue else { return }
            if case .reviewing = state { return }
            guard let editor else { return }
            editor.collapseSelectionForAI(at: Self.caretEnd(of: ended.selectionRange, in: editor.string))
        }
    }
    /// A refused decision's explanation, carried from the refusal to the end of `handle`. With one
    /// change per review the refusal is always the last decision, so it ends the review and becomes
    /// `state = .message` (seen, not only announced). Cleared by the next command, `endReview` and
    /// `abandon`. Never drawn on its own: nothing can show it while a review is still up.
    private(set) var reviewNotice: String?
    weak var editor: AIEditorSurface?
    weak var history: DocumentHistoryController?
    private(set) var runTask: Task<Void, Never>?

    private let connectionStore: AIConnectionStore
    private let clientFactory: (AIConnection) -> AIClient
    /// Bumped by every run, cancel and abandon, so a late reply from an old request is ignored.
    private var generation = 0
    /// Who answered the request the current review came from.
    private var reviewProvider: AIProvider?
    /// The reply's segments behind the current review: Try Again asks for something different.
    private var reviewRevisions: [String]?
    private var connectionObservation: AnyCancellable?

    init(connectionStore: AIConnectionStore,
         clientFactory: @escaping (AIConnection) -> AIClient = { AIClientFactory.client(for: $0) }) {
        self.connectionStore = connectionStore
        self.clientFactory = clientFactory
        // `@Published` delivers the NEW value synchronously, on the main actor, before it lands.
        connectionObservation = connectionStore.$connectedProvider
            .dropFirst()
            .sink { [weak self] provider in
                MainActor.assumeIsolated { self?.connectionChanged(to: provider) }
            }
    }

    /// Disconnect (or a switch to another provider) cancels a request in flight and abandons a
    /// review that provider produced: nothing more is sent, and its suggestions leave.
    private func connectionChanged(to provider: AIProvider?) {
        switch state {
        case .running(_, let running) where running != provider:
            abandon()
        case .reviewing where reviewProvider != provider:
            abandon()
        default:
            break
        }
    }

    // MARK: - Messages

    static var tooMuchTextMessage: String { String(localized: "Select less text — about 4,000 words at most.") }
    static var reconnectMessage: String { String(localized: "Connect your AI again in Lineform ▸ Connect Your AI….") }
    static var textChangedMessage: String { String(localized: "The text changed while Lineform was waiting. Nothing was changed.") }
    static var noChangesMessage: String { String(localized: "No changes suggested.") }
    static var nothingToMarkMessage: String { String(localized: "Nothing to mark.") }
    static var structureRefusedMessage: String { String(localized: "That change would alter the Markdown, so it wasn't applied.") }
    static var reviewEndedMessage: String { String(localized: "Review ended") }
    static var editSkippedMessage: String { String(localized: "That change couldn't be applied, so the review ended.") }
    static var acceptOneActionName: String { String(localized: "Accept Suggestion") }

    /// One action is one change, so a review always opens with exactly one.
    static var changeSuggestedMessage: String { String(localized: "1 change suggested") }

    /// What a reply that changes nothing says. Proofread: "No changes suggested." (no errors is a
    /// legitimate answer). An action that must change the text (`mustChangeText`) never says
    /// that: a reply identical to the selection is "<AI> returned the same text. Try again.", and
    /// one whose changes were all refused (structure, length) is an unusable response.
    static func unchangedMessage(for action: AIAction, provider: AIProvider,
                                 segments: [ProseSegment], revisions: [String]) -> String {
        guard action.mustChangeText else { return noChangesMessage }
        let identical = zip(segments, revisions).allSatisfy { segment, revision in
            revision.trimmingCharacters(in: .whitespacesAndNewlines)
                == segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return identical ? AIReviewCardPresentation.sameTextMessage(provider: provider)
                         : AIClientError.unusableResponse.message
    }

    static func markedMessage(_ count: Int) -> String {
        count == 1 ? String(localized: "1 sentence marked") : String(localized: "\(count) sentences marked")
    }

    // MARK: - Availability

    private var isBusy: Bool {
        switch state {
        case .running, .reviewing: return true
        case .idle, .marking, .message: return false
        }
    }

    private func allowsRun(on range: NSRange) -> Bool {
        connectionStore.isConnected && range.length > 0 && !isBusy && history?.allowsAIAction(on: range) != false
    }

    /// Whole-document structure analysis: call when a menu opens, never per keystroke.
    func isAvailable(for range: NSRange, text: String) -> Bool {
        guard allowsRun(on: range) else { return false }
        return !MarkdownStructureMap.proseSegments(in: text, selection: range).isEmpty
    }

    // MARK: - Running

    private enum Request {
        case edit([ProseSegment])
        case mark([AISentence])
    }

    /// `avoiding`: the segments of a suggestion just discarded by Try Again; the prompt asks for a
    /// different result (`AIActionPrompt.editPrompt(_:segments:avoiding:)`).
    func run(_ action: AIAction, range: NSRange, text: String, avoiding: [String]? = nil) {
        guard allowsRun(on: range) else { return }
        let ns = text as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        guard clamped.length > 0 else { return }
        let selection = ns.rangeOfComposedCharacterSequences(for: clamped)

        let request: Request
        let pieces: [String]
        if action.isMark {
            let sentences = AISentenceSplitter.sentences(in: text, selection: selection)
            guard !sentences.isEmpty else { return show(Self.nothingToMarkMessage) }
            request = .mark(sentences)
            pieces = sentences.map(\.prose)
        } else {
            let segments = MarkdownStructureMap.proseSegments(in: text, selection: selection)
            guard !segments.isEmpty else { return show(Self.noChangesMessage) }
            request = .edit(segments)
            pieces = segments.map(\.text)
        }
        let proseLength = pieces.reduce(0) { $0 + ($1 as NSString).length }
        guard pieces.count <= AILimits.maxSegments, proseLength <= AILimits.maxProseUTF16 else {
            return show(Self.tooMuchTextMessage)
        }
        guard let connection = connectionStore.resolvedConnection() else {
            return show(Self.reconnectMessage)
        }

        let prompt: AIPrompt
        switch request {
        case .edit:
            // Only a list that still lines up with the segments being sent.
            let avoid = avoiding?.count == pieces.count ? avoiding : nil
            prompt = AIActionPrompt.editPrompt(action, segments: pieces, avoiding: avoid)
        case .mark: prompt = AIActionPrompt.markPrompt(action, sentences: pieces)
        }
        let client = clientFactory(connection)
        // History mode on? Its selected passage is remembered and History mode ends; the action's
        // end brings it back (`settleHistory`).
        history?.aiActionWillStart()
        generation += 1
        let token = generation
        state = .running(action, connection.provider)
        editor?.announceAI(action.progressVerb)
        runTask = Task { [weak self] in
            let result: Result<String, AIClientError>
            do {
                result = .success(try await client.complete(prompt))
            } catch let error as AIClientError {
                result = .failure(error)
            } catch {
                result = .failure(Task.isCancelled ? .cancelled : .unusableResponse)
            }
            self?.finish(token: token, action: action, request: request, selection: selection,
                         snapshot: text, result: result)
        }
    }

    func cancel() {
        guard case .running = state else { return }
        stopRequest()
        state = .idle
        settleHistory(recorded: nil)
    }

    /// The action is over (no review, request or marks remain): History comes back on the passage
    /// it was on when the action started, or remembers an accept's passage
    /// (`DocumentHistoryController.aiActionDidEnd`).
    private func settleHistory(recorded: UUID?, changedRange: NSRange? = nil) {
        guard let history else { return }
        // No editor, no text to locate in (locating in the wrong text would drop passages).
        guard let editor else { return history.aiActionAbandoned() }
        history.aiActionDidEnd(recorded: recorded, changedRange: changedRange, text: editor.string)
    }

    /// Live reload (or any wholesale text replacement): reload wins. Cancels a request, drops a
    /// review or marks, and records nothing in History.
    func abandon() {
        stopRequest()
        reviewNotice = nil
        reviewProvider = nil
        reviewRevisions = nil
        state = .idle
        history?.aiActionAbandoned()
    }

    /// History is about to open on a passage (Add to History, a document's first accepted change): History
    /// and AI never overlap. A request or review ends (keeping what was accepted); Mark's wash is
    /// dismissed. A message is left up — the first-accept show arrives just after a review
    /// ended, and dropping it then would lose a refusal.
    func yieldToHistory() {
        switch state {
        case .running, .reviewing:
            endReview(settlingHistory: false)
            abandon()
        case .marking:
            dismissMarks()
        case .idle, .message:
            break
        }
        // History opens on its own target: it must not ALSO come back where it was.
        history?.aiActionAbandoned()
    }

    func dismissMarks() {
        if case .marking = state { state = .idle }
    }

    func dismissMessage() {
        if case .message = state { state = .idle }
    }

    private func stopRequest() {
        generation += 1
        runTask?.cancel()
        runTask = nil
    }

    private func show(_ message: String) {
        state = .message(message)
        editor?.announceAI(message)
    }

    private func finish(token: Int, action: AIAction, request: Request, selection: NSRange,
                        snapshot: String, result: Result<String, AIClientError>) {
        guard token == generation, case .running(_, let provider) = state else { return }
        runTask = nil
        defer {
            switch state {
            case .reviewing: break // the review's end settles History
            case .marking: history?.aiActionAbandoned() // History would dismiss the marks at once
            case .idle, .running, .message: settleHistory(recorded: nil)
            }
        }
        let reply: String
        switch result {
        case .failure(.cancelled):
            state = .idle
            return
        case .failure(let error):
            return show(error.message)
        case .success(let text):
            reply = text
        }
        // Exact UTF-16: a canonically equal but renormalized text still moves offsets.
        guard let editor, editor.string.utf16.elementsEqual(snapshot.utf16) else {
            return show(Self.textChangedMessage)
        }

        switch request {
        case .mark(let sentences):
            guard let indices = AIResponseParser.sentenceIndices(from: reply, sentenceCount: sentences.count) else {
                return show(AIClientError.unusableResponse.message)
            }
            guard !indices.isEmpty else { return show(Self.nothingToMarkMessage) }
            state = .marking(indices.map { sentences[$0].range })
            // The selection would draw over the wash and hide it.
            editor.collapseSelectionForAI(at: Self.caretEnd(of: selection, in: snapshot))
            editor.announceAI(Self.markedMessage(indices.count))

        case .edit(let segments):
            guard let revisions = AIResponseParser.segments(from: reply, expectedCount: segments.count) else {
                return show(AIClientError.unusableResponse.message)
            }
            let admitted = MarkdownStructureGuard.admissibleRevisions(revisions, for: segments, in: snapshot)
            // ONE change for the whole selection: one Accept / Reject decision, however many
            // segments (and whatever Markdown between them) it spans.
            guard let change = AIChangeBuilder.change(segments: segments, revisions: admitted, in: snapshot) else {
                return show(Self.unchangedMessage(for: action, provider: provider, segments: segments, revisions: revisions))
            }
            guard MarkdownStructureGuard.verify(original: snapshot, revised: Self.applying(change.edits(), to: snapshot)) else {
                return show(AIClientError.unusableResponse.message)
            }
            let ns = snapshot as NSString
            reviewProvider = provider
            reviewRevisions = revisions
            state = .reviewing(AIReviewSession(action: action, changes: [change], selectionRange: selection,
                                               originalSelection: ns.substring(with: selection)))
            editor.announceAI(Self.changeSuggestedMessage)
        }
    }

    // MARK: - Review

    func handle(_ command: AIReviewCommand) {
        guard case .reviewing(var session) = state, let editor else { return }
        reviewNotice = nil
        switch command {
        case .accept(let id):
            let before = (editor.string as NSString).length
            guard accept(id, in: &session, editor: editor) else { return endAfterSkippedEdit(session, lengthBefore: before) }
        case .acceptCurrent:
            // A change is current from the moment the review opens; the fallback only guards.
            guard let id = session.currentID ?? session.pending.first?.id else { return }
            let before = (editor.string as NSString).length
            guard accept(id, in: &session, editor: editor) else { return endAfterSkippedEdit(session, lengthBefore: before) }
        case .reject(let id):
            session.reject(id)
        case .end:
            endReview()
            return
        case .typed(let text):
            // Typing goes on writing: History must not reopen under the keystroke.
            endReview(settlingHistory: false)
            history?.aiActionAbandoned()
            editor.insertTypedText(text)
            return
        case .retry:
            // Only before anything was accepted: the document then still holds the original
            // text at the session's range (a review applies nothing until Accept).
            guard !session.acceptedAny else { return }
            let previous = reviewRevisions
            // The action goes on: History stays settled-later (the re-run keeps its context).
            endReview(settlingHistory: false)
            run(session.action, range: session.selectionRange, text: editor.string, avoiding: previous)
            return
        }
        state = .reviewing(session)
        if session.isFinished {
            let notice = reviewNotice
            endReview()
            // A refusal that was the last decision: the review is gone, so the refusal is the
            // message the status card shows (already announced when it was refused).
            if let notice { state = .message(notice) }
        }
    }

    /// Ends the review — Esc, ✕, the last decision, typing, a document swap. It is an explicit
    /// REJECT of whatever is still pending: nothing pending is applied, and the text keeps it as it
    /// was. When anything was accepted, History records the original plus the accepted result —
    /// one passage per changed paragraph of the selection (`acceptedPassages`); otherwise nothing.
    /// Returns the ended session (every change decided), nil when no review was up.
    /// `settlingHistory` false: the action is not over (Try Again) or must not bring History back
    /// (typing, History opening on its own target).
    @discardableResult
    func endReview(settlingHistory: Bool = true) -> AIReviewSession? {
        guard case .reviewing(var session) = state else { return nil }
        var firstRecorded: UUID?
        var changedRange: NSRange?
        var introduction: (id: UUID, documentHadHistory: Bool)?
        for change in session.pending { session.reject(change.id) }
        reviewNotice = nil
        reviewProvider = nil
        reviewRevisions = nil
        state = .idle
        if session.acceptedAny, let editor, let history {
            let text = editor.string
            let ns = text as NSString
            let range = session.selectionRange
            if range.location >= 0, NSMaxRange(range) <= ns.length {
                // Read BEFORE recording: the accept that gives a document its first History shows it.
                let documentHadHistory = history.hasHistory
                let accepted = ns.substring(with: range)
                changedRange = range
                for passage in Self.acceptedPassages(original: session.originalSelection, accepted: accepted,
                                                     at: range.location) {
                    let id = history.recordAccepted(range: passage.range, original: passage.original,
                                                    accepted: passage.accepted, text: text)
                    if firstRecorded == nil { firstRecorded = id }
                }
                // The accept that gives this document its first History shows it, focused on
                // what it recorded; later accepts in the same document leave the sidebar alone.
                if let firstRecorded { introduction = (firstRecorded, documentHadHistory) }
            }
        }
        editor?.announceAI(Self.reviewEndedMessage)
        if settlingHistory { settleHistory(recorded: firstRecorded, changedRange: changedRange) }
        // After settling: a show on its own target spends any passage just remembered.
        if let introduction {
            history?.introduceAfterAIAccept(introduction.id, documentHadHistory: introduction.documentHadHistory)
        }
        return session
    }

    /// What History records for an accepted selection: one passage per CHANGED paragraph
    /// (ruling: a selection spanning several paragraphs records each, rather than nothing).
    ///
    /// Accepted edits never add or remove a line ending, so the original and accepted selections
    /// have the same lines, pairwise. Paragraphs are runs of lines that are non-blank in the
    /// original. Each paragraph's text is edge-trimmed on both sides, and `range` is where the
    /// accepted text sits in the document. A selection inside one line is one piece: the selection
    /// itself, trimmed. Line counts that disagree (never expected) also record one piece.
    static func acceptedPassages(original: String, accepted: String, at location: Int)
        -> [(range: NSRange, original: String, accepted: String)] {
        guard !accepted.utf16.elementsEqual(original.utf16) else { return [] }
        let before = markdownSourceLines(in: original)
        let after = markdownSourceLines(in: accepted)
        let beforeNS = original as NSString
        let afterNS = accepted as NSString

        func piece(_ beforeRange: NSRange, _ afterRange: NSRange) -> (range: NSRange, original: String, accepted: String)? {
            let b = PassageHistoryText.aligned(beforeRange, in: original)
            let a = PassageHistoryText.aligned(afterRange, in: accepted)
            guard a.length > 0, b.length > 0 else { return nil }
            let o = beforeNS.substring(with: b)
            let n = afterNS.substring(with: a)
            guard !o.utf16.elementsEqual(n.utf16) else { return nil }
            return (NSRange(location: location + a.location, length: a.length), o, n)
        }

        guard before.lines.count == after.lines.count, before.lines.count > 1 else {
            return piece(NSRange(location: 0, length: beforeNS.length),
                         NSRange(location: 0, length: afterNS.length)).map { [$0] } ?? []
        }
        var result: [(range: NSRange, original: String, accepted: String)] = []
        var runStart: Int?
        func flush(through last: Int) {
            guard let first = runStart else { return }
            runStart = nil
            let b = NSRange(location: before.ranges[first].location,
                            length: NSMaxRange(before.ranges[last]) - before.ranges[first].location)
            let a = NSRange(location: after.ranges[first].location,
                            length: NSMaxRange(after.ranges[last]) - after.ranges[first].location)
            if let p = piece(b, a) { result.append(p) }
        }
        for index in before.lines.indices {
            if before.lines[index].trimmingCharacters(in: markdownLineTrimCharacters).isEmpty {
                flush(through: index - 1)
            } else if runStart == nil {
                runStart = index
            }
        }
        flush(through: before.lines.count - 1)
        return result
    }

    /// False when the editor skipped the edit: the review must end (`endAfterSkippedEdit`).
    private func accept(_ id: Int, in session: inout AIReviewSession, editor: AIEditorSurface) -> Bool {
        var candidate = session
        // One edit per changed segment of the change, all one decision: verified together, one
        // `applyAIEdits` call, one undo group.
        let edits = candidate.accept(id)
        guard !edits.isEmpty else {
            // Already decided.
            session = candidate
            return true
        }
        guard isStructurePreserving(edits, in: editor.string) else {
            session.reject(id)
            editor.announceAI(Self.structureRefusedMessage)
            reviewNotice = Self.structureRefusedMessage
            return true
        }
        guard editor.applyAIEdits(edits, actionName: Self.acceptOneActionName) else { return false }
        session = candidate
        return true
    }

    /// The editor skipped an edit (never expected: every edit was verified). The session's ranges
    /// no longer describe the text, so the review ends at once — no later decision may aim at
    /// shifted text — and History records nothing. Whatever did land stays, and is one ⌘Z.
    /// `session` is the review before the failed decision; `lengthBefore` the text's length then.
    private func endAfterSkippedEdit(_ session: AIReviewSession, lengthBefore: Int? = nil) {
        reviewNotice = nil
        reviewProvider = nil
        show(Self.editSkippedMessage)
        settleHistory(recorded: nil)
        guard let editor, let lengthBefore else { return }
        // The edits all lie inside the passage, so its end moved by however much did land.
        let moved = (editor.string as NSString).length - lengthBefore
        let shifted = NSRange(location: session.selectionRange.location,
                              length: max(0, session.selectionRange.length + moved))
        editor.collapseSelectionForAI(at: Self.caretEnd(of: shifted, in: editor.string))
    }

    /// Where the caret goes when an AI selection collapses: the END of the passage's text, before
    /// any line endings the selection ends with. A triple-click selects a line WITH its "\n" (or
    /// "\r\n"); NSMaxRange would put the caret at the start of the NEXT line, and a typed key
    /// would land there.
    static func caretEnd(of range: NSRange, in text: String) -> Int {
        let ns = text as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        var end = NSMaxRange(clamped)
        while end > clamped.location {
            let unit = ns.character(at: end - 1)
            guard unit == 0x0A || unit == 0x0D else { break }
            end -= 1
        }
        return end
    }

    private func isStructurePreserving(_ edits: [AIReviewEdit], in text: String) -> Bool {
        MarkdownStructureGuard.verify(original: text, revised: Self.applying(edits, to: text))
    }

    /// Applies `edits` in order, each in the coordinates the previous one left.
    nonisolated static func applying(_ edits: [AIReviewEdit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits {
            guard edit.range.location >= 0, NSMaxRange(edit.range) <= result.length else { continue }
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }
}
