import Foundation

/// Classification of an image reference found in a Markdown document.
enum ImageReferenceKind: Equatable {
    case localFile(URL)
    case remote
    case unresolved
}

/// Classifies an image path from the document into local-file / remote / unresolved.
/// Never touches the network — remote detection is a pure string test, and local
/// resolution only checks the filesystem for existence + a restricted image UTI.
enum ImageResolver {
    /// Explicit allow-list of common raster image extensions. Used as the primary gate
    /// so classification is deterministic in tests regardless of the host's UTI database.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "svg"
    ]

    static func resolve(path: String, documentDirectory: URL?) -> ImageReferenceKind {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unresolved }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") || lowercased.hasPrefix("data:") {
            return .remote
        }

        // The LITERAL path first, then its percent-decoded form. Percent-encoded destinations are
        // ordinary Markdown — every other editor writes `%20` for a space, and Reconnect writes
        // `%28`/`%29` for a filename's parentheses — but they were compared against the
        // filesystem verbatim, so a document authored elsewhere drew a broken-image placeholder
        // for a file sitting right beside it. Literal stays first so a filename that genuinely
        // contains a `%` escape is never decoded out from under the writer.
        var candidates = [trimmed]
        if let decoded = trimmed.removingPercentEncoding, decoded != trimmed {
            candidates.append(decoded)
        }

        for path in candidates {
            guard let resolvedURL = fileURL(for: path, documentDirectory: documentDirectory) else { continue }
            guard isImageExtension(resolvedURL.pathExtension) else { continue }
            guard FileManager.default.fileExists(atPath: resolvedURL.path) else { continue }
            return .localFile(resolvedURL)
        }
        return .unresolved
    }

    private static func fileURL(for path: String, documentDirectory: URL?) -> URL? {
        let candidate: URL?
        if path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: path)
        } else if path.lowercased().hasPrefix("file://") {
            candidate = URL(string: path)?.standardizedFileURL ?? URL(fileURLWithPath: path)
        } else {
            guard let documentDirectory else { return nil }
            candidate = documentDirectory.appendingPathComponent(path)
        }
        return candidate?.standardizedFileURL
    }

    /// True when `path`'s extension is one of the recognized raster image extensions.
    /// Lets the export pre-flight tell "image reference we couldn't resolve" apart from
    /// "link to a non-image file" without duplicating the extension set.
    static func hasImageExtension(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (trimmed as NSString).pathExtension
        return isImageExtension(ext)
    }

    private static func isImageExtension(_ pathExtension: String) -> Bool {
        imageExtensions.contains(pathExtension.lowercased())
    }
}
