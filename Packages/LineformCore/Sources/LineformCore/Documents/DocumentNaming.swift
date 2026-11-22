import Foundation

/// Names a new document from its first line, and keeps the name unique in its folder.
///
/// The rules turn any first line into a safe file name: Markdown markers and emphasis go, the
/// characters a file system or the Files app rejects become spaces, a leading dot cannot hide the
/// file, and a long line is cut to a readable length without splitting a character.
public enum DocumentNaming {
    /// The longest base name, in characters (grapheme clusters).
    static let maximumBaseNameLength = 60
    /// How far back from the cut a word boundary may fall and still be used.
    static let wordBoundaryWindow = 15
    /// The longest base name in UTF-8 bytes. File names are limited to 255 bytes; this leaves room
    /// for a " N" suffix and the ".md" extension, so a line of emoji still gives a name that saves.
    static let maximumBaseNameBytes = 200

    /// The name for a document whose first line has nothing left after the rules: "Untitled".
    public static let untitledBaseName = String(localized: "Untitled", bundle: .module)

    /// The base name (no extension) for a document holding `text`, or nil when the text has no
    /// non-whitespace character (such a document gets no file).
    ///
    /// The name comes from the first line that still has words once its image references
    /// (`![alt](dest)`) are taken out, so a pasted image never names the document; a link in that
    /// line counts as its text. A document of nothing but images is Untitled (not nil: it still
    /// gets a file, beside its `images/` folder).
    public static func baseName(fromText text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.contains(where: { $0.contains { !$0.isWhitespace } }) else { return nil }
        guard let line = lines.lazy
            .map({ removingImageReferences(from: String($0)) })
            .first(where: { $0.contains { !$0.isWhitespace } })
        else { return untitledBaseName }

        var name = stripLeadingMarkers(reducingLinksToText(in: line))
        name.removeAll { emphasisMarkers.contains($0) }
        name = replacingUnsafeCharacters(in: name)
        name = collapsingWhitespace(in: name)
        name = String(name.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
        name = truncated(name)
        return name.isEmpty ? untitledBaseName : name
    }

    /// `"<base>.md"`, or `"<base> 2.md"`, `"<base> 3.md"` and so on: the first that is not in
    /// `existingNames`. The comparison ignores case (and Unicode normalisation), as the default
    /// APFS volume does.
    public static func uniqueFileName(base: String, existingNames: Set<String>) -> String {
        let taken = Set(existingNames.map(comparisonKey))
        var candidate = "\(base).md"
        var number = 2
        while taken.contains(comparisonKey(candidate)) {
            candidate = "\(base) \(number).md"
            number += 1
        }
        return candidate
    }

    // MARK: - Rules

    private static let emphasisMarkers: Set<Character> = ["*", "_", "`", "~"]
    private static let unsafeCharacters: Set<Character> = ["/", ":", "\\", "?", "%", "*", "|", "\"", "<", ">"]

    private static func comparisonKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Strips heading `#`s, list markers (`-`, `*`, `+`, `1.`), `>` and task boxes (`[ ]`,
    /// `[x]`) from the start of the line, repeatedly, so `> - [ ] Item` gives `Item`. A marker
    /// counts only when whitespace or the end of the line follows it, so `#tag` and `-5°` stay.
    private static func stripLeadingMarkers(_ line: String) -> String {
        var rest = Substring(line).drop { $0.isWhitespace }
        while true {
            let before = rest
            if rest.first == "#" {
                rest = markerEnd(rest.drop { $0 == "#" }) ?? rest
            } else if let first = rest.first, ["-", "*", "+"].contains(first) {
                rest = markerEnd(rest.dropFirst()) ?? rest
            } else if rest.first == ">" {
                rest = rest.dropFirst()
            } else if let first = rest.first, first.isASCII, first.isNumber {
                let afterDigits = rest.drop { $0.isASCII && $0.isNumber }
                if afterDigits.first == "." { rest = markerEnd(afterDigits.dropFirst()) ?? rest }
            } else if rest.hasPrefix("[ ]") || rest.hasPrefix("[x]") || rest.hasPrefix("[X]") {
                rest = markerEnd(rest.dropFirst(3)) ?? rest
            }
            rest = rest.drop { $0.isWhitespace }
            if rest == before { return String(rest) }
        }
    }

    /// `afterMarker` when the marker ended the line or whitespace follows it; nil otherwise.
    private static func markerEnd(_ afterMarker: Substring) -> Substring? {
        guard let next = afterMarker.first else { return afterMarker }
        return next.isWhitespace ? afterMarker : nil
    }

    /// `![alt](dest)`, on one line.
    private static let imageReference = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)\n]*\)"#)
    /// `[text](dest)`, on one line; the text is group 1.
    private static let linkReference = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)\n]*\)"#)

    private static func removingImageReferences(from line: String) -> String {
        imageReference.stringByReplacingMatches(
            in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: " "
        )
    }

    private static func reducingLinksToText(in line: String) -> String {
        linkReference.stringByReplacingMatches(
            in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "$1"
        )
    }

    private static func replacingUnsafeCharacters(in name: String) -> String {
        String(name.map { character in
            let isControl = character.unicodeScalars.contains { $0.properties.generalCategory == .control }
            return unsafeCharacters.contains(character) || isControl ? " " : character
        })
    }

    private static func collapsingWhitespace(in name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Cuts to `maximumBaseNameLength` characters, at a word boundary when one falls within the
    /// last `wordBoundaryWindow` characters, otherwise hard; then drops whole characters until the
    /// name fits `maximumBaseNameBytes`. Works on `Character`s, so a cluster is never split.
    private static func truncated(_ name: String) -> String {
        var result = name
        if result.count > maximumBaseNameLength {
            let cut = result.index(result.startIndex, offsetBy: maximumBaseNameLength)
            let head = result[..<cut]
            if result[cut].isWhitespace {
                result = String(head)
            } else if let space = head.lastIndex(where: \.isWhitespace),
                      head.distance(from: space, to: head.endIndex) <= wordBoundaryWindow {
                result = String(head[..<space])
            } else {
                result = String(head)
            }
        }
        while result.utf8.count > maximumBaseNameBytes {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
