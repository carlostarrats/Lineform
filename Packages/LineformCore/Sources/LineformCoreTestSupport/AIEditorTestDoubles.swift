import Foundation
import LineformCore

/// The editor as the AI controller sees it. Applies edits the way the text view does: each edit
/// is reported (`onApplyEdit`, in pre-change coordinates, as `shouldChangeText` reports it to
/// History), then lands.
@MainActor
public final class FakeAIEditorSurface: AIEditorSurface {
    public var string: String
    /// Called with each edit before it lands. The Mac's History tests forward it to
    /// `DocumentHistoryController.noteUserEdit`.
    public var onApplyEdit: ((AIReviewEdit) -> Void)?
    public private(set) var editCalls: [(edits: [AIReviewEdit], actionName: String)] = []
    public private(set) var typed: [String] = []
    public private(set) var announcements: [String] = []
    /// Every `collapseSelectionForAI` location, in order.
    public private(set) var collapsedSelections: [Int] = []
    /// When set, edits whose index in a call is listed are skipped (as the text view skips an
    /// edit that would split a character or touch structure), and the call reports false.
    public var skippedEditIndices: Set<Int> = []

    public init(_ string: String) {
        self.string = string
    }

    @discardableResult
    public func applyAIEdits(_ edits: [AIReviewEdit], actionName: String) -> Bool {
        editCalls.append((edits, actionName))
        let text = NSMutableString(string: string)
        var appliedAll = true
        for (index, edit) in edits.enumerated() {
            guard !skippedEditIndices.contains(index) else {
                appliedAll = false
                continue
            }
            onApplyEdit?(edit)
            text.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        string = text as String
        return appliedAll
    }

    public func collapseSelectionForAI(at location: Int) {
        collapsedSelections.append(location)
    }

    public func insertTypedText(_ text: String) {
        typed.append(text)
    }

    public func announceAI(_ message: String) {
        announcements.append(message)
    }
}

/// History as the AI controller sees it, recording every call in order. `allowsAction` stands in
/// for History mode (false refuses an action); `widen` for growing a range over a partly
/// covered passage.
@MainActor
public final class FakeAIHistoryRecorder: AIHistoryRecording {
    public enum Call: Equatable {
        case actionRange(NSRange)
        case actionWillStart
        case actionDidEnd(recorded: UUID?, changedRange: NSRange?, text: String)
        case actionAbandoned
        case acceptWillApply
        case acceptDidApply
        case recordAccepted(range: NSRange, original: String, accepted: String)
        case acceptRecordingDidFinish
    }

    public var allowsAction = true
    public var widen: (NSRange) -> NSRange = { $0 }
    /// Every call except `allowsAIAction` (asked whenever availability is checked).
    public private(set) var calls: [Call] = []
    /// The ids `recordAccepted` handed out, in order.
    public private(set) var recordedIDs: [UUID] = []

    public init() {}

    public func allowsAIAction(on range: NSRange) -> Bool { allowsAction }

    public func aiActionRange(for range: NSRange) -> NSRange {
        calls.append(.actionRange(range))
        return widen(range)
    }

    public func aiActionWillStart() { calls.append(.actionWillStart) }

    public func aiActionDidEnd(recorded: UUID?, changedRange: NSRange?, text: String) {
        calls.append(.actionDidEnd(recorded: recorded, changedRange: changedRange, text: text))
    }

    public func aiActionAbandoned() { calls.append(.actionAbandoned) }
    public func aiAcceptWillApply() { calls.append(.acceptWillApply) }
    public func aiAcceptDidApply() { calls.append(.acceptDidApply) }

    @discardableResult
    public func recordAccepted(range: NSRange, original: String, accepted: String, text: String) -> UUID? {
        calls.append(.recordAccepted(range: range, original: original, accepted: accepted))
        let id = UUID()
        recordedIDs.append(id)
        return id
    }

    public func aiAcceptRecordingDidFinish() { calls.append(.acceptRecordingDidFinish) }
}
