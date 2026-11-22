import LineformCore
import SwiftUI
import UIKit

/// The Read view for SwiftUI: wraps `LineformReadView`. Every update hands it the current text,
/// profile and document folder (`apply` renders only when one of them changed), and re-binds the
/// callbacks so they reach the current document.
///
/// A checkbox tap reports the range together with the source the view rendered, so the document
/// can refuse a toggle whose render is stale (`OpenDocument.toggleCheckbox(at:renderedFrom:)`).
struct ReadViewRepresentable: UIViewRepresentable {
    var text: String
    var profile: ReadingProfile
    /// The open document's folder, for relative image paths; nil for a document never saved.
    var documentDirectory: URL?
    /// A rendered checkbox was tapped: its `[ ]`/`[x]` source range, and the source text the view
    /// rendered it from.
    var onCheckboxToggle: (NSRange, String?) -> Void = { _, _ in }
    /// A Reconnect pill was tapped: the image line's source range.
    var onImageReconnect: (NSRange) -> Void = { _ in }
    /// The source offset at the top of the page, 0.08 s after scrolling stops.
    var onVisibleTopSourceLocationChanged: ((Int) -> Void)?
    /// The document's undo manager, so undo in Read undoes a toggle or a Reconnect.
    var undoManager: UndoManager?
    /// Told which view is the Read view, for the mode switch's position restore.
    var positionKeeper: ModePositionKeeper?
    /// Extra room above the first line for the floating mode control (Read; not Preview's lower pane).
    var topChromeInset: CGFloat = 0
    /// Preview's linked scrolling; nil in Read.
    var linkedScroll: LinkedScroll?
    /// How long after an edit the text is rendered (Preview's 0.12 s; Read renders at once).
    var textDelay: TimeInterval = 0

    func makeUIView(context: Context) -> LineformReadView {
        let view = LineformReadView.make(profile: profile)
        configure(view)
        return view
    }

    func updateUIView(_ view: LineformReadView, context: Context) {
        configure(view)
    }

    /// Hands `view` this value's inputs and callbacks. Internal so tests wire a view the same way.
    func configure(_ view: LineformReadView) {
        let toggle = onCheckboxToggle
        view.onCheckboxToggle = { [weak view] range in toggle(range, view?.renderedSourceText) }
        view.onImageReconnect = onImageReconnect
        view.onVisibleTopSourceLocationChanged = onVisibleTopSourceLocationChanged
        view.documentUndoManager = undoManager
        view.setTopChromeInset(topChromeInset)
        positionKeeper?.reader = view
        if let linkedScroll {
            linkedScroll.connect(preview: view)
            view.onScroll = { [weak linkedScroll] in linkedScroll?.previewDidScroll($0) }
        } else {
            view.onScroll = nil
        }
        view.apply(text: text, profile: profile, documentDirectory: documentDirectory, textDelay: textDelay)
    }
}
