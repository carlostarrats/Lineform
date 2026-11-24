import Combine
import Foundation

/// The editor as an AI action sees it. The text view implements it: `applyAIEdits` goes through
/// the normal edit path (`shouldChangeText` → `textStorage.replaceCharacters` → `didChangeText`)
/// as ONE undo group named `actionName`, so History hears every edit from its single user-edit
/// source and one decision is one ⌘Z.
@MainActor
public protocol AIEditorSurface: AnyObject {
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
public enum AIReviewCommand: Equatable {
    case accept(Int), reject(Int)
    case acceptCurrent, end
    /// Esc and the card's Reject: the current change is rejected (and the next becomes current;
    /// a one-change review then ends).
    case rejectCurrent
    /// Proofread's Accept All: every change still pending.
    case acceptAll
    /// ← / →: the previous or next pending change.
    case move(Int)
    /// A click on a pending change in the overlay.
    case select(Int)
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
public final class AIActionController: ObservableObject {
    public enum State: Equatable {
        case idle
        case running(AIAction, AIProvider)
        case reviewing(AIReviewSession)
        case marking([NSRange])
        case message(String)
        /// A question's prose answer (the AI drawer): nothing to review, nothing changes.
        case answer(String)
    }

    /// Leaving `.reviewing` — by ANY path (Esc, the card's buttons or ✕, Return, a typed key,
    /// a document swap, abandon, disconnect) — collapses the editor's selection to the end of the
    /// reviewed passage. This is the one choke point: the passage stays selected in the editor
    /// under the overlay, and a keystroke after the review would otherwise replace it.
    @Published public private(set) var state: State = .idle {
        didSet {
            guard case .reviewing(let ended) = oldValue else { return }
            if case .reviewing = state { return }
            guard let editor else { return }
            editor.collapseSelectionForAI(at: Self.caretEnd(of: ended.selectionRange, in: editor.string))
        }
    }
    public weak var editor: (any AIEditorSurface)?
    /// Where a review's accepted changes go when the editor is ALREADY gone at the review's end
    /// (2026-11-14: switching to Read tears the Write text view down before `onChange(of:
    /// displayMode)` ends the review, and the accepted Proofread decisions were silently lost).
    /// `text` reads the document; `apply` writes the edits (descending) into it, reporting each to
    /// History as a user edit. Set by the editor around that call only.
    public var documentFallback: (text: () -> String, apply: ([AIReviewEdit]) -> Void)?
    public weak var history: (any AIHistoryRecording)?
    public private(set) var runTask: Task<Void, Never>?
    /// The version behind the current review (set just before `state` becomes `.reviewing`):
    /// the AI drawer keeps each one, so the writer can step back to it (`restoreReview`).
    public private(set) var currentVersion: AIReviewVersion?

    private let connectionStore: AIConnectionStore
    private let clientFactory: (AIConnection) -> AIClient
    /// Bumped by every run, cancel and abandon, so a late reply from an old request is ignored.
    private var generation = 0
    /// Who answered the request the current review came from.
    private var reviewProvider: AIProvider?
    /// The reply's segments behind the current review: Try Again asks for something different.
    private var reviewRevisions: [String]?
    /// The writer's note for the request behind the current run or review (the selection toolbar's
    /// comment). Try Again sends it again.
    private var reviewNote: String?
    /// The current run or review is for the whole document (Ask AI with nothing selected):
    /// its limit message is `WholeDocumentAIPolicy.refusalMessage`, and Try Again keeps it.
    private var requestIsWholeDocument = false
    private var connectionObservation: AnyCancellable?

