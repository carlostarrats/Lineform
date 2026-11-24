import Combine
import Foundation

/// The AI drawer's conversation (the Mac's right-side drawer, the iPhone's sheet): the writer's
/// requests and the AI's replies for ONE open document, in memory only. It is never written
/// anywhere, and it is cleared when the document closes (`reset`).
///
/// It drives the window's `AIActionController` and mirrors it; every rule of an AI action stays
/// the controller's (structure guard, nothing in the text until Accept, one History record, the
/// Keychain read only when a request starts, `WholeDocumentAIPolicy`). What it adds:
/// - quick actions (`runQuickAction`) and typed instructions (`send`): a clear question is
///   answered in prose (`AIRequestClassifier`), anything else is a Custom edit whose curated words
///   travel as explicit directions (`AIPromptLexicon.instruction`);
/// - a suggestion's versions: Try Again keeps the same bubble and adds a version, ‹ › steps
///   between them, and Accept takes the version on screen (`AIActionController.restoreReview`);
/// - blanks: a guess in a reply that the writer fills in, with no request
///   (`AIActionController.applyAssumption`);
/// - the options card for a curated word or a blank (`card`), one at a time.
@MainActor
public final class AIConversation: ObservableObject {
    public struct Suggestion: Equatable {
        public fileprivate(set) var versions: [AIReviewVersion]
        public fileprivate(set) var index: Int
        /// Accept / Reject / Try Again are offered (the review is up).
        public fileprivate(set) var isPending: Bool
        /// Try Again is running: the bubble keeps its text, dimmed, until the new version arrives.
        public fileprivate(set) var isRetrying: Bool

        public var current: AIReviewVersion { versions[index] }
        /// "v2", 1-based.
        public var versionNumber: Int { index + 1 }
    }

    public enum Content: Equatable {
        /// What the writer sent, as plain text (a typed instruction, or a quick action's title).
        case request(String)
        case suggestion(Suggestion)
        /// A prose answer to a question.
        case answer(String)
        /// A status from the AI: an error, "No changes suggested.", Find's count.
        case notice(String)
    }

    public struct Message: Identifiable, Equatable {
        public let id: UUID
        public fileprivate(set) var content: Content

        public var isWriter: Bool {
            if case .request = content { return true }
            return false
        }

        public var suggestion: Suggestion? {
            if case .suggestion(let suggestion) = content { return suggestion }
            return nil
        }
    }

    /// The options card above the input. While it is up, everything else dims and stops responding.
    public enum Card: Equatable {
        /// A curated word typed in the input: several refinements may be chosen.
        case word(AIPromptWord)
        /// A blank in a suggestion: one option, or something typed.
        case blank(messageID: UUID, assumption: AIAssumption)

        public var question: String {
            switch self {
            case .word(let word): return word.question
            case .blank(_, let assumption): return assumption.question
            }
        }
    }

    /// Where a request goes: the editor's selection and text, read when the writer sends.
    public struct Target: Equatable {
        public let range: NSRange
        public let text: String

        public init(range: NSRange, text: String) {
            self.range = range
            self.text = text
        }
    }

    @Published public private(set) var messages: [Message] = []
    /// The input's text. Matching runs on every change, on the device.
    @Published public var draft: String = "" {
        didSet {
            guard draft != oldValue else { return }
            refreshMatches()
        }
    }
    @Published public private(set) var matches: [AIPromptWordMatch] = []
    /// Refinements the writer applied, by word id (a solid underline). A word never opened sends
    /// its defaults (`AIPromptLexicon.directions`).
    @Published public private(set) var choices: [String: [String]] = [:]
    @Published public private(set) var card: Card?
    /// A request is in flight (not a Try Again, which works inside its bubble).
    @Published public private(set) var isWorking = false

    public let words: [AIPromptWord]
    /// The editor's selection and text right now; nil when no editor can take a request.
    public var target: () -> Target? = { nil }
    /// Asks the writer before a whole document over `WholeDocumentAIPolicy.confirmWordCount`
    /// words is sent; calls `proceed` only on Send.
    public var confirmWholeDocument: (_ words: Int, _ proceed: @escaping () -> Void) -> Void = { _, _ in }

    private weak var controller: AIActionController?
    private var observation: AnyCancellable?
    /// The request bubble waiting for its reply.
    private var awaitingID: UUID?
    /// The suggestion a Try Again or a decision is for.
    private var retryingID: UUID?
    private var rejectingID: UUID?
    /// The Try Again request is running (its reply is a new version, not a decision's echo).
    private var retryRequestStarted = false
    /// The conversation itself is changing the review (a version step, a blank): no new bubble.
    private var isChangingReviewLocally = false

