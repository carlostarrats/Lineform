import LineformCore
import UIKit
import UniformTypeIdentifiers

/// The document an inserted image is saved beside. `OpenDocument` is the real one.
@MainActor
protocol ImageInsertionHost: AnyObject {
    /// The folder whose `images/` subfolder receives the image: the document's own folder. A
    /// document that was never saved is saved first, through the normal autosave rules, so its
    /// file and `images/` sit side by side. Nil when that save failed (the save-failed notice is
    /// then showing); nothing must be inserted.
    func folderForInsertedImage() async -> URL?
    /// An image link went into the text (and through the binding). Saves at once, so a document
    /// that had nothing to be named from until now gets its file next to `images/`.
    func imageLinkInserted() async
    /// Which document is open. An image captures it when the paste or drop starts and is only
    /// inserted if it is unchanged by the time the image is ready.
    var imageInsertionDocumentIdentity: Int { get }
    /// The image could not be written into `images/` beside the document; nothing was inserted.
    /// Shows a short, non-modal notice.
    func imageCouldNotBeSaved()
}

/// Paste and drop of an image into the iPhone editor, the iPhone side of the Mac's
/// `LineformTextView+ImageInsertion.swift`:
///
/// - The image is written as PNG (`UIImage.pngData()`) with a coordinated write to
///   `<document folder>/images/<name>.png`, named and uniqued by `ImageFileNaming` (the Mac's
///   names), and never anywhere else: the folder is the document's own, or the save folder for a
///   document that is created by this paste.
/// - The link (`ImageLinkRewrite.markdownDestination`) goes in on its own line at the start of the
///   caret's line (`ImageInsertionText.insertingOnLine`), as one localized edit with one undo step.
/// - Pasting a string never takes the image path: while the pasteboard has strings, `paste(_:)`
///   runs the normal text paste, as on the Mac. `paste(itemProviders:)` (UIKit's paste and drop)
///   decides from its providers alone: a drop has no pasteboard, so a string that happens to be on
///   the general pasteboard never turns an image drop into a text paste.
/// - When the image cannot be written beside the document (its folder is not writable), nothing is
///   inserted and the host shows a short notice. There is no fallback folder: a link to an absolute
///   path in the app's container would not travel with the document.
/// - An image only lands in the document that was open when its paste or drop started.
/// - Paste goes through `pasteConfiguration` and `paste(itemProviders:)` (and `paste(_:)`, which
///   the edit menu and ⌘V call); drop goes through a `UIDropInteraction` that only takes sessions
///   with an image and no text, so a text drag keeps the system's text drop.
extension LineformTextView: UIDropInteractionDelegate {
    /// The base name of an image that arrives without one (a screenshot on the pasteboard), the
    /// Mac's name for raw image data.
    static let pastedImageBaseName = "image"