    public init(connectionStore: AIConnectionStore,
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

    public static var tooMuchTextMessage: String { String(localized: "Select less text — about 4,000 words at most.", bundle: .module) }
    public static var reconnectMessage: String { reconnectMessage(bundle: .module) }
    /// The Mac points at its menu bar; the iPhone at Menu ▸ Settings.
    static func reconnectMessage(bundle: Bundle) -> String {
        guard !AIDeviceWording.namesPhone else {
            return String(localized: "Connect your AI again in Menu ▸ Settings ▸ Connect Your AI….", bundle: bundle)
        }
        return String(localized: "Connect your AI again in Lineform ▸ Connect Your AI….", bundle: bundle)
    }
    public static var textChangedMessage: String { String(localized: "The text changed while Lineform was waiting. Nothing was changed.", bundle: .module) }
    public static var noChangesMessage: String { String(localized: "No changes suggested.", bundle: .module) }
    public static var nothingToMarkMessage: String { String(localized: "No sentences found.", bundle: .module) }
    public static var structureRefusedMessage: String { String(localized: "That change would alter the Markdown, so it wasn't applied.", bundle: .module) }
    public static var reviewEndedMessage: String { String(localized: "Review ended", bundle: .module) }
    public static var editSkippedMessage: String { String(localized: "That change couldn't be applied, so the review ended.", bundle: .module) }
    public static var acceptOneActionName: String { String(localized: "Accept Suggestion", bundle: .module) }

    /// Proofread's corrections, each verified ON ITS OWN against the structure guard (any subset
    /// may be accepted). One that fails is first merged with its neighbours in the same segment —
    /// a token MOVE (`$5` → `5$`) diffs into a deletion and an insertion, and only the two
    /// together keep the structure — and dropped only if no merge passes. Ids renumbered from 0.
    public static func structurePreservingCorrections(_ corrections: [AIChange], segments: [ProseSegment],
                                               in text: String) -> [AIChange] {
        let ns = text as NSString
        func verifies(_ change: AIChange) -> Bool {
            MarkdownStructureGuard.verify(original: text, revised: applying(change.edits(), to: text))
        }
        func segment(of change: AIChange) -> NSRange? {
            segments.first { NSIntersectionRange($0.range, change.range) == change.range
                && change.range.location >= $0.range.location && NSMaxRange(change.range) <= NSMaxRange($0.range) }?.range
        }
        func merged(_ a: AIChange, _ b: AIChange) -> AIChange {
            let between = NSRange(location: NSMaxRange(a.range), length: b.range.location - NSMaxRange(a.range))
            let range = NSRange(location: a.range.location, length: NSMaxRange(b.range) - a.range.location)
            return AIChange(id: 0, range: range, original: ns.substring(with: range),
                            replacement: a.replacement + ns.substring(with: between) + b.replacement)
        }
        let sorted = corrections.sorted { $0.range.location < $1.range.location }
        var kept: [AIChange] = []
        var index = 0
        while index < sorted.count {
            var change = sorted[index]
            var last = index
            while !verifies(change), last + 1 < sorted.count,
                  let home = segment(of: change), segment(of: sorted[last + 1]) == home {
                last += 1
                change = merged(change, sorted[last])
            }
            if verifies(change) {
                kept.append(change)
            } else if let previous = kept.last, let home = segment(of: change), segment(of: previous) == home,
                      verifies(merged(previous, change)) {
                kept[kept.count - 1] = merged(previous, change)
            }
            index = last + 1
        }
        return kept.enumerated().map { id, change in
            AIChange(id: id, range: change.range, original: change.original, replacement: change.replacement)
        }
    }

    /// A Rewrite-family action is one change, so its review opens with exactly one.
    public static var changeSuggestedMessage: String { String(localized: "1 change suggested", bundle: .module) }

    /// Proofread opens with one suggestion per correction.
    public static func correctionsSuggestedMessage(_ count: Int) -> String {
        String(localized: "\(count) corrections suggested", bundle: .module)
    }

    /// What a reply that changes nothing says. Proofread: "No changes suggested." (no errors is a
    /// legitimate answer). An action that must change the text (`mustChangeText`) never says
    /// that: a reply identical to the selection is "<AI> returned the same text. Try again.", and
    /// one whose changes were all refused (structure, length) is an unusable response.
    public static func unchangedMessage(for action: AIAction, provider: AIProvider,
                                 segments: [ProseSegment], revisions: [String]) -> String {
        guard action.mustChangeText else { return noChangesMessage }
        let identical = zip(segments, revisions).allSatisfy { segment, revision in
            revision.trimmingCharacters(in: .whitespacesAndNewlines)
                == segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return identical ? AIReviewCardPresentation.sameTextMessage(provider: provider)
                         : AIClientError.unusableResponse.message
    }

    public static func markedMessage(_ count: Int) -> String {
        String(localized: "\(count) sentences found", bundle: .module)
    }

    // MARK: - Availability

    private var isBusy: Bool {
        switch state {
        case .running, .reviewing: return true
        case .idle, .marking, .message, .answer: return false
        }
    }

    private func allowsRun(on range: NSRange) -> Bool {
        connectionStore.isConnected && range.length > 0 && !isBusy && history?.allowsAIAction(on: range) != false
    }

    /// Whole-document structure analysis: call when a menu opens, never per keystroke.
    public func isAvailable(for range: NSRange, text: String) -> Bool {
        guard allowsRun(on: range) else { return false }
        return !MarkdownStructureMap.proseSegments(in: text, selection: range).isEmpty
    }

    // MARK: - Running

    private enum Request {
        case edit([ProseSegment])
        case mark([AISentence])
        /// A question about the prose: answered in words (`.answer`), never reviewed.
        case question([ProseSegment])
    }

    /// `avoiding`: the segments of a suggestion just discarded by Try Again; the prompt asks for a
    /// different result (`AIActionPrompt.editPrompt(_:segments:avoiding:)`).
    public func run(_ action: AIAction, range: NSRange, text: String, avoiding: [String]? = nil, note: String? = nil) {
        start(action, range: range, text: text, avoiding: avoiding, note: note, wholeDocument: false)
    }

    /// Ask AI for the whole document (nothing selected): the range is the whole text. Refused by
    /// `WholeDocumentAIPolicy` past `AILimits` — the message card says so, before the Keychain is
    /// read. The confirmation above `WholeDocumentAIPolicy.confirmWordCount` words is the
    /// caller's, before the comment field opens.
    public func runWholeDocument(_ action: AIAction, text: String, avoiding: [String]? = nil, note: String?) {
        guard WholeDocumentAIPolicy.decision(for: text) != .refuse else { return refuseWholeDocument() }
        start(action, range: NSRange(location: 0, length: (text as NSString).length), text: text,
              avoiding: avoiding, note: note, wholeDocument: true)
    }

    /// A question about the selection (`AIRequestClassifier.isQuestion`): its prose is sent with
    /// the question, and the reply is a prose answer (`.answer`). Same gates as `run`.
    public func ask(_ question: String, range: NSRange, text: String) {
        guard let question = AIActionPrompt.trimmedNote(question) else { return }
        start(.custom, range: range, text: text, avoiding: nil, note: nil, wholeDocument: false, question: question)
    }

    /// A question about the whole document, through `WholeDocumentAIPolicy` like `runWholeDocument`.
    public func askWholeDocument(_ question: String, text: String) {
        guard let question = AIActionPrompt.trimmedNote(question) else { return }
        guard WholeDocumentAIPolicy.decision(for: text) != .refuse else { return refuseWholeDocument() }
        start(.custom, range: NSRange(location: 0, length: (text as NSString).length), text: text,
              avoiding: nil, note: nil, wholeDocument: true, question: question)
    }

    /// The whole-document refusal, through the ordinary message card. Nothing is read or sent.
    public func refuseWholeDocument() {
        guard connectionStore.isConnected, !isBusy else { return }
        show(WholeDocumentAIPolicy.refusalMessage)
    }

    private func start(_ action: AIAction, range: NSRange, text: String, avoiding: [String]?, note: String?,
                       wholeDocument: Bool, question: String? = nil) {
        guard allowsRun(on: range) else { return }
        let note = AIActionPrompt.trimmedNote(note)
        // Custom IS the note: without one there is nothing to ask.
        guard action != .custom || note != nil || question != nil else { return }
        let ns = text as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        guard clamped.length > 0 else { return }
        // Grown over any History passage the selection only partly covers: the accepted change
        // then never straddles (and drops) a passage boundary.
        let widened = history?.aiActionRange(for: clamped) ?? clamped
        let selection = ns.rangeOfComposedCharacterSequences(
            for: NSIntersectionRange(widened, NSRange(location: 0, length: ns.length)))

        let request: Request
        let pieces: [String]
        if question != nil {
            let segments = MarkdownStructureMap.proseSegments(in: text, selection: selection)
            guard !segments.isEmpty else { return show(Self.noChangesMessage) }
            request = .question(segments)
            pieces = segments.map(\.text)
        } else if action.isMark {
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
            return show(wholeDocument ? WholeDocumentAIPolicy.refusalMessage : Self.tooMuchTextMessage)
        }
        guard let connection = connectionStore.resolvedConnection() else {
            return show(Self.reconnectMessage)
        }

        let prompt: AIPrompt
        switch request {
        case .edit:
            // Only a list that still lines up with the segments being sent.
            let avoid = avoiding?.count == pieces.count ? avoiding : nil
            prompt = AIActionPrompt.editPrompt(action, segments: pieces, avoiding: avoid, note: note)
        case .mark: prompt = AIActionPrompt.markPrompt(action, sentences: pieces, note: note)
        case .question: prompt = AIActionPrompt.questionPrompt(question ?? "", segments: pieces)
        }
        reviewNote = note
        requestIsWholeDocument = wholeDocument
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

    public func cancel() {
        guard case .running = state else { return }
        stopRequest()
        state = .idle
        settleHistory(recorded: nil)
    }

    /// The action is over (no review, request or marks remain): History comes back on the passage
    /// it was on when the action started, or remembers an accept's passage
    /// (`AIHistoryRecording.aiActionDidEnd`).
    private func settleHistory(recorded: UUID?, changedRange: NSRange? = nil) {
        guard let history else { return }
        // No editor (nor document fallback), no text to locate in (locating in the wrong text
        // would drop passages).
        guard let text = editor?.string ?? documentFallback?.text() else { return history.aiActionAbandoned() }
        history.aiActionDidEnd(recorded: recorded, changedRange: changedRange, text: text)
    }

    /// Live reload (or any wholesale text replacement): reload wins. Cancels a request, drops a
    /// review or marks, and records nothing in History.
    public func abandon() {
        stopRequest()
        reviewProvider = nil
        reviewRevisions = nil
        state = .idle
        history?.aiActionAbandoned()
    }

    /// History is about to open on a passage (Replace With…, a return after an AI action): History
    /// and AI never overlap. A request or review ends (keeping what was accepted); Mark's wash is
    /// dismissed. A message is left up — the first-accept show arrives just after a review
    /// ended, and dropping it then would lose a refusal.
    public func yieldToHistory() {
        switch state {
        case .running, .reviewing:
            endReview(settlingHistory: false)
            abandon()
        case .marking:
            dismissMarks()
        case .idle, .message, .answer:
            break
        }
        // History opens on its own target: it must not ALSO come back where it was.
        history?.aiActionAbandoned()
    }

    public func dismissMarks() {
        if case .marking = state { state = .idle }
    }

    public func dismissMessage() {
        switch state {
        case .message, .answer: state = .idle
        default: break
        }
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
            case .idle, .running, .message, .answer: settleHistory(recorded: nil)
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
        case .question:
            guard let answer = AIResponseParser.answer(from: reply, allowsPlainText: true) else {
                return show(AIClientError.unusableResponse.message)
            }
            state = .answer(answer)
            editor.announceAI(answer)

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
                // A typed instruction that was really a question is answered in words.
                if action == .custom, let answer = AIResponseParser.answer(from: reply) {
                    state = .answer(answer)
                    editor.announceAI(answer)
                    return
                }
                return show(AIClientError.unusableResponse.message)
            }
            let admitted = MarkdownStructureGuard.admissibleRevisions(revisions, for: segments, in: snapshot)
            let ns = snapshot as NSString
            if action.reviewsPerCorrection {
                // Proofread: one suggestion per correction (a word-level diff of each segment).
                let corrections = AIWordDiff.corrections(segments: segments, revisions: admitted, in: snapshot)
                guard !corrections.isEmpty else {
                    // Nothing to fix is a real answer; fixes the structure guard refused are not.
                    let refusedSome = zip(zip(segments, revisions), admitted).contains { pair, admittedRevision in
                        admittedRevision == nil
                            && pair.1.trimmingCharacters(in: .whitespacesAndNewlines) != pair.0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    return show(refusedSome ? AIClientError.unusableResponse.message
                                            : Self.unchangedMessage(for: action, provider: provider, segments: segments, revisions: revisions))
                }
                let kept = Self.structurePreservingCorrections(corrections, segments: segments, in: snapshot)
                guard !kept.isEmpty else { return show(AIClientError.unusableResponse.message) }
                reviewProvider = provider
                reviewRevisions = revisions
                let session = AIReviewSession(action: action, changes: kept, selectionRange: selection,
                                              originalSelection: ns.substring(with: selection))
                currentVersion = AIReviewVersion(session: session, snapshot: snapshot, segments: segments,
                                                 revisions: revisions, assumptions: [], provider: provider,
                                                 note: reviewNote, wholeDocument: requestIsWholeDocument)
                state = .reviewing(session)
                editor.announceAI(Self.correctionsSuggestedMessage(kept.count))
                return
            }
            // ONE change for the whole selection: one Accept / Reject decision, however many
            // segments (and whatever Markdown between them) it spans.
            guard let change = AIChangeBuilder.change(segments: segments, revisions: admitted, in: snapshot) else {
                return show(Self.unchangedMessage(for: action, provider: provider, segments: segments, revisions: revisions))
            }
            guard MarkdownStructureGuard.verify(original: snapshot, revised: Self.applying(change.edits(), to: snapshot)) else {
                return show(AIClientError.unusableResponse.message)
            }
            reviewProvider = provider
            reviewRevisions = revisions
            let session = AIReviewSession(action: action, changes: [change], selectionRange: selection,
                                          originalSelection: ns.substring(with: selection))
            // Blanks only for a typed instruction, and only those its admitted text still holds.
            let revised = zip(segments, admitted).map { $1 ?? $0.text }
            let assumptions = action == .custom ? AIResponseParser.assumptions(from: reply, revisions: revised) : []
            currentVersion = AIReviewVersion(session: session, snapshot: snapshot, segments: segments,
                                             revisions: revisions, assumptions: assumptions, provider: provider,
                                             note: reviewNote, wholeDocument: requestIsWholeDocument)
            state = .reviewing(session)
            editor.announceAI(Self.changeSuggestedMessage)
        }
    }

    // MARK: - Versions and blanks

    /// Puts an earlier version of this review back on screen (the drawer's ‹ ›), or brings one back
    /// after a Try Again that failed. Only for the SAME text it was built from (exact UTF-16), the
    /// same provider still connected, and nothing accepted yet; nothing is sent. False otherwise.
    @discardableResult
    public func restoreReview(_ version: AIReviewVersion) -> Bool {
        guard let editor, connectionStore.connectedProvider == version.provider,
              editor.string.utf16.elementsEqual(version.snapshot.utf16) else { return false }
        switch state {
        case .reviewing(let session):
            guard !session.acceptedAny else { return false }
        case .idle, .message, .answer:
            guard history?.allowsAIAction(on: version.session.selectionRange) != false else { return false }
            history?.aiActionWillStart()
        case .running, .marking:
            return false
        }
        reviewProvider = version.provider
        reviewRevisions = version.revisions
        reviewNote = version.note
        requestIsWholeDocument = version.wholeDocument
        currentVersion = version
        state = .reviewing(version.session)
        return true
    }

    /// Fills in a blank: every occurrence of the assumption's phrase in the suggestion becomes
    /// `choice`, through the same structure guard and change builder as a reply (no request). The
    /// review then shows the new text, without that assumption. False (nothing changes) when the
    /// result would alter the Markdown, or the review moved on.
    @discardableResult
    public func applyAssumption(_ assumption: AIAssumption, choice: String) -> Bool {
        guard case .reviewing(let current) = state, !current.acceptedAny,
              let version = currentVersion, version.session == current,
              let index = version.assumptions.firstIndex(of: assumption) else { return false }
        let choice = choice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !choice.isEmpty, !choice.unicodeScalars.contains(where: {
            let category = $0.properties.generalCategory
            return category == .control || category == .lineSeparator || category == .paragraphSeparator
        }) else { return false }
        let snapshot = version.snapshot
        let admittedBefore = MarkdownStructureGuard.admissibleRevisions(version.revisions, for: version.segments,
                                                                         in: snapshot)
        let revised = zip(version.segments, admittedBefore).map { segment, admitted in
            (admitted ?? segment.text).replacingOccurrences(of: assumption.phrase, with: choice)
        }
        let admitted = MarkdownStructureGuard.admissibleRevisions(revised, for: version.segments, in: snapshot)
        // Every segment that took the choice must still be admitted, or the blank is refused whole.
        let allAdmitted = zip(admitted, zip(version.segments, revised)).allSatisfy { admittedRevision, pair in
            admittedRevision != nil || pair.1 == pair.0.text
        }
        guard allAdmitted,
              let change = AIChangeBuilder.change(segments: version.segments, revisions: admitted, in: snapshot),
              MarkdownStructureGuard.verify(original: snapshot, revised: Self.applying(change.edits(), to: snapshot)) else {
            editor?.announceAI(Self.structureRefusedMessage)
            return false
        }
        var remaining = version.assumptions
        remaining.remove(at: index)
        let session = AIReviewSession(action: current.action, changes: [change], selectionRange: current.selectionRange,
                                      originalSelection: current.originalSelection)
        let next = AIReviewVersion(session: session, snapshot: snapshot, segments: version.segments, revisions: revised,
                                   assumptions: remaining, provider: version.provider, note: version.note,
                                   wholeDocument: version.wholeDocument)
        reviewRevisions = revised
        currentVersion = next
        state = .reviewing(session)
        return true
    }

    // MARK: - Review

    public func handle(_ command: AIReviewCommand) {
        guard case .reviewing(var session) = state, let editor else { return }
        switch command {
        case .accept(let id):
            session.accept(id)
        case .acceptCurrent:
            // A change is current from the moment the review opens; the fallback only guards.
            guard let id = session.currentID ?? session.pending.first?.id else { return }
            session.accept(id)
        case .reject(let id):
            session.reject(id)
        case .rejectCurrent:
            guard let id = session.currentID ?? session.pending.first?.id else { return }
            session.reject(id)
        case .acceptAll:
            session.acceptAllPending()
        case .move(let delta):
            session.move(by: delta)
        case .select(let id):
            session.select(id)
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
            // Only before anything was accepted: a retry discards the suggestion, and the
            // decisions made in it would be lost silently.
            guard !session.acceptedAny else { return }
            let previous = reviewRevisions
            let wholeDocument = requestIsWholeDocument
            // The action goes on: History stays settled-later (the re-run keeps its context).
            endReview(settlingHistory: false)
            start(session.action, range: session.selectionRange, text: editor.string, avoiding: previous,
                  note: reviewNote, wholeDocument: wholeDocument)
            return
        }
        state = .reviewing(session)
        if session.isFinished { endReview() }
    }

    /// Ends the review — Esc, ✕, the last decision, typing, a document swap. It is an explicit
    /// REJECT of whatever is still pending: nothing pending is applied, and the text keeps it as it
    /// was. When anything was accepted, History records the original plus the accepted result —
    /// one passage per changed paragraph of the selection (`acceptedPassages`); otherwise nothing.
    /// Returns the ended session (every change decided), nil when no review was up.
    /// `settlingHistory` false: the action is not over (Try Again) or must not bring History back
    /// (typing, History opening on its own target).
    @discardableResult
    public func endReview(settlingHistory: Bool = true) -> AIReviewSession? {
        guard case .reviewing(var session) = state else { return nil }
        var firstRecorded: UUID?
        var changedRange: NSRange?
        for change in session.pending { session.reject(change.id) }
        reviewProvider = nil
        reviewRevisions = nil

        // Every accepted change is applied NOW, together: one `applyAIEdits` call, one undo step.
        // Each range must still read what was reviewed (defence in depth: every known writer ends
        // the review first), then the structure guard checks the whole accepted result.
        enum Outcome { case nothingAccepted, applied, refused, skipped, stale }
        var outcome = Outcome.nothingAccepted
        let edits = session.acceptedEdits
        if !edits.isEmpty, let current = editor?.string ?? documentFallback?.text() {
            let ns = current as NSString
            let intact = session.accepted.allSatisfy { change in
                change.range.location >= 0 && NSMaxRange(change.range) <= ns.length
                    && ns.substring(with: change.range).utf16.elementsEqual(change.original.utf16)
            }
            if !intact {
                outcome = .stale
            } else if !isStructurePreserving(edits, in: current) {
                outcome = .refused
            } else if let editor {
                let before = ns.length
                history?.aiAcceptWillApply()
                let appliedAll = editor.applyAIEdits(edits, actionName: Self.acceptOneActionName)
                history?.aiAcceptDidApply()
                session.shiftSelection(by: (editor.string as NSString).length - before)
                outcome = appliedAll ? .applied : .skipped
            } else if let fallback = documentFallback {
                history?.aiAcceptWillApply()
                fallback.apply(edits)
                history?.aiAcceptDidApply()
                session.shiftSelection(by: AIReviewSession.lengthDelta(of: edits))
                outcome = .applied
            }
        }
        // Through `.reviewing` first, so the `didSet` collapse aims at the selection as it is now.
        state = .reviewing(session)
        state = .idle

        if outcome == .applied, let history, let text = editor?.string ?? documentFallback?.text() {
            let ns = text as NSString
            let range = session.selectionRange
            if range.location >= 0, NSMaxRange(range) <= ns.length {
                let accepted = ns.substring(with: range)
                changedRange = range
                for passage in Self.acceptedPassages(original: session.originalSelection, accepted: accepted,
                                                     at: range.location) {
                    let id = history.recordAccepted(range: passage.range, original: passage.original,
                                                    accepted: passage.accepted, text: text)
                    if firstRecorded == nil { firstRecorded = id }
                }
            }
        }
        // Set-aside passages the recording could not file go now (2026-11-13: History never
        // opens by itself after an accept — the remembered passage waits for the History tab).
        if outcome == .applied || outcome == .skipped { history?.aiAcceptRecordingDidFinish() }
        switch outcome {
        case .refused:
            // Nothing was applied; the refusal is what the status card shows.
            show(Self.structureRefusedMessage)
        case .skipped:
            // Whatever did land stays (one ⌘Z); History records nothing.
            show(Self.editSkippedMessage)
        case .stale:
            // The text under the review changed: nothing is spliced at offsets that moved.
            show(Self.textChangedMessage)
        case .nothingAccepted, .applied:
            editor?.announceAI(Self.reviewEndedMessage)
        }
        if settlingHistory { settleHistory(recorded: firstRecorded, changedRange: changedRange) }
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
    public static func acceptedPassages(original: String, accepted: String, at location: Int)
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

    /// Where the caret goes when an AI selection collapses: the END of the passage's text, before
    /// any line endings the selection ends with. A triple-click selects a line WITH its "\n" (or
    /// "\r\n"); NSMaxRange would put the caret at the start of the NEXT line, and a typed key
    /// would land there.
    public static func caretEnd(of range: NSRange, in text: String) -> Int {
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
    nonisolated public static func applying(_ edits: [AIReviewEdit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits {
            guard edit.range.location >= 0, NSMaxRange(edit.range) <= result.length else { continue }
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }
}

/// One suggestion as the AI drawer keeps it: the review it opens, the text it was built from, and
/// what the selection reads with every change in it accepted (`displayText`, the bubble's text).
public struct AIReviewVersion: Equatable {
    public let session: AIReviewSession
    public let snapshot: String
    public let assumptions: [AIAssumption]
    /// The selection as it would read with this version accepted: only the new text.
    public let displayText: String
    let segments: [ProseSegment]
    let revisions: [String]
    let provider: AIProvider
    let note: String?
    let wholeDocument: Bool

    init(session: AIReviewSession, snapshot: String, segments: [ProseSegment], revisions: [String],
         assumptions: [AIAssumption], provider: AIProvider, note: String?, wholeDocument: Bool) {
        self.session = session
        self.snapshot = snapshot
        self.segments = segments
        self.revisions = revisions
        self.assumptions = assumptions
        self.provider = provider
        self.note = note
        self.wholeDocument = wholeDocument
        let edits = session.changes.flatMap { $0.edits() }.sorted { $0.range.location > $1.range.location }
        let revised = AIActionController.applying(edits, to: snapshot) as NSString
        let range = session.selectionRange
        let length = range.length + AIReviewSession.lengthDelta(of: edits)
        if range.location >= 0, length >= 0, range.location + length <= revised.length {
            displayText = revised.substring(with: NSRange(location: range.location, length: length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            displayText = ""
        }
    }
}
