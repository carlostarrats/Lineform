import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Applies the editor's Markdown styling to a text storage: base attributes over the WHOLE
/// document (uniform font / paragraph style / kern / colour → stable layout everywhere), token
/// inks only within a scope. Moved from the Mac app's `MarkdownSyntaxHighlighter`
/// (`highlight`, `refreshTokens` and the token → attributes map), which now forwards here, so the
/// Mac writes the same attributes as before and the iPhone editor writes the same ones too.
public enum MarkdownTokenStyler {
    /// Full refresh: resets the whole document to base attributes and colours tokens only within
    /// `tokenScope`. `nil` colours the whole document.
    public static func apply(to storage: NSTextStorage, profile: ReadingProfile, tokenScope: NSRange?) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let scope = NSIntersectionRange(tokenScope ?? fullRange, fullRange)

        storage.beginEditing()
        storage.setAttributes(MarkdownTextStyle.baseAttributes(for: profile), range: fullRange)
        addTokenAttributes(to: storage, profile: profile, scope: scope)
        storage.endEditing()
    }

    /// Resets the whole document to base attributes, with no token inks.
    public static func applyBase(to storage: NSTextStorage, profile: ReadingProfile) {
        apply(to: storage, profile: profile, tokenScope: NSRange(location: 0, length: 0))
    }

    /// Incremental token pass: resets ONLY `scope` to base (clearing stale token colours there)
    /// and re-applies tokens within it. Does not touch the rest of the document — base is already
    /// whole-document from the last full pass, and edits preserve attributes. The per-pass cost is
    /// bounded to the scope.
    public static func applyTokens(to storage: NSTextStorage, profile: ReadingProfile, scope: NSRange) {
        let clamped = NSIntersectionRange(scope, NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else {
            return
        }

        storage.beginEditing()
        storage.setAttributes(MarkdownTextStyle.baseAttributes(for: profile), range: clamped)
        addTokenAttributes(to: storage, profile: profile, scope: clamped)
        storage.endEditing()
    }

    private static func addTokenAttributes(to storage: NSTextStorage, profile: ReadingProfile, scope: NSRange) {
        guard scope.length > 0 else { return }
        for token in MarkdownTokenScope.tokens(in: storage.string as NSString, scope: scope) where NSMaxRange(token.range) <= storage.length {
            storage.addAttributes(attributes(for: token.kind, profile: profile), range: token.range)
        }
    }

    /// The attributes a token of `kind` adds over the base attributes.
    public static func attributes(for kind: MarkdownTokenKind, profile: ReadingProfile) -> [NSAttributedString.Key: Any] {
        let markerColor = MarkdownTextStyle.markdownMarkerColor(for: profile)
        let mutedColor = markerColor

        switch kind {
        case .headingMarker:
            return [.foregroundColor: markerColor]
        case .listMarker, .checkbox, .blockquoteMarker:
            return [.foregroundColor: mutedColor]
        case .codeSpan, .codeFence:
            return [
                .font: PlatformFont.monospacedSystemFont(ofSize: CGFloat(profile.fontSize), weight: .regular),
                .foregroundColor: MarkdownTextStyle.inlineCodeColor(for: profile)
            ]
        case .linkText:
            // Through the theme's contrast floor: the system link colour was the one reader ink
            // not derived from the theme, so nothing put it under the contrast gate — it reads
            // 3.70:1 on Quiet, below AA.
            return [.foregroundColor: Theme.theme(for: profile).readableInk(PlatformColor.lineformLink)]
        case .linkDestination:
            return [.foregroundColor: markerColor]
        case .imageText, .imageDestination:
            // Image links read in link blue (both alt and path) so they're easy to spot as
            // references — unlike ordinary links, the path is colored too, since image links
            // often have an empty alt (`![](path)`) and the path is the only visible content.
            return [.foregroundColor: Theme.theme(for: profile).readableInk(PlatformColor.lineformLink)]
        }
    }
}