    public init(words: [AIPromptWord] = AIPromptLexicon.current) {
        self.words = words
    }

    // MARK: - Wiring

    /// Follows `controller` (the window's or screen's). One conversation is attached at a time.
    public func attach(_ controller: AIActionController) {
        guard self.controller !== controller || observation == nil else { return }
        self.controller = controller
        observation = controller.$state
            .dropFirst()
            .sink { [weak self] state in
                MainActor.assumeIsolated { self?.controllerWillEnter(state) }
            }
    }

    public func detach() {
        observation = nil
        controller = nil
        awaitingID = nil
        retryingID = nil
        rejectingID = nil
        isWorking = false
        for index in messages.indices {
            guard case .suggestion(var suggestion) = messages[index].content, suggestion.isPending || suggestion.isRetrying else { continue }
            suggestion.isPending = false
            suggestion.isRetrying = false
            messages[index].content = .suggestion(suggestion)
        }
    }

    /// The document closed: the conversation is gone.
    public func reset() {
        messages = []
        draft = ""
        choices = [:]
        card = nil
        isWorking = false
        awaitingID = nil
        retryingID = nil
        rejectingID = nil
    }

    // MARK: - What the drawer shows

    /// Before anything is sent: the note and the quick actions.
    public var hasStarted: Bool { !messages.isEmpty || isWorking }

    /// The suggestion whose Accept / Reject / Try Again are up, if any.
    public var pendingSuggestion: (id: UUID, suggestion: Suggestion)? {
        for message in messages.reversed() {
            if let suggestion = message.suggestion, suggestion.isPending { return (message.id, suggestion) }
        }
        return nil
    }

    public var isRetrying: Bool { pendingSuggestion?.suggestion.isRetrying == true }