    func configureImagePasteAndDrop() {
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier])
        let drop = UIDropInteraction(delegate: self)
        addInteraction(drop)
        state.imageDropInteraction = drop
    }

    /// The pasteboard paste reads. Tests substitute their own, so they never touch the user's.
    var activePasteboard: UIPasteboard {
        #if DEBUG
        state.pasteboardForTesting ?? .general
        #else
        .general
        #endif
    }

    #if DEBUG
    var pasteboardForTesting: UIPasteboard? {
        get { state.pasteboardForTesting }
        set { state.pasteboardForTesting = newValue }
    }
    #endif

    /// True when a paste from `pasteboard` should insert an image: it has one, and no string.
    static func pastesImage(from pasteboard: UIPasteboard) -> Bool {
        !pasteboard.hasStrings && pasteboard.hasImages
    }

    // MARK: - Paste

    /// `paste:` is enabled for an image-only pasteboard, which UITextView would otherwise refuse
    /// (it pastes images only when it edits attributed text). Nil defers to the text view.
    func canPerformImagePaste(_ action: Selector) -> Bool? {
        guard action == #selector(paste(_:)), isEditable, Self.pastesImage(from: activePasteboard) else { return nil }
        return true
    }

    override func paste(_ sender: Any?) {
        let pasteboard = activePasteboard
        guard Self.pastesImage(from: pasteboard) else {
            super.paste(sender)
            return
        }
        insertImages(from: Self.imageProviders(from: pasteboard), at: nil)
    }

    /// One in-memory provider per pasteboard item that holds an image, carrying that image's
    /// bytes. Read at once, while the paste is happening: the pasteboard's own lazy providers
    /// can fail to load later.
    static func imageProviders(from pasteboard: UIPasteboard) -> [NSItemProvider] {
        pasteboard.items.compactMap { item -> NSItemProvider? in
            for (type, value) in item where UTType(type)?.conforms(to: .image) == true {
                if let data = value as? Data {
                    return NSItemProvider(item: data as NSData, typeIdentifier: type)
                }
                if let image = value as? UIImage, let data = image.pngData() {
                    return NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
                }
            }
            return nil
        }
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        if isEditable, itemProviders.contains(where: Self.providesImage) { return true }
        return super.canPaste(itemProviders)
    }

    /// Decided from the providers alone, never from a pasteboard: a drop through
    /// `pasteConfiguration` arrives here too, and has none.
    override func paste(itemProviders: [NSItemProvider]) {
        guard !itemProviders.contains(where: Self.providesText),
              itemProviders.contains(where: Self.providesImage)
        else {
            super.paste(itemProviders: itemProviders)
            return
        }
        insertImages(from: itemProviders, at: nil)
    }

    // MARK: - Drop

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: any UIDropSession) -> Bool {
        isEditable
            && session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier])
            && !session.hasItemsConforming(toTypeIdentifiers: [UTType.text.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: any UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: any UIDropSession) {
        let point = session.location(in: self)
        let index = closestPosition(to: point).map { offset(from: beginningOfDocument, to: $0) }
        insertImages(from: session.items.map(\.itemProvider), at: index ?? selectedRange.location)
    }

    // MARK: - Insert

    /// Starts inserting every image in `providers`, in order, at `index` (nil: the caret when each
    /// one is ready). Every provider starts loading now, synchronously (a drop session's providers
    /// are only good during `performDrop`); only the inserts wait for each other. The open
    /// document is captured now, too. The work is `imagePasteTask`.
    func insertImages(from providers: [NSItemProvider], at index: Int?) {
        let loads = providers.filter(Self.providesImage).map { provider in
            (name: provider.suggestedName ?? Self.pastedImageBaseName, png: Self.beginLoadingPNG(from: provider))
        }
        guard !loads.isEmpty else { return }
        let documentIdentity = imageInsertionHost?.imageInsertionDocumentIdentity
        let previous = imagePasteTask
        imagePasteTask = Task { [weak self] in
            await previous?.value
            var nextIndex = index
            for load in loads {
                guard let png = await load.png.value else { continue }
                guard let self else { return }
                guard let caret = await self.insertImage(
                    png: png, preferredName: load.name, at: nextIndex, documentIdentity: documentIdentity
                ) else { return }
                if nextIndex != nil { nextIndex = caret }
            }
        }
    }

    /// Writes `png` into `images/` beside the document and inserts its link on its own line.
    /// Returns the caret after the link, or nil when nothing was inserted: no document, its first
    /// save failed, the file could not be written (the host shows its notice), or another
    /// document took this one's place since `documentIdentity` was taken (nil: now).
    @discardableResult
    func insertImage(png: Data, preferredName: String, at index: Int?, documentIdentity: Int? = nil) async -> Int? {
        guard isEditable, let host = imageInsertionHost else { return nil }
        let identity = documentIdentity ?? host.imageInsertionDocumentIdentity
        guard let folder = await host.folderForInsertedImage() else { return nil }
        guard let written = await Self.writeImage(png, imagesFolderNextTo: folder, preferredName: preferredName) else {
            // The folder (or its images/) is not writable. Nothing is inserted, and no copy is put
            // anywhere else.
            if host.imageInsertionDocumentIdentity == identity { host.imageCouldNotBeSaved() }
            return nil
        }
        guard host.imageInsertionDocumentIdentity == identity, isEditable else {
            // Another document is open now: the image belongs to neither.
            try? FileManager.default.removeItem(at: written.url)
            return nil
        }
        let text = textStorage.string
        let location = min(index ?? selectedRange.location, (text as NSString).length)
        let edit = ImageInsertionText.insertingOnLine(
            into: text, at: location, path: ImageLinkRewrite.markdownDestination(for: written.link)
        )
        guard applyRuleEdit(replacing: NSRange(location: edit.location, length: 0), with: edit.snippet) else {
            // Composing text (marked text) refuses the edit; leave no orphan file behind.
            try? FileManager.default.removeItem(at: written.url)
            return nil
        }
        await host.imageLinkInserted()
        return edit.caret
    }

    // MARK: - Reading and writing

    nonisolated static func providesImage(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    nonisolated static func providesText(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.text.identifier)
    }

    /// The provider's image, decoded and re-encoded as PNG with `UIImage.pngData()`, off the main
    /// thread.
    static func pngData(from provider: NSItemProvider) async -> Data? {
        await beginLoadingPNG(from: provider).value
    }

    /// Starts loading the provider's image now, synchronously, and returns the task that ends
    /// with it as PNG (decoded and re-encoded with `UIImage.pngData()`, off the main thread).
    static func beginLoadingPNG(from provider: NSItemProvider) -> Task<Data?, Never> {
        let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
            ?? UTType.image.identifier
        let (loaded, delivery) = AsyncStream<Data?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            delivery.yield(data)
            delivery.finish()
        }
        return Task.detached(priority: .userInitiated) {
            var data: Data?
            for await value in loaded {
                data = value
                break
            }
            guard let data else { return nil }
            return UIImage(data: data)?.pngData()
        }
    }

    /// Writes `data` to a new `images/<name>.png` in `folder`, with a coordinated write that never
    /// replaces a file: a name taken at the last moment is uniqued again. Off the main thread.
    /// Returns the file and its link text (`images/<name>.png`), or nil.
    nonisolated static func writeImage(
        _ data: Data,
        imagesFolderNextTo folder: URL,
        preferredName: String
    ) async -> (url: URL, link: String)? {
        let result: WrittenImage? = await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let imagesFolder = folder.appendingPathComponent("images", isDirectory: true).standardizedFileURL
            for _ in 0..<5 {
                guard let destination = ImageFileNaming.imagesFolderDestination(
                    nextTo: folder, preferredName: preferredName, ext: "png", fileManager: fileManager
                ) else { return nil }
                // Only ever inside the document's own `images/`.
                guard destination.url.deletingLastPathComponent().standardizedFileURL == imagesFolder else { return nil }
                var coordinationError: NSError?
                var writeError: Error?
                NSFileCoordinator(filePresenter: nil)
                    .coordinate(writingItemAt: destination.url, options: [], error: &coordinationError) { url in
                        do {
                            try data.write(to: url, options: .withoutOverwriting)
                        } catch {
                            writeError = error
                        }
                    }
                if let error = writeError as? CocoaError, error.code == .fileWriteFileExists { continue }
                guard coordinationError == nil, writeError == nil else { return nil }
                return WrittenImage(url: destination.url, link: destination.link)
            }
            return nil
        }.value
        return result.map { ($0.url, $0.link) }
    }
}

private struct WrittenImage: Sendable {
    let url: URL
    let link: String
}
