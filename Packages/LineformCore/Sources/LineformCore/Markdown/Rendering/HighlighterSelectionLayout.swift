import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The selected lines a TextKit 1 editor shows, for `HighlighterSelection` (both editors use it:
/// the Mac's `NSTextView` and the iPhone's TextKit 1 `UITextView`).
///
/// Scoped to what is on screen: only the glyphs inside `visibleRect` are walked, so selecting all
/// of a 1 MB document costs no more than selecting one screenful. Nothing is written anywhere.
public enum HighlighterSelectionLayout {
    /// One `HighlighterSelection.Line` per line fragment that `selection` touches inside
    /// `visibleRect` (container coordinates), offset into the view by `origin` (the text
    /// container's origin in the drawing view).
    @MainActor
    public static func lines(
        selection: NSRange,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        visibleRect: CGRect,
        origin: CGPoint
    ) -> [HighlighterSelection.Line] {
        guard let storage = layoutManager.textStorage else { return [] }
        let length = storage.length
        let clamped = NSIntersectionRange(selection, NSRange(location: 0, length: length))
        guard clamped.length > 0, !visibleRect.isEmpty else { return [] }

        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let selectedGlyphs = layoutManager.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
        let glyphs = NSIntersectionRange(visibleGlyphs, selectedGlyphs)
        guard glyphs.length > 0 else { return [] }

        let text = storage.string as NSString
        var lines: [HighlighterSelection.Line] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, container, lineGlyphs, _ in
            let part = NSIntersectionRange(lineGlyphs, selectedGlyphs)
            guard part.length > 0 else { return }
            var characters = layoutManager.characterRange(forGlyphRange: part, actualGlyphRange: nil)
            // A line break is selected but never painted past the text, as in the mockup.
            while characters.length > 0, isLineBreak(text.character(at: NSMaxRange(characters) - 1)) {
                characters.length -= 1
            }
            let minX: CGFloat
            let maxX: CGFloat
            if characters.length > 0 {
                let inkGlyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
                let box = layoutManager.boundingRect(forGlyphRange: inkGlyphs, in: container)
                minX = box.minX
                maxX = box.maxX
            } else {
                // An empty line (or only its line break): a short nib where the line starts.
                minX = rect.minX + layoutManager.location(forGlyphAt: part.location).x
                maxX = minX
            }

            let fontIndex = min(characters.length > 0 ? characters.location : part.location, max(length - 1, 0))
            let font = (storage.attribute(.font, at: fontIndex, effectiveRange: nil) as? PlatformFont)
                ?? PlatformFont.systemFont(ofSize: 17)
            let ascender = font.ascender
            let descender = font.descender // negative
            let baseline = rect.minY + layoutManager.location(forGlyphAt: lineGlyphs.location).y
            let centerY = baseline - (ascender + descender) / 2

            lines.append(HighlighterSelection.Line(
                minX: minX + origin.x,
                maxX: maxX + origin.x,
                centerY: centerY + origin.y,
                textHeight: ascender - descender,
                pitch: rect.height,
                seed: layoutManager.characterIndexForGlyph(at: lineGlyphs.location)
            ))
        }
        return lines
    }

    private static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 || unit == 0x85
    }
}
