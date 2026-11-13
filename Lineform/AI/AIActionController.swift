import Foundation

/// The editor as an AI action sees it. The text view implements it: `applyAIEdits` goes through
/// the normal edit path (`shouldChangeText` → `textStorage.replaceCharacters` → `didChangeText`)
/// as ONE undo group named `actionName`, so History hears every edit from its single user-edit
/// source and one decision is one ⌘Z.
@MainActor
protocol AIEditorSurface: AnyObject {
    var string: String { get }
    /// Applies `edits` IN ORDER, each in the coordinates of the text the previous one left.
    func applyAIEdits(_ edits: [AIReviewEdit], actionName: String)
    func insertTypedText(_ text: String)
    /// Spoken status (`.announcementRequested`), never written into the text view's AX value.
    func announceAI(_ message: String)
}

enum AIReviewCommand: Equatable {
    case accept(Int), reject(Int), toggleKeep(Int)
    case acceptCurrent, next, previous, acceptRemaining, rejectRemaining, end
    case typed(String)
}

/// Runs one AI action on a selection and holds its review (spec §4, §4.1, §4.3).
///
/// Hard rules, all enforced here:
/// - No request unless connected AND the writer chose an action (`run`). The Keychain is read
///   then, once, through `resolvedConnection()`.
/// - Nothing reaches the document until a change is accepted. Mark changes nothing.
/// - Every decision's resulting text must keep the document's Markdown structure byte-for-byte
///   (`MarkdownStructureGuard.verify`) or it is not applied. The whole reply was verified, but a
///   SUBSET of its changes can still re-pair structure (`$5` → `5$` split in two, one half alone
///   making `$5$` math), so each decision is verified on its own.
/// - A reply for text that changed while the request ran is discarded (exact UTF-16 compare).
/// - History records once, when the review ends, if anything was accepted. Live reload abandons
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

    @Published private(set) var state: State = .idle
    weak var editor: AIEditorSurface?
    weak var history: DocumentHistoryController?
    private(set) var runTask: Task<Void, Never>?

    private let connectionStore: AIConnectionStore
    private let clientFactory: (AIConnection) -> AIClient
    /// Bumped by every run, cancel and abandon, so a late reply from an old request is ignored.
    private var generation = 0

    init(connectionStore: AIConnectionStore,
         clientFactory: @escaping (AIConnection) -> AIClient = { AIClientFactory.client(for: $0) }) {
        self.connectionStore = connectionStore
        self.clientFactory = clientFactory
    }

    // MARK: - Messages

    static var tooMuchTextMessage: String { String(localized: "Select less text — about 4,000 words at most.") }
    static var reconnectMessage: String { String(localized: "Connect your AI again in Lineform ▸ Connect Your AI….") }
    static var textChangedMessage: String { String(localized: "The text changed while Lineform was waiting. Nothing was changed.") }
    static var noChangesMessage: String { String(localized: "No changes suggested.") }
    static var nothingToMarkMessage: String { String(localized: "Nothing to mark.") }
    static var structureRefusedMessage: String { String(localized: "That change would alter the Markdown, so it wasn't applied.") }
    static var reviewEndedMessage: String { String(localized: "Review ended") }
    static var acceptOneActionName: String { String(localized: "Accept Suggestion") }
    static var acceptManyActionName: String { String(localized: "Accept Suggestions") }

    static func changesSuggestedMessage(_ count: Int) -> String {
        count == 1 ? String(localized: "1 change suggested") : String(localized: "\(count) changes suggested")
    }

    static func positionMessage(_ current: Int, of total: Int) -> String {
        String(localized: "Change \(current) of \(total)")
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

    func run(_ action: AIAction, range: NSRange, text: String) {
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
        case .edit: prompt = AIActionPrompt.editPrompt(action, segments: pieces)
        case .mark: prompt = AIActionPrompt.markPrompt(action, sentences: pieces)
        }
        let client = clientFactory(connection)
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
    }

    /// Live reload (or any wholesale text replacement): reload wins. Cancels a request, drops a
    /// review or marks, and records nothing in History.
    func abandon() {
        stopRequest()
        state = .idle
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
        guard token == generation, case .running = state else { return }
        runTask = nil
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
            editor.announceAI(Self.markedMessage(indices.count))

        case .edit(let segments):
            guard let revisions = AIResponseParser.segments(from: reply, expectedCount: segments.count) else {
                return show(AIClientError.unusableResponse.message)
            }
            let admitted = MarkdownStructureGuard.admissibleRevisions(revisions, for: segments, in: snapshot)
            let changes = AIChangeBuilder.changes(segments: segments, revisions: admitted, in: snapshot)
            guard !changes.isEmpty else { return show(Self.noChangesMessage) }
            let composed = Self.applying(changes.map { AIReviewEdit(range: $0.range, replacement: $0.replacement) }
                .sorted { $0.range.location > $1.range.location }, to: snapshot)
            guard MarkdownStructureGuard.verify(original: snapshot, revised: composed) else {
                return show(AIClientError.unusableResponse.message)
            }
            let ns = snapshot as NSString
            state = .reviewing(AIReviewSession(action: action, changes: changes, selectionRange: selection,
                                               originalSelection: ns.substring(with: selection)))
            editor.announceAI(Self.changesSuggestedMessage(changes.count))
        }
    }

    // MARK: - Review

    func handle(_ command: AIReviewCommand) {
        guard case .reviewing(var session) = state, let editor else { return }
        switch command {
        case .accept(let id):
            accept(id, in: &session, editor: editor)
        case .acceptCurrent:
            guard let id = session.currentID else { return }
            accept(id, in: &session, editor: editor)
        case .reject(let id):
            session.reject(id)
        case .toggleKeep(let id):
            session.toggleKeep(id)
            state = .reviewing(session)
            return
        case .next, .previous:
            session.move(by: command == .next ? 1 : -1)
        case .acceptRemaining:
            var candidate = session
            let edits = candidate.acceptRemaining()
            if !edits.isEmpty {
                guard isStructurePreserving(edits, in: editor.string) else {
                    editor.announceAI(Self.structureRefusedMessage)
                    return
                }
                editor.applyAIEdits(edits, actionName: edits.count == 1 ? Self.acceptOneActionName : Self.acceptManyActionName)
            }
            session = candidate
        case .rejectRemaining:
            session.rejectRemaining()
        case .end:
            return endReview()
        case .typed(let text):
            endReview()
            editor.insertTypedText(text)
            return
        }
        state = .reviewing(session)
        if session.isFinished {
            endReview()
        } else {
            let position = session.position
            editor.announceAI(Self.positionMessage(position.current, of: position.total))
        }
    }

    /// Ends the review: undecided changes are rejected (the text keeps them as they were). When
    /// anything was accepted, History records ONE passage for the selection: the original plus
    /// the accepted result.
    func endReview() {
        guard case .reviewing(var session) = state else { return }
        session.rejectRemaining()
        state = .idle
        if session.acceptedAny, let editor, let history {
            let ns = editor.string as NSString
            let range = session.selectionRange
            if range.location >= 0, NSMaxRange(range) <= ns.length {
                let accepted = ns.substring(with: range)
                if !accepted.utf16.elementsEqual(session.originalSelection.utf16) {
                    history.recordAccepted(range: range, original: session.originalSelection,
                                           accepted: accepted, text: editor.string)
                }
            }
        }
        editor?.announceAI(Self.reviewEndedMessage)
    }

    private func accept(_ id: Int, in session: inout AIReviewSession, editor: AIEditorSurface) {
        var candidate = session
        guard let edit = candidate.accept(id) else {
            // Already decided, or a kept pure deletion (decided, nothing to write).
            session = candidate
            return
        }
        guard isStructurePreserving([edit], in: editor.string) else {
            session.reject(id)
            editor.announceAI(Self.structureRefusedMessage)
            return
        }
        editor.applyAIEdits([edit], actionName: Self.acceptOneActionName)
        session = candidate
    }

    private func isStructurePreserving(_ edits: [AIReviewEdit], in text: String) -> Bool {
        MarkdownStructureGuard.verify(original: text, revised: Self.applying(edits, to: text))
    }

    /// Applies `edits` in order, each in the coordinates the previous one left.
    static func applying(_ edits: [AIReviewEdit], to text: String) -> String {
        let result = NSMutableString(string: text)
        for edit in edits {
            guard edit.range.location >= 0, NSMaxRange(edit.range) <= result.length else { continue }
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }
}
