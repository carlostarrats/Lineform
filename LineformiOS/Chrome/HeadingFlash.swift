import LineformCore
import QuartzCore
import UIKit

/// The brief flash on a heading the Outline jumped to: a Lineform-blue wash behind the heading's
/// line that fades out over a second. A layer behind the text, never a text attribute, so nothing
/// reaches the text storage or the undo history. With Reduce Motion the wash still fades (opacity
/// only, no movement).
@MainActor
enum HeadingFlash {
    static let duration: CFTimeInterval = 1.1
    /// The wash's colour at its strongest.
    static let color = UIColor(red: 0.184, green: 0.420, blue: 0.871, alpha: 0.22)
    /// The scroll re-asserts itself for a few ticks; the flash waits for the layout to settle.
    static let delay: TimeInterval = 0.08

    /// The editor: `sourceRange` is in the document's text. The whole line by default (an
    /// Outline jump); `wholeLine: false` washes the range itself (a search match).
    static func flash(sourceRange: NSRange, in editor: UITextView, wholeLine: Bool = true) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak editor] in
            guard let editor else { return }
            let text = editor.textStorage.string as NSString
            guard sourceRange.location <= text.length else { return }
            if !wholeLine, sourceRange.length > 0, NSMaxRange(sourceRange) <= text.length {
                show(characterRange: sourceRange, in: editor)
                return
            }
            let line = text.lineRange(for: NSRange(location: sourceRange.location, length: 0))
            show(characterRange: trimmed(line, in: text), in: editor)
        }
    }

    /// The Read view: `sourceRange` is in the document's text; the flash lands on its rendered line.
    static func flash(sourceRange: NSRange, inReader reader: UITextView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak reader] in
            guard let reader,
                  let index = SourcePosition.renderedIndex(forSourceLocation: sourceRange.location, in: reader.textStorage)
            else { return }
            let text = reader.textStorage.string as NSString
            let line = text.paragraphRange(for: NSRange(location: min(index, max(0, text.length - 1)), length: 0))
            show(characterRange: trimmed(line, in: text), in: reader)
        }
    }

    /// The line without its line ending.
    private static func trimmed(_ line: NSRange, in text: NSString) -> NSRange {
        var range = line
        while range.length > 0 {
            let last = text.character(at: NSMaxRange(range) - 1)
            guard last == 0x0A || last == 0x0D || last == 0x2028 || last == 0x2029 else { break }
            range.length -= 1
        }
        return range
    }

    private static func show(characterRange: NSRange, in textView: UITextView) {
        let layoutManager = textView.layoutManager
        let container = textView.textContainer
        guard characterRange.length > 0 else { return }
        layoutManager.ensureLayout(forCharacterRange: characterRange)
        let glyphs = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        guard !rect.isNull, rect.width > 0 else { return }
        rect = rect.offsetBy(dx: textView.textContainerInset.left, dy: textView.textContainerInset.top)
            .insetBy(dx: -6, dy: -3)
        let layer = CALayer()
        layer.frame = rect
        layer.backgroundColor = color.cgColor
        layer.cornerRadius = 6
        layer.opacity = 0
        // Behind the text's own view, so the ink stays on top.
        textView.layer.insertSublayer(layer, at: 0)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        layer.add(fade, forKey: "flash")
        CATransaction.commit()
    }
}
