import UIKit

/// Preview's linked scrolling, the Mac's `SplitScrollSynchronizer`
/// (`Lineform/Editor/LineformTextView.swift`): a scroll of one pane sets the other pane's vertical
/// offset directly, in the same turn, with no source lookup, block mapping, proportion or
/// animation (`docs/architecture/editor-behavior.md` says why).
///
/// - **Physical Y.** The distance scrolled from the top of the source pane (its `contentOffset.y`
///   past its top inset) is copied to the other pane, clamped to that pane's range
///   `0 … contentSize.height − bounds.height + insets`. At the end of the shorter pane the copy
///   stays at its end, and never jumps back.
/// - **No echo.** Setting the other pane's offset makes it report a scroll; `isApplying` drops it.
/// - **Replaced panes.** Each pane is held weakly and matched by identity: a scroll from a view
///   that is no longer the connected one (a pane SwiftUI replaced) is ignored.
/// - **Linked by default.** Unlinked, the panes scroll on their own; re-linking brings Preview to
///   the editor (`alignPreviewToEditor`), the writing surface.
@MainActor
final class LinkedScroll {
    private(set) weak var editor: UIScrollView?
    private(set) weak var preview: UIScrollView?
    var isLinked = true
    private var isApplying = false

    func connect(editor: UIScrollView) {
        self.editor = editor
    }

    func connect(preview: UIScrollView) {
        self.preview = preview
    }

    func editorDidScroll(_ source: UIScrollView) {
        guard source === editor else { return }
        synchronize(from: source, to: preview)
    }

    func previewDidScroll(_ source: UIScrollView) {
        guard source === preview else { return }
        synchronize(from: source, to: editor)
    }

    /// Brings Preview to the editor's offset, linked or not (re-linking).
    func alignPreviewToEditor() {
        synchronize(from: editor, to: preview, requiresLink: false)
    }

    /// The link button: toggles the link, and a re-link aligns Preview to the editor.
    func toggleLink() {
        isLinked.toggle()
        if isLinked { alignPreviewToEditor() }
    }

    private func synchronize(from source: UIScrollView?, to destination: UIScrollView?, requiresLink: Bool = true) {
        guard !requiresLink || isLinked, !isApplying, let source, let destination else { return }
        let y = Self.linkedOffsetY(from: source, to: destination)
        guard abs(destination.contentOffset.y - y) > 0.001 else { return }
        isApplying = true
        defer { isApplying = false }
        destination.contentOffset = CGPoint(x: destination.contentOffset.x, y: y)
    }

    /// `destination`'s offset for `source`'s: the same distance from the top, clamped to the
    /// destination's scrollable range.
    static func linkedOffsetY(from source: UIScrollView, to destination: UIScrollView) -> CGFloat {
        let distance = source.contentOffset.y + source.adjustedContentInset.top
        let insets = destination.adjustedContentInset
        let maximumDistance = max(0, destination.contentSize.height + insets.top + insets.bottom - destination.bounds.height)
        return min(max(0, distance), maximumDistance) - insets.top
    }
}
