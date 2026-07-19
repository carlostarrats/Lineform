import Foundation

/// One `![alt](path)` reference in a document that could not be resolved to a readable local
/// image file (either missing, or existing but outside every granted sandbox scope — the two are
/// indistinguishable under the sandbox, so both surface here).
struct UnresolvedImageReference: Equatable {
    let path: String
    let range: NSRange
}

/// Pure pre-flight scan for Styled PDF export / Print: finds local image references the app can't
/// currently read, so the caller can offer a single grant-access prompt. Never touches the network;
/// remote (`http(s)`/`data:`) references are ignored, and non-image link targets (`![x](notes.txt)`)
/// are ignored — only genuine image references that fail to resolve are returned.
///
/// It scans the SAME block partition the renderer uses (`markdownBlocks(in:)`), considering only
/// `.image` blocks — i.e. images ALONE on their own line, outside code fences — because those are
/// the only references that render as a real picture. A mid-sentence image (or one inside a code
/// fence) always renders as the inline placeholder, so granting access to it would accomplish
/// nothing; the prompt would be misleading. Scoping to `.image` blocks keeps the prompt honest: it
/// offers access exactly for the images that would otherwise render as placeholders.
enum ImageExportPreflight {
    static func unresolvedLocalReferences(in text: String, documentDirectory: URL?) -> [UnresolvedImageReference] {
        let lines = text.components(separatedBy: "\n")
        var result: [UnresolvedImageReference] = []
        for block in markdownBlocks(in: lines) {
            guard case let .image(_, rawPath, sourceRange, _) = block else { continue }
            let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)

            let lowered = path.lowercased()
            if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("data:") {
                continue // remote — never fetched, never prompted
            }
            guard ImageResolver.hasImageExtension(path) else { continue } // not an image target
            // A relative path with no document directory (an untitled/never-saved doc) can never
            // resolve — there is no base to resolve it against, and granting a folder can't supply
            // one — so prompting would be hollow (the image stays a placeholder regardless). Only an
            // absolute / file:// path can be made readable by a grant, so only those are worth a prompt.
            if documentDirectory == nil, !(path.hasPrefix("/") || lowered.hasPrefix("file://")) {
                continue
            }
            if case .localFile = ImageResolver.resolve(path: path, documentDirectory: documentDirectory) {
                continue // already readable → will render, no prompt
            }
            result.append(UnresolvedImageReference(path: path, range: sourceRange))
        }
        return result
    }
}
