import Foundation

/// Ask AI for the whole document — Edit ▸ Ask AI… with nothing selected on the Mac, the Menu's
/// Ask AI… row on the iPhone. One length policy for both apps, decided before the comment field
/// opens: up to `confirmWordCount` words it runs, above that the writer confirms first, and past
/// `AILimits` it is refused — before the Keychain is read or anything is sent.
///
/// Words and length are what would be SENT: the document's prose segments
/// (`MarkdownStructureMap.proseSegments`), never its code, front matter or other structure.
public enum WholeDocumentAIPolicy {
    public static let confirmWordCount = 1_500

    public enum Decision: Equatable {
        case run
        /// Ask first: "Send the whole document (N words) to …?", Send / Cancel (Cancel the default).
        case confirm(words: Int)
        /// Past `AILimits`: `refusalMessage`, nothing sent.
        case refuse
    }

    public static func decision(for text: String) -> Decision {
        let ns = text as NSString
        let segments = MarkdownStructureMap.proseSegments(in: text, selection: NSRange(location: 0, length: ns.length))
        let length = segments.reduce(0) { $0 + ($1.text as NSString).length }
        guard segments.count <= AILimits.maxSegments, length <= AILimits.maxProseUTF16 else { return .refuse }
        let words = DocumentStatistics(text: segments.map(\.text).joined(separator: " ")).wordCount
        return words > confirmWordCount ? .confirm(words: words) : .run
    }

    public static var refusalMessage: String {
        String(localized: "Select a part of the document — about 4,000 words at most.", bundle: .module)
    }

    public static func confirmationTitle(words: Int, recipient: String, bundle: Bundle = .lineformCore) -> String {
        String(localized: "Send the whole document (\(words) words) to \(recipient)?", bundle: bundle)
    }

    public static var sendTitle: String { String(localized: "Send", bundle: .module) }
    public static var cancelTitle: String { String(localized: "Cancel", bundle: .module) }

    /// Who the confirmation names: the provider (Claude, ChatGPT, Google), or for Other the
    /// address's host — the same recipient the Connect button named — else "Your AI".
    public static func recipient(for provider: AIProvider, otherEndpoint: URL?) -> String {
        if provider == .other, let host = otherEndpoint?.host, !host.isEmpty { return host }
        return SelectionToolbarPresentation.aiName(for: provider)
    }
}
