import Foundation
import UIKit

/// Where Save As stages the copy the export picker places: `tmp/SaveAs/<UUID>/<file name>`. The
/// whole folder is deleted when the picker closes and at launch, for a copy a picker still held
/// when iOS ended the app.
enum SaveAsStaging {
    static var defaultFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SaveAs", isDirectory: true)
    }

    static func removeAll(in folder: URL = defaultFolder) {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Save As on iPhone: the system export picker (`UIDocumentPickerViewController(forExporting:
/// asCopy: true)`) over a staged copy of the document (`OpenDocument.prepareSaveAs`), then the
/// document moves to the file the picker made (`OpenDocument.adoptSaveAs`). The picker's own
/// "Replace?" covers an existing file there. Cancel changes nothing.
///
/// It is presented with UIKit over the top-most presented controller (the Menu sheet), like
/// `ActivityShareSheet`, so its dismissal never takes the Menu sheet with it.
@MainActor
final class SaveAsPicker: NSObject, UIDocumentPickerDelegate {
    /// Called once: with the new file's URL, or nil for a cancel (or a picker UIKit refused).
    private let onFinish: (URL?) -> Void
    private let copyURL: URL
    /// The picker holds its delegate weakly: this keeps the delegate alive until it finishes.
    private var keepsSelfAlive: SaveAsPicker?

    init(copyURL: URL, onFinish: @escaping (URL?) -> Void) {
        self.copyURL = copyURL
        self.onFinish = onFinish
    }

    func makeController() -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [copyURL], asCopy: true)
        controller.delegate = self
        return controller
    }

    /// Presents the picker over whatever is on top of the key window; when UIKit would refuse
    /// (no window, or the top controller is mid-transition) it finishes at once as a cancel.
    func present() {
        guard let presenter = ActivityShareSheet.topPresenter(), ActivityShareSheet.canPresent(on: presenter) else {
            finish(nil)
            return
        }
        keepsSelfAlive = self
        presenter.present(makeController(), animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(nil)
    }

    /// Delivers the result once and lets go of the delegate.
    func finish(_ url: URL?) {
        guard !didFinish else { return }
        didFinish = true
        keepsSelfAlive = nil
        onFinish(url)
    }

    private var didFinish = false
}
