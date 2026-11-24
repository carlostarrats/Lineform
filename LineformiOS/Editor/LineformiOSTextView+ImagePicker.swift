import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// The selection row's Image button: a picture from Photos or Files, without pasting.
///
/// Both pickers hand their result to the EXISTING paste path (`insertImages(from:at:)` in
/// `LineformiOSTextView+ImagePaste.swift`), so a picked image is exactly a pasted one: PNG through
/// `UIImage.pngData()`, a coordinated never-overwriting write into `images/` beside the document,
/// named by `ImageFileNaming`, its link on its own line (`ImageInsertionText`), an unsaved document
/// saved first, nothing written outside the document's folder or the save folder, the short notice
/// when it cannot be saved, and one undo step.
///
/// - Photos is `PHPickerViewController`: it runs out of process, so the app never asks for
///   photo-library access.
/// - Files is `UIDocumentPickerViewController` for images, as copies (nothing is kept open).
extension LineformTextView {
    enum ImagePickerSource: Equatable {
        case photos, files
    }

    /// Presents the picker for `source` from the editor's window.
    func presentImagePicker(_ source: ImagePickerSource) {
        guard isEditable, !refusesEditForAI(), let presenter = window?.rootViewController?.topmostPresented else { return }
        let coordinator = ImagePickerCoordinator(editor: self)
        state.imagePickerCoordinator = coordinator
        let picker: UIViewController
        switch source {
        case .photos:
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = 1
            let photos = PHPickerViewController(configuration: configuration)
            photos.delegate = coordinator
            picker = photos
        case .files:
            let files = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
            files.allowsMultipleSelection = false
            files.delegate = coordinator
            picker = files
        }
        presenter.present(picker, animated: true)
    }

    /// The picked images, through the paste path. The caret (or the selection's start) is where
    /// the link goes, as for a paste.
    func insertPickedImages(_ providers: [NSItemProvider]) {
        state.imagePickerCoordinator = nil
        guard !providers.isEmpty else { return }
        insertImages(from: providers, at: nil)
    }
}

/// The pickers' delegate, held by the editor's `State` while a picker is up.
@MainActor
final class ImagePickerCoordinator: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    private weak var editor: LineformTextView?

    init(editor: LineformTextView) {
        self.editor = editor
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        editor?.insertPickedImages(results.map(\.itemProvider))
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let providers = urls.compactMap { url -> NSItemProvider? in
            guard let provider = NSItemProvider(contentsOf: url) else { return nil }
            provider.suggestedName = url.deletingPathExtension().lastPathComponent
            return provider
        }
        editor?.insertPickedImages(providers)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        editor?.insertPickedImages([])
    }
}

private extension UIViewController {
    /// The controller on top of everything this one presents.
    var topmostPresented: UIViewController {
        presentedViewController?.topmostPresented ?? self
    }
}
