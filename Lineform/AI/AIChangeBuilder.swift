import Foundation

/// One suggested change, in DOCUMENT UTF-16 coordinates. `range` always sits on
/// composed-character boundaries; an insertion has an empty range.
struct AIChange: Equatable, Identifiable {
    let id: Int
    var range: NSRange
    let original: String
    let replacement: String
}

/// Turns admitted segment revisions into word-level changes.
///
/// Tokens are letter/number runs (an apostrophe between letters stays in the word), whitespace
/// runs, and single other Characters. A Han, kana or other ideograph is its own token: those
/// scripts write without spaces, and a whole sentence as one "word" would turn a one-character
/// fix into a sentence-wide change. Every token is built from whole `Character`s, so no change
/// can split an emoji, a combining sequence or a CJK cluster.
///
/// Tokens compare with `String` equality (canonical equivalence): an AI that answers in NFC for
/// an NFD document changes nothing the writer can see, and the writer's own bytes are kept.
enum AIChangeBuilder {
    /// Above this many LCS cells a segment becomes one whole-segment change.
    static let maxDiffCells = 4_000_000

    static func changes(segments: [ProseSegment], revisions: [String?], in text: String) -> [AIChange] {
        let ns = text as NSString
        var pieces: [(range: NSRange, original: String, replacement: String)] = []
        for (index, segment) in segments.enumerated() where index < revisions.count {
            guard let revision = revisions[index],
                  segment.range.location >= 0, NSMaxRange(segment.range) <= ns.length,
                  // EXACT UTF-16: `==` is canonical equivalence, so a renormalized region would
                  // pass and a change would splice over bytes the AI never saw.
                  ns.substring(with: segment.range).utf16.elementsEqual(segment.text.utf16),
                  revision != segment.text else { continue }
            pieces += diff(segment, revision: revision)
        }
        pieces.sort { $0.range.location < $1.range.location }
        return pieces.enumerated().map { offset, piece in
            AIChange(id: offset, range: piece.range, original: piece.original, replacement: piece.replacement)
        }
    }

    // MARK: - Tokens

    struct Token {
        let text: String
        /// UTF-16 offset within its source string.
        let offset: Int
        let length: Int
        let isWhitespace: Bool
    }

    private enum Kind { case word, whitespace, other }

    private static func kind(of character: Character) -> Kind {
        if character.isWhitespace { return .whitespace }
        if character.isLetter || character.isNumber {
            return isIdeographic(character) ? .other : .word
        }
        return .other
    }

    private static func isIdeographic(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if scalar.properties.isIdeographic { return true }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true // kana
        default: return false
        }
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "\u{2019}"
    }

    static func tokens(_ string: String) -> [Token] {
        let characters = Array(string)
        var result: [Token] = []
        var offset = 0
        var index = 0
        while index < characters.count {
            let start = index
            let startKind = kind(of: characters[index])
            index += 1
            switch startKind {
            case .word:
                while index < characters.count {
                    if kind(of: characters[index]) == .word {
                        index += 1
                    } else if isApostrophe(characters[index]), index + 1 < characters.count,
                              kind(of: characters[index + 1]) == .word {
                        index += 2
                    } else {
                        break
                    }
                }
            case .whitespace:
                while index < characters.count, kind(of: characters[index]) == .whitespace { index += 1 }
            case .other:
                break
            }
            let text = String(characters[start..<index])
            let length = text.utf16.count
            result.append(Token(text: text, offset: offset, length: length, isWhitespace: startKind == .whitespace))
            offset += length
        }
        return result
    }

    // MARK: - Diff

    private static func diff(_ segment: ProseSegment, revision: String) -> [(range: NSRange, original: String, replacement: String)] {
        let a = tokens(segment.text)
        let b = tokens(revision)
        let base = segment.range.location
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= maxDiffCells else {
            return [(segment.range, segment.text, revision)]
        }

        // LCS lengths from the END, so a forward walk can choose greedily.
        let n = a.count
        let m = b.count
        let width = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = a[i].text == b[j].text
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }

        // Hunks: maximal runs of unmatched tokens, as token index spans on each side.
        struct Hunk { var a: Range<Int>; var b: Range<Int> }
        var hunks: [Hunk] = []
        var i = 0
        var j = 0
        var aStart = 0
        var bStart = 0
        func close() {
            if aStart < i || bStart < j { hunks.append(Hunk(a: aStart..<i, b: bStart..<j)) }
        }
        while i < n || j < m {
            if i < n, j < m, a[i].text == b[j].text {
                close()
                i += 1
                j += 1
                aStart = i
                bStart = j
            } else if j >= m || (i < n && table[(i + 1) * width + j] >= table[i * width + j + 1]) {
                i += 1
            } else {
                j += 1
            }
        }
        close()

        // Two hunks separated only by matched whitespace become one change.
        var merged: [Hunk] = []
        for hunk in hunks {
            if let last = merged.last,
               a[last.a.upperBound..<hunk.a.lowerBound].allSatisfy(\.isWhitespace) {
                merged[merged.count - 1] = Hunk(a: last.a.lowerBound..<hunk.a.upperBound,
                                               b: last.b.lowerBound..<hunk.b.upperBound)
            } else {
                merged.append(hunk)
            }
        }

        return merged.map { hunk in
            let start = hunk.a.isEmpty
                ? (hunk.a.lowerBound < n ? a[hunk.a.lowerBound].offset : (segment.text as NSString).length)
                : a[hunk.a.lowerBound].offset
            let end = hunk.a.isEmpty ? start : a[hunk.a.upperBound - 1].offset + a[hunk.a.upperBound - 1].length
            let original = a[hunk.a].map(\.text).joined()
            let replacement = b[hunk.b].map(\.text).joined()
            return (NSRange(location: base + start, length: end - start), original, replacement)
        }
    }
}
