import Foundation

enum ReadingAssistRangeResolver {
    static func focusRange(in text: String, selectedRange: NSRange, mode: FocusMode) -> NSRange? {
        let textLength = (text as NSString).length
        guard textLength > 0 else {
            return nil
        }

        let location = min(max(selectedRange.location, 0), max(textLength - 1, 0))
        let caretRange = NSRange(location: location, length: 0)

        switch mode {
        case .off:
            return nil
        case .currentLine:
            return (text as NSString).lineRange(for: caretRange)
        case .currentSentence:
            return sentenceRange(in: text, containing: location)
        case .currentParagraph:
            return paragraphRange(in: text, containing: location)
        }
    }

    private static func paragraphRange(in text: String, containing location: Int) -> NSRange {
        let nsText = text as NSString
        let beforeRange = NSRange(location: 0, length: location)
        let afterRange = NSRange(location: location, length: nsText.length - location)

        let previousBreak = nsText.range(of: "\n\n", options: .backwards, range: beforeRange)
        let nextBreak = nsText.range(of: "\n\n", options: [], range: afterRange)

        let start = previousBreak.location == NSNotFound ? 0 : previousBreak.location + previousBreak.length
        let end = nextBreak.location == NSNotFound ? nsText.length : nextBreak.location + 1

        return NSRange(location: start, length: max(0, end - start))
    }

    private static func sentenceRange(in text: String, containing location: Int) -> NSRange {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var match = nsText.lineRange(for: NSRange(location: location, length: 0))

        nsText.enumerateSubstrings(in: fullRange, options: [.bySentences, .substringNotRequired]) { _, range, enclosingRange, stop in
            guard NSLocationInRange(location, enclosingRange) else {
                return
            }

            match = range
            stop.pointee = true
        }

        return match
    }
}
