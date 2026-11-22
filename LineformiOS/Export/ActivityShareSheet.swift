import UIKit

/// The system share sheet for one file: an export copy, or the document's own file. Its "Save to
/// Files" is where an export is saved. `onComplete` runs once the sheet is done, whether the file
/// was shared, saved or not, so an export copy can be deleted then.
///
/// It is presented with UIKit over the top-most presented controller (the Menu sheet), not as
/// the content of a SwiftUI `.sheet`: hosted that way, the activity controller's own dismissal
/// after an action took the Menu sheet down with it, and the share sheet vanished at once.
@MainActor
struct ActivityShareSheet {
    var fileURL: URL
    var onComplete: () -> Void

    /// What the sheet hands on: the file itself, never its contents, so the receiving app gets
    /// the file's name and type.
    var activityItems: [Any] { [fileURL] }

    func makeController() -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        let onComplete = onComplete
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    /// Presents the sheet over whatever is on top of the key window. Without a window (a test
    /// host with no scene) nothing is shown and `onComplete` runs at once, so a copy never lingers.
    func present() {
        guard let presenter = Self.topPresenter() else {
            onComplete()
            return
        }
        let controller = makeController()
        // iPad-safe anchor; the iPhone presents it as a sheet and ignores this.
        controller.popoverPresentationController?.sourceView = presenter.view
        presenter.present(controller, animated: true)
    }

    private static func topPresenter() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
