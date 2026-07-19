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

        let candidate: URL?
        if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
        } else if lowercased.hasPrefix("file://") {
            candidate = URL(string: trimmed)?.standardizedFileURL ?? URL(fileURLWithPath: trimmed)
        } else {
            guard let documentDirectory else { return .unresolved }
            candidate = documentDirectory.appendingPathComponent(trimmed)
        }

        guard let candidateURL = candidate else { return .unresolved }
        let resolvedURL = candidateURL.standardizedFileURL

        guard isImageExtension(resolvedURL.pathExtension) else { return .unresolved }
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else { return .unresolved }

        return .localFile(resolvedURL)
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
