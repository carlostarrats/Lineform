import LineformCore
import UIKit

/// Keeps the reading position across a Write / Read / Preview switch, the Mac's
/// `onChange(of: displayMode)` rule (`EditorContainerView.swift`): the source location at the top
/// of the surface being left is recorded at the switch, and one runloop tick later, once the new
/// surface is made and sized, and only if the switch is still the current one, the new surface
/// scrolls it to the top. Write re-asserts it for a few ticks
/// (`LineformTextView.scrollCharacterRangeToTopPersistently`); Read waits for its render.
///
/// In Preview the editor is the writing surface and owns the position: entering Preview scrolls
/// the editor and, while the panes are linked, Preview follows it (`SplitScrollJumpPlan`).
///
/// It also moves the keyboard focus with the mode: Read takes first responder (so a shake or ⌘Z
/// reaches the document's undo for a checkbox or a Reconnect) and the editor gives it up. A burst
/// of switches that ends back in Write gives the editor its focus back when it had it at the
/// first switch, and a scene restored straight into Read gives Read the focus.
@MainActor
final class ModePositionKeeper {
    weak var editor: LineformTextView? {
        didSet { if editor !== oldValue { applyAwaitedRestore() } }
    }
    weak var reader: LineformReadView? {
        didSet {
            guard reader !== oldValue else { return }
            focusAdoptedReaderIfNeeded()
            applyAwaitedRestore()
        }
    }
    /// Whether Preview's panes are linked (`LinkedScroll.isLinked`); nil reads as linked.
    var isPreviewLinked: () -> Bool = { true }

    /// The mode the last switch went to.
    private(set) var currentMode: EditorDisplayMode = .write
    /// A target recorded by a switch whose restore has not run yet. A second switch in the same
    /// tick keeps it: the surface it would read from has not been laid out yet.
    private(set) var pendingTarget: Int?
    private var generation = 0
    /// A restore whose tick came before SwiftUI made the new surface; it runs when the surface
    /// registers (`editor`, `reader`), if its switch is still the current one.
    private var awaitedRestore: (target: Int?, mode: EditorDisplayMode, generation: Int)?
    /// Whether the editor had the focus at the first switch of the burst being restored.
    private var editorHadFocus = false
    /// Set from a burst's first switch until its tick runs.
    private var isInBurst = false
    /// Read was adopted (a restored scene) and has not taken the focus yet.
    private var readerAwaitsAdoptedFocus = false

    /// The mode shown when the screen appears (a restored scene, a test); no restore. Read takes
    /// the focus, now or once its view registers, so a shake undoes there.
    func adopt(_ mode: EditorDisplayMode) {
        currentMode = mode
        readerAwaitsAdoptedFocus = mode == .read
        focusAdoptedReaderIfNeeded()
    }

    private func focusAdoptedReaderIfNeeded() {
        guard readerAwaitsAdoptedFocus, currentMode == .read, let reader else { return }
        readerAwaitsAdoptedFocus = false
        reader.takeFocusWhenInWindow()
    }

    /// The source location at the top of the surface the reader is looking at in `mode`.
    func topSourceLocation(in mode: EditorDisplayMode) -> Int? {
        switch mode {
        case .write, .split:
            editor?.topVisibleSourceLocation()
        case .read:
            reader?.sourceLocationAtTopOfViewport()
        }
    }

    /// Call as the mode changes from `old` to `new`, before the views update.
    func switchMode(from old: EditorDisplayMode, to new: EditorDisplayMode) {
        guard old != new else { return }
        if !isInBurst {
            // The first switch of a burst (switches inside one tick): remember who had the focus.
            isInBurst = true
            editorHadFocus = editor?.isFirstResponder ?? false
        }
        readerAwaitsAdoptedFocus = false
        // Read's focus request is Read's alone: leaving it drops one still waiting for a window.
        if new != .read { reader?.cancelPendingFocus() }
        let target = pendingTarget ?? topSourceLocation(in: old)
        pendingTarget = target
        currentMode = new
        generation += 1
        let switchGeneration = generation
        if new == .read { editor?.resignFirstResponder() }
        awaitedRestore = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, switchGeneration == self.generation, self.currentMode == new else { return }
            self.isInBurst = false
            self.pendingTarget = nil
            self.awaitedRestore = (target, new, switchGeneration)
            self.applyAwaitedRestore()
        }
    }

    /// Runs the awaited restore once every surface `mode` shows is there.
    private func applyAwaitedRestore() {
        guard let awaited = awaitedRestore else { return }
        guard awaited.generation == generation, awaited.mode == currentMode else {
            awaitedRestore = nil
            return
        }
        switch awaited.mode {
        case .write: guard editor != nil else { return }
        case .read: guard reader != nil else { return }
        case .split: guard editor != nil, reader != nil else { return }
        }
        awaitedRestore = nil
        if awaited.mode == .read { reader?.takeFocusWhenInWindow() }
        if awaited.mode == .write, editorHadFocus, let editor, !editor.isFirstResponder {
            editor.becomeFirstResponder()
        }
        editorHadFocus = false
        if let target = awaited.target { restore(target, in: awaited.mode) }
    }

    /// Scrolls the surfaces of `mode` so `location` is at the top.
    func restore(_ location: Int, in mode: EditorDisplayMode) {
        let range = NSRange(location: max(0, location), length: 0)
        switch mode {
        case .write:
            editor?.scrollCharacterRangeToTopPersistently(range)
        case .read:
            reader?.scrollSourceLocationToTop(range.location)
        case .split:
            let plan = SplitScrollJumpPlan(range: range, isLinked: isPreviewLinked())
            editor?.scrollCharacterRangeToTopPersistently(plan.editorRange)
            if let preview = plan.previewRange {
                reader?.scrollSourceLocationToTop(preview.location)
            }
        }
    }
}