    public var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking && !isRetrying && card == nil
    }

    /// The quick actions: the rewrite actions and Proofread.
    public static let quickActions: [AIAction] = [.proofread, .trim, .cutInHalf, .rephrase, .simplify, .moreFormal, .moreCasual]

    public func word(for match: AIPromptWordMatch) -> AIPromptWord? {
        words.first { $0.id == match.wordID }
    }

    public func isChosen(_ wordID: String) -> Bool { choices[wordID] != nil }

    // MARK: - Sending

    public func runQuickAction(_ action: AIAction) {
        guard !isWorking, !isRetrying, card == nil, let target = currentTarget() else { return }
        submit(display: action.title, target: target) { controller, target, whole in
            if whole { controller.runWholeDocument(action, text: target.text, note: nil) }
            else { controller.run(action, range: target.range, text: target.text) }
        }
    }

    /// Sends the typed instruction. A clear question is answered in prose; anything else is an
    /// edit, with the curated words' directions and the keep-constraint appended.
    public func send() {
        guard canSend, let target = currentTarget() else { return }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = AIRequestClassifier.isQuestion(typed, words: words)
        let instruction = AIPromptLexicon.instruction(typed, choices: choices, words: words)
        let previousDraft = draft
        let previousChoices = choices
        draft = ""
        choices = [:]
        let sent = submit(display: typed, target: target) { controller, target, whole in
            switch (question, whole) {
            case (true, true): controller.askWholeDocument(typed, text: target.text)
            case (true, false): controller.ask(typed, range: target.range, text: target.text)
            case (false, true): controller.runWholeDocument(.custom, text: target.text, note: instruction)
            case (false, false): controller.run(.custom, range: target.range, text: target.text, note: instruction)
            }
        }
        if !sent {
            draft = previousDraft
            choices = previousChoices
        }
    }

    /// Cancels the request in flight.
    public func stop() {
        controller?.cancel()
    }

    /// The selection a request goes to. With a suggestion pending, a new instruction is about the
    /// same passage: the review ends (rejected, nothing applied) and the request goes to its range.
    private func currentTarget() -> Target? {
        guard let controller else { return nil }
        if let pending = pendingSuggestion, case .reviewing(let session) = controller.state {
            let text = target()?.text ?? pending.suggestion.current.snapshot
            rejectingID = nil
            controller.handle(.end)
            markNotPending(pending.id)
            return Target(range: session.selectionRange, text: text)
        }
        return target()
    }

    /// Adds the request bubble and runs it. The whole document (nothing selected) goes through
    /// `WholeDocumentAIPolicy`: refused past the limit, confirmed above 1,500 words. False when
    /// nothing was sent (the bubble is taken back).
    @discardableResult
    private func submit(display: String, target: Target,
                       run: @escaping (AIActionController, Target, Bool) -> Void) -> Bool {
        guard controller != nil else { return false }
        let whole = target.range.length == 0
        let wholeTarget = Target(range: NSRange(location: 0, length: (target.text as NSString).length), text: target.text)
        let start: () -> Bool = { [weak self] in
            guard let self, let controller = self.controller else { return false }
            let id = UUID()
            self.messages.append(Message(id: id, content: .request(display)))
            self.awaitingID = id
            run(controller, whole ? wholeTarget : target, whole)
            // Refused without a word (History mode, a busy controller): the bubble goes.
            if self.awaitingID == id, !self.isWorking {
                self.awaitingID = nil
                self.messages.removeAll { $0.id == id }
                return false
            }
            return true
        }
        guard whole else { return start() }
        switch WholeDocumentAIPolicy.decision(for: target.text) {
        case .run, .refuse:
            // The controller refuses past the limit itself, on a notice.
            return start()
        case .confirm(let count):
            confirmWholeDocument(count) { _ = start() }
            return true
        }
    }

    // MARK: - A suggestion's decisions

    public func accept() {
        guard let pending = pendingSuggestion, !pending.suggestion.isRetrying, let controller,
              case .reviewing = controller.state else { return }
        controller.handle(.acceptAll)
        // Normally the review has ended now; a review still up (never expected) keeps its buttons.
        if case .reviewing = controller.state { return }
        markNotPending(pending.id)
    }

    /// Reject leaves no trace: the request and the suggestion go, and with nothing left the drawer
    /// is back at its start.
    public func reject() {
        guard let pending = pendingSuggestion, let controller else { return }
        rejectingID = pending.id
        if case .reviewing = controller.state {
            controller.handle(.end)
        } else {
            removeRejected()
        }
    }

    public func tryAgain() {
        guard let pending = pendingSuggestion, !pending.suggestion.isRetrying, let controller,
              case .reviewing(let session) = controller.state, !session.acceptedAny else { return }
        retryingID = pending.id
        update(pending.id) { $0.isRetrying = true }
        controller.handle(.retry)
        if case .running = controller.state { return }
        // The retry could not start: the version on screen comes back.
        finishRetry(restoring: true)
    }

    /// ‹ › : the version on screen. While the review is up, the review follows it, so Accept takes it.
    public func showVersion(_ index: Int, of messageID: UUID) {
        guard let position = messages.firstIndex(where: { $0.id == messageID }),
              var suggestion = messages[position].suggestion, !suggestion.isRetrying,
              suggestion.versions.indices.contains(index), index != suggestion.index else { return }
        if suggestion.isPending, let controller {
            isChangingReviewLocally = true
            let restored = controller.restoreReview(suggestion.versions[index])
            isChangingReviewLocally = false
            guard restored else { return }
        }
        suggestion.index = index
        messages[position].content = .suggestion(suggestion)
    }

    // MARK: - The options card

    public func openWord(_ match: AIPromptWordMatch) {
        guard card == nil, let word = word(for: match) else { return }
        card = .word(word)
    }

    public func openBlank(_ assumption: AIAssumption, in messageID: UUID) {
        guard card == nil, let pending = pendingSuggestion, pending.id == messageID,
              !pending.suggestion.isRetrying, pending.suggestion.current.assumptions.contains(assumption) else { return }
        card = .blank(messageID: messageID, assumption: assumption)
    }

    /// What the card starts with: the word's applied refinements (or its defaults), or the blank's guess.
    public var cardSelection: [String] {
        switch card {
        case .word(let word): return choices[word.id] ?? word.defaults
        case .blank(_, let assumption): return [assumption.phrase]
        case nil: return []
        }
    }

    /// Apply: a word's refinements turn its underline solid; a blank rewrites the reply.
    public func applyCard(_ selection: [String]) {
        switch card {
        case .word(let word):
            choices[word.id] = selection.filter { word.refinement($0) != nil }
            card = nil
        case .blank(let messageID, let assumption):
            guard let choice = selection.last?.trimmingCharacters(in: .whitespacesAndNewlines), !choice.isEmpty else {
                card = nil
                return
            }
            card = nil
            guard let controller, let pending = pendingSuggestion, pending.id == messageID else { return }
            isChangingReviewLocally = true
            let applied = controller.applyAssumption(assumption, choice: choice)
            isChangingReviewLocally = false
            guard applied, let version = controller.currentVersion else { return }
            update(messageID) { $0.versions[$0.index] = version }
        case nil:
            break
        }
    }

    /// ✕ or Esc: nothing changes.
    public func cancelCard() {
        card = nil
    }

    // MARK: - Following the controller

    private func controllerWillEnter(_ state: AIActionController.State) {
        switch state {
        case .running(let action, _):
            if retryingID != nil {
                retryRequestStarted = true
                return
            }
            if awaitingID == nil {
                // Started elsewhere (the context menu, Another Word): it is part of the conversation.
                let id = UUID()
                messages.append(Message(id: id, content: .request(action.title)))
                awaitingID = id
            }
            isWorking = true

        case .reviewing:
            guard !isChangingReviewLocally, let version = controller?.currentVersion else { return }
            let isRetryReply = retryingID != nil && retryRequestStarted
            // The same review with decisions recorded (the controller passes through `.reviewing`
            // as it ends, and on every overlay decision): not a new reply.
            if !isRetryReply, messages.contains(where: { $0.suggestion?.versions.contains(version) == true }) {
                return
            }
            if isRetryReply, let id = retryingID {
                retryRequestStarted = false
                retryingID = nil
                update(id) { suggestion in
                    suggestion.versions.append(version)
                    suggestion.index = suggestion.versions.count - 1
                    suggestion.isRetrying = false
                    suggestion.isPending = true
                }
            } else {
                messages.append(Message(id: UUID(), content: .suggestion(Suggestion(
                    versions: [version], index: 0, isPending: true, isRetrying: false))))
            }
            awaitingID = nil
            isWorking = false

        case .answer(let text):
            append(.answer(text))
            dismissControllerMessage()

        case .message(let text):
            append(.notice(text))
            if retryingID != nil { finishRetry(restoring: true) }
            dismissControllerMessage()

        case .marking(let ranges):
            append(.notice(AIActionController.markedMessage(ranges.count)))

        case .idle:
            isWorking = false
            awaitingID = nil
            if retryingID != nil {
                // Leaving the old version for the retry's request: nothing to do yet; a cancelled
                // retry (no request running any more) brings the version back.
                if case .running = controller?.state { finishRetry(restoring: true) }
                return
            }
            if rejectingID != nil {
                removeRejected()
                return
            }
            for message in messages where message.suggestion?.isPending == true {
                markNotPending(message.id)
            }
        }
    }

    /// A reply (or notice) arrived for the awaited request.
    private func append(_ content: Content) {
        messages.append(Message(id: UUID(), content: content))
        awaitingID = nil
        isWorking = false
    }

    /// The controller's message or answer is now a bubble: the controller goes back to idle, AFTER
    /// the assignment being observed has landed.
    private func dismissControllerMessage() {
        Task { @MainActor [weak controller] in controller?.dismissMessage() }
    }

    private func finishRetry(restoring: Bool) {
        guard let id = retryingID else { return }
        retryingID = nil
        retryRequestStarted = false
        update(id) { $0.isRetrying = false }
        guard restoring, let suggestion = messages.first(where: { $0.id == id })?.suggestion else { return }
        let version = suggestion.current
        Task { @MainActor [weak self] in
            guard let self, let controller = self.controller else { return }
            self.isChangingReviewLocally = true
            let restored = controller.restoreReview(version)
            self.isChangingReviewLocally = false
            if !restored { self.markNotPending(id) }
        }
    }

    private func removeRejected() {
        guard let id = rejectingID, let position = messages.firstIndex(where: { $0.id == id }) else {
            rejectingID = nil
            return
        }
        rejectingID = nil
        var gone: Set<UUID> = [id]
        // The request it answered, when it is the writer's bubble right above it.
        if position > 0, messages[position - 1].isWriter { gone.insert(messages[position - 1].id) }
        messages.removeAll { gone.contains($0.id) }
    }

    private func markNotPending(_ id: UUID) {
        update(id) { suggestion in
            suggestion.isPending = false
            suggestion.isRetrying = false
        }
    }

    private func update(_ id: UUID, _ change: (inout Suggestion) -> Void) {
        guard let position = messages.firstIndex(where: { $0.id == id }),
              var suggestion = messages[position].suggestion else { return }
        change(&suggestion)
        messages[position].content = .suggestion(suggestion)
    }

    private func refreshMatches() {
        let found = AIPromptLexicon.matches(in: draft, words: words)
        if found != matches { matches = found }
        let present = Set(found.map(\.wordID))
        let kept = choices.filter { present.contains($0.key) }
        if kept.count != choices.count { choices = kept }
        if case .word(let word) = card, !present.contains(word.id) { card = nil }
    }
}
