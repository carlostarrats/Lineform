import Foundation

/// A run of prose an AI action may revise, in DOCUMENT UTF-16 coordinates. `text` carries no
/// leading or trailing whitespace — edge whitespace stays in the document and is never sent.
public struct ProseSegment: Equatable {
    public let range: NSRange
    public let text: String

    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }
}
