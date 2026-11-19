import Foundation
@testable import Lineform
@testable import LineformCore

/// The editor as the AI controller sees it. Applies edits the way the text view does: each edit
/// is reported to History in pre-change coordinates (`shouldChangeText`), then lands.
@MainActor
final class FakeAIEditorSurface: AIEditorSurface {
    var string: String
    weak var history: DocumentHistoryController?
    private(set) var editCalls: [(edits: [AIReviewEdit], actionName: String)] = []
    private(set) var typed: [String] = []
    private(set) var announcements: [String] = []
    /// Every `collapseSelectionForAI` location, in order.
    private(set) var collapsedSelections: [Int] = []
    /// When set, edits whose index in a call is listed are skipped (as the text view skips an
    /// edit that would split a character or touch structure), and the call reports false.
    var skippedEditIndices: Set<Int> = []

    init(_ string: String) {
        self.string = string
    }

    @discardableResult
    func applyAIEdits(_ edits: [AIReviewEdit], actionName: String) -> Bool {
        editCalls.append((edits, actionName))
        let text = NSMutableString(string: string)
        var appliedAll = true
        for (index, edit) in edits.enumerated() {
            guard !skippedEditIndices.contains(index) else {
                appliedAll = false
                continue
            }
            history?.noteUserEdit(edit.range, replacement: edit.replacement)
            text.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        string = text as String
        return appliedAll
    }

    func collapseSelectionForAI(at location: Int) {
        collapsedSelections.append(location)
    }

    func insertTypedText(_ text: String) {
        typed.append(text)
    }

    func announceAI(_ message: String) {
        announcements.append(message)
    }
}
