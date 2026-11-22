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
        view.apply(text: text, profile: profile, documentDirectory: documentDirectory)
    }
}
