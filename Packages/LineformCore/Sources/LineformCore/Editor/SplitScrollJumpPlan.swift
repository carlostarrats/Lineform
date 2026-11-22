import Foundation

/// Which panes a jump (an outline click, a mode-switch restore) moves in a split of source and
/// rendered text. Moved from the Mac app's `EditorContainerView.swift` so the iPhone's top/bottom
/// Preview plans its jumps the same way.
public struct SplitScrollJumpPlan: Equatable, Sendable {
    public let editorRange: NSRange
    public let previewRange: NSRange?

    public init(range: NSRange, isLinked: Bool) {
        editorRange = range
        // While linked, Write owns the jump and Preview follows its physical Y. Issuing a second,
        // source-mapped Preview jump would move Write back again through the link; the two fresh
        // representables would fight until the editor's deferred restore happened to win.
        previewRange = isLinked ? nil : range
    }
}
