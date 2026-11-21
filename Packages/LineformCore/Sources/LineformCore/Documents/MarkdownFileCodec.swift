import Foundation

/// The one byte rule for reading and writing a Markdown or plain-text file, shared by the Mac
/// document, the live-reload reader and the iPhone app so all of them see the same text.
///
/// Validate with `String(data:encoding:)`: it returns nil on invalid UTF-8, which is how a corrupt
/// file is rejected rather than repaired. Decode with `String(decoding:as:)`, because the
/// validating initializer ALSO strips a leading U+FEFF on Darwin: the BOM then never reaches the
/// text, `encode` cannot re-emit it, and the first write silently drops three bytes from the head
/// of every Notepad-authored file. This is the same rule as the CRLF one: Lineform never
/// normalises a file's byte-level conventions for the writer.
public enum MarkdownFileCodec {
    /// The text of `data`, or nil when it is not valid UTF-8. A leading BOM and CRLF line endings
    /// are kept as they are.
    public static func decode(_ data: Data) -> String? {
        guard String(data: data, encoding: .utf8) != nil else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The UTF-8 bytes of `text`, exactly: nothing is added, removed or normalised.
    public static func encode(_ text: String) -> Data {
        Data(text.utf8)
    }
}
