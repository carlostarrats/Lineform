import AppKit

/// Drag-and-drop and paste of an image into the Write-mode editor. On drop/paste of an image file
/// (or raw PNG/TIFF data), the image is written next to the document (in an `images/` subfolder,
/// yielding a portable relative link) — falling back to the app's own container with an absolute
/// link when there is no document folder or it isn't writable — and a Markdown `![](path)` link is
/// inserted **on its own line** so it renders as a block image in Read/Preview.
extension LineformTextView {

    // MARK: - Drag

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedImageIsAvailable(sender.draggingPasteboard) else {
            return super.draggingEntered(sender)
        }
        updateDropIndicator(at: convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedImageIsAvailable(sender.draggingPasteboard) else {
            return super.draggingUpdated(sender)
        }
        updateDropIndicator(at: convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropIndicator()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideDropIndicator()
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDropIndicator()
        let pasteboard = sender.draggingPasteboard
        guard draggedImageIsAvailable(pasteboard) else {
            return super.performDragOperation(sender)
        }
        let point = convert(sender.draggingLocation, from: nil)
        let dropIndex = characterIndexForInsertion(at: point)
        return insertImage(from: pasteboard, at: dropIndex)
    }

    // MARK: - Drop indicator

    /// Position and show the horizontal drop rule at the top of the line the image would land on.
    private func updateDropIndicator(at point: NSPoint) {
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let length = (string as NSString).length
        let indicatorY: CGFloat
        if layoutManager.numberOfGlyphs == 0 {
            indicatorY = origin.y
        } else {
            let index = min(max(0, characterIndexForInsertion(at: point)), length)
            let glyphIndex = min(layoutManager.glyphIndexForCharacter(at: index), layoutManager.numberOfGlyphs - 1)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            indicatorY = lineRect.minY + origin.y
        }
        imageDropIndicatorLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        imageDropIndicatorLine.frame = NSRect(x: origin.x, y: indicatorY - 1, width: max(0, textContainer.size.width), height: 2)
        imageDropIndicatorLine.isHidden = false
    }

    private func hideDropIndicator() {
        imageDropIndicatorLine.isHidden = true
    }

    // MARK: - Paste

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        // Only hijack paste when there's an image AND no plain text — so pasting normal text/code
        // that merely also carries an image representation still pastes the text.
        if pasteboard.data(forType: .string) == nil,
           draggedImageIsAvailable(pasteboard),
           insertImage(from: pasteboard, at: selectedRange().location) {
            return
        }
        super.paste(sender)
    }

    // MARK: - Detection

    private func draggedImageIsAvailable(_ pasteboard: NSPasteboard) -> Bool {
        imageFileURL(from: pasteboard) != nil || imageData(from: pasteboard) != nil
    }

    private func imageFileURL(from pasteboard: NSPasteboard) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] else {
            return nil
        }
        return urls.first { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Raw image data on the pasteboard, normalized to PNG when possible (TIFF is re-encoded so the
    /// written file is small and universally openable).
    private func imageData(from pasteboard: NSPasteboard) -> (data: Data, ext: String)? {
        if let png = pasteboard.data(forType: .png) { return (png, "png") }
        if let tiff = pasteboard.data(forType: .tiff) {
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                return (png, "png")
            }
            return (tiff, "tiff")
        }
        return nil
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "svg"
    ]

    // MARK: - Write + insert

    private func insertImage(from pasteboard: NSPasteboard, at index: Int) -> Bool {
        if let source = imageFileURL(from: pasteboard) {
            let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
            let base = source.deletingPathExtension().lastPathComponent
            guard let dest = destination(preferredName: base, ext: ext) else { return false }
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            do {
                if FileManager.default.fileExists(atPath: dest.url.path) {
                    try FileManager.default.removeItem(at: dest.url)
                }
                try FileManager.default.copyItem(at: source, to: dest.url)
            } catch {
                return false
            }
            insertImageLink(path: dest.link, at: index)
            return true
        }
        if let payload = imageData(from: pasteboard) {
            guard let dest = destination(preferredName: "image", ext: payload.ext) else { return false }
            do { try payload.data.write(to: dest.url) } catch { return false }
            insertImageLink(path: dest.link, at: index)
            return true
        }
        return false
    }

    /// Where to write the image and the link text to insert. Prefers `images/<name>` next to the
    /// document (relative, portable); falls back to the app container with an absolute path when
    /// there is no document folder or it can't be written to.
    private func destination(preferredName: String, ext: String) -> (url: URL, link: String)? {
        let fileManager = FileManager.default

        if let directory = imageInsertionDocumentDirectory {
            let imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
            if (try? fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)) != nil,
               fileManager.isWritableFile(atPath: imagesDirectory.path) {
                let name = uniqueName(in: imagesDirectory, base: preferredName, ext: ext)
                return (imagesDirectory.appendingPathComponent(name), "images/\(name)")
            }
        }

        if let support = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let directory = support.appendingPathComponent("Lineform/InsertedImages", isDirectory: true)
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = uniqueName(in: directory, base: preferredName, ext: ext)
            let url = directory.appendingPathComponent(name)
            return (url, url.path)
        }
        return nil
    }

    private func uniqueName(in directory: URL, base: String, ext: String) -> String {
        let fileManager = FileManager.default
        let safeBase = Self.sanitizedFileBase(base)
        var candidate = "\(safeBase).\(ext)"
        var counter = 1
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            counter += 1
            candidate = "\(safeBase)-\(counter).\(ext)"
        }
        return candidate
    }

    /// Reduce a filename base to clean ASCII: letters, digits, `.`, `-`, `_` only; every run of any
    /// other character (spaces, incl. the U+202F narrow no-break space macOS puts in screenshot
    /// names, punctuation, unicode) collapses to a single `-`. Keeps written image filenames tidy
    /// and — critically — free of characters that can break the `![](path)` link's resolution after
    /// a save/reload round-trip through the `.md`.
    static func sanitizedFileBase(_ base: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        var result = ""
        var lastWasDash = false
        for character in base {
            if allowed.contains(character) {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "image" : trimmed
    }

    /// Insert `![](path)` on its OWN line. The drop index is snapped to the START of the line it
    /// falls on (a paragraph boundary) so the image lands BETWEEN whole lines and never splits a
    /// word or sentence — matching the drop indicator, which is drawn at that same line's top edge.
    /// Goes through `insertText(_:replacementRange:)` so undo + the document binding sync normally.
    private func insertImageLink(path: String, at index: Int) {
        let text = string as NSString
        let clamped = max(0, min(index, text.length))
        // Snap to the beginning of the drop line. Inserting `![](path)\n` here places the image as
        // its own line and pushes the existing line down; no leading newline is needed because we're
        // already at a line boundary.
        let lineStart = text.lineRange(for: NSRange(location: clamped, length: 0)).location
        // Insert the image as its own line at the drop line's start. The renderer gives the image
        // block symmetric spacing, so no blank-line wrapping is needed here.
        let snippet = "![](\(path))\n"
        let range = NSRange(location: lineStart, length: 0)
        // Use the shouldChangeText → mutate textStorage → didChangeText path (the same one the
        // formatting commands use). A bare `insertText` during a drag session does not reliably
        // sync back to the SwiftUI document binding, so the inserted link was being lost.
        guard shouldChangeText(in: range, replacementString: snippet) else { return }
        textStorage?.replaceCharacters(in: range, with: snippet)
        didChangeText()
        setSelectedRange(NSRange(location: lineStart + (snippet as NSString).length, length: 0))
    }
}
