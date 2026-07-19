import Foundation

/// One `![alt](path)` reference in a document that could not be resolved to a readable local
/// image file (either missing, or existing but outside every granted sandbox scope — the two are
/// indistinguishable under the sandbox, so both surface here).
struct UnresolvedImageReference: Equatable {
    let path: String
    let range: NSRange
}

/// Pure pre-flight scan for Styled PDF export / Print: finds local image references the app can't
/// currently read, so the caller can offer a single grant-access prompt. Never touches the
/// network; remote (`http(s)`/`data:`) references are ignored, and non-image link targets
/// (`![x](notes.txt)`) are ignored — only genuine image references that fail to resolve are
/// returned.
enum ImageExportPreflight {
    private static let imageRegex = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(([^\)\n]+)\)"#)

    static func unresolvedLocalReferences(in text: String, documentDirectory: URL?) -> [UnresolvedImageReference] {
        let ns = text as NSString
        let matches = imageRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result: [UnresolvedImageReference] = []
        for match in matches where match.numberOfRanges >= 3 {
            let pathRange = match.range(at: 2)
            let rawPath = ns.substring(with: pathRange)
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

            let lowered = path.lowercased()
            if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("data:") {
                continue // remote — never fetched, never prompted
            }
            guard ImageResolver.hasImageExtension(path) else { continue } // not an image target
            if case .localFile = ImageResolver.resolve(path: path, documentDirectory: documentDirectory) {
                continue // already readable → will render, no prompt
            }
            result.append(UnresolvedImageReference(path: path, range: match.range))
        }
        return result
    }
}
