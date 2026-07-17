import AppKit
import QuickLookUI

@MainActor
@preconcurrency
class PreviewViewController: NSViewController, QLPreviewingController {
    private var textView: NSTextView!

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = NSFont.systemFont(ofSize: 17)
        textView.textContainerInset = NSSize(width: 40, height: 40)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.documentView = textView
        self.view = scrollView
    }

    nonisolated func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping @Sendable (Error?) -> Void) {
        Task { @MainActor in
            do {
                let markdown = try Self.readText(at: url)
                let attributedString = QuickLookMarkdownRenderer.render(markdown)
                textView.textStorage?.setAttributedString(attributedString)
                handler(nil)
            } catch {
                handler(error)
            }
        }
    }

    /// Reads a Markdown/text file, tolerating non-UTF-8 encodings. UTF-8 is the app's
    /// canonical format and by far the common case, so it is tried first; a file saved in
    /// another editor with a legacy encoding falls back to a sniffed encoding, then Latin-1
    /// (which never fails) so Quick Look shows a preview instead of an error.
    private nonisolated static func readText(at url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        var sniffed: String.Encoding = .utf8
        if let detected = try? String(contentsOf: url, usedEncoding: &sniffed) {
            return detected
        }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }
}

enum QuickLookMarkdownRenderer {
    // Matches the app's ReadingProfile.original defaults
    private static let bodyFontSize: CGFloat = 17
    private static let lineHeightMultiple: CGFloat = 1.5
    private static let paragraphSpacing: CGFloat = 12
    private static let letterSpacing: CGFloat = 0.5
    private static let listIndentStep: CGFloat = 24
    private static let listMarkerColumn: CGFloat = 22
    private static let blockquoteIndentStep: CGFloat = 22

    // Heading size boosts matching MarkdownPreviewRenderer
    private static let headingSizeBoosts: [Int: CGFloat] = [
        1: 11, 2: 3, 3: 2, 4: 1, 5: 0, 6: 0
    ]

    static func render(_ text: String) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let lines = text.components(separatedBy: "\n")
        let bodyFont = NSFont.systemFont(ofSize: bodyFontSize)
        let themeTextColor = NSColor.labelColor

        var inCodeBlock = false
        var codeBlockLines: [String] = []
        var listStack: [(type: String, indent: Int)] = []
        var listIndexCounters: [Int] = []
        var inBlockquote = false
        var inTable = false
        var tableRows: [[String]] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            if !paragraphBuffer.isEmpty {
                let content = paragraphBuffer.joined(separator: " ")
                let attrs = bodyAttributes()
                let attrString = NSAttributedString(string: content + "\n", attributes: attrs)
                output.append(attrString)
                paragraphBuffer = []
            }
        }

        func closeAllLists() {
            while !listStack.isEmpty {
                listStack.removeLast()
                // List closure doesn't add visual text; spacing is handled by paragraph styles
            }
            // Reset ordered-list numbering so a later numbered list restarts at 1 rather than
            // continuing from the previous list's last index (e.g. 4, 5, 6…).
            listIndexCounters = []
        }

        func appendParagraph(text: String, attributes: [NSAttributedString.Key: Any] = [:]) {
            var attrs = bodyAttributes()
            attrs.merge(attributes) { _, new in new }
            let attrString = NSAttributedString(string: text + "\n", attributes: attrs)
            output.append(attrString)
        }

        func listIndex(at level: Int) -> Int {
            while listIndexCounters.count <= level {
                listIndexCounters.append(0)
            }
            listIndexCounters[level] += 1
            return listIndexCounters[level]
        }

        // A GFM table delimiter row: only dashes, colons, pipes and spaces, with ≥1 dash.
        func isTableDelimiterRow(_ line: String) -> Bool {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.contains("-") else { return false }
            return candidate.allSatisfy { $0 == "-" || $0 == ":" || $0 == "|" || $0 == " " }
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code blocks
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    let codeText = codeBlockLines.joined(separator: "\n") + "\n"
                    let codeFont = NSFont.monospacedSystemFont(ofSize: bodyFontSize, weight: .regular)
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: codeFont,
                        .foregroundColor: themeTextColor
                    ]
                    attrs[.paragraphStyle] = paragraphStyle(lineHeight: lineHeightMultiple, spacing: paragraphSpacing)
                    output.append(NSAttributedString(string: codeText, attributes: attrs))
                    inCodeBlock = false
                    codeBlockLines = []
                } else {
                    flushParagraph()
                    closeAllLists()
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeBlockLines.append(line)
                continue
            }

            // Empty line
            if trimmed.isEmpty {
                flushParagraph()
                if inBlockquote {
                    inBlockquote = false
                }
                if inTable {
                    output.append(renderTable(tableRows))
                    tableRows = []
                    inTable = false
                }
                continue
            }

            // Table detection (GFM): a row contains a pipe, and either we're already inside a
            // table or the NEXT line is a delimiter row (dashes/colons/pipes). The leading pipe
            // is optional per GFM, so we don't require hasPrefix("|"); the lookahead keeps a
            // stray "a | b" in prose from being mistaken for a table.
            if trimmed.contains("|"),
               inTable || (index + 1 < lines.count && isTableDelimiterRow(lines[index + 1])) {
                flushParagraph()
                closeAllLists()
                inTable = true

                // A delimiter row (---|:--:) sets alignment and carries no cell text — skip it.
                if isTableDelimiterRow(trimmed) {
                    continue
                }

                // Split on pipes and drop only the empty cells created by an optional
                // leading/trailing pipe — never a real first/last column.
                var cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                if cells.first == "" { cells.removeFirst() }
                if cells.last == "" { cells.removeLast() }
                tableRows.append(cells)
                continue
            }

            // Headings
            var handledAsHeading = false
            for level in 1...6 {
                let prefix = String(repeating: "#", count: level) + " "
                if trimmed.hasPrefix(prefix) {
                    flushParagraph()
                    closeAllLists()
                    let content = String(trimmed.dropFirst(prefix.count))
                    let headingSize = bodyFontSize + (headingSizeBoosts[level] ?? 0)
                    let font = NSFont.boldSystemFont(ofSize: headingSize)
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: themeTextColor
                    ]
                    let spacing = paragraphSpacing + (level <= 2 ? 4 : 0)
                    attrs[.paragraphStyle] = paragraphStyle(lineHeight: lineHeightMultiple, spacing: spacing)
                    attrs[.kern] = letterSpacing
                    output.append(NSAttributedString(string: content + "\n", attributes: attrs))
                    handledAsHeading = true
                    break
                }
            }
            if handledAsHeading { continue }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                closeAllLists()
                let ruleColor = themeTextColor.withAlphaComponent(0.22)
                let ruleFont = NSFont.systemFont(ofSize: bodyFontSize)
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: ruleFont,
                    .foregroundColor: ruleColor
                ]
                attrs[.paragraphStyle] = paragraphStyle(lineHeight: 1.0, spacing: paragraphSpacing)
                output.append(NSAttributedString(string: "\n\u{2014}\u{2014}\u{2014}\u{2014}\u{2014}\u{2014}\u{2014}\u{2014}\n", attributes: attrs))
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                closeAllLists()
                if !inBlockquote {
                    inBlockquote = true
                }
                let content = String(trimmed.dropFirst(2))
                let color = themeTextColor.withAlphaComponent(0.8)
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: bodyFont,
                    .foregroundColor: color
                ]
                let style = paragraphStyle(lineHeight: lineHeightMultiple, spacing: paragraphSpacing)
                style.headIndent = blockquoteIndentStep
                style.firstLineHeadIndent = blockquoteIndentStep
                attrs[.paragraphStyle] = style
                attrs[.kern] = letterSpacing
                output.append(NSAttributedString(string: content + "\n", attributes: attrs))
                continue
            }

            // List items
            let listMatch = matchListItem(line)
            if let match = listMatch {
                flushParagraph()

                let currentIndent = match.indent
                let listType = match.type

                if listStack.isEmpty {
                    listStack.append((type: listType, indent: currentIndent))
                } else {
                    let lastList = listStack.last!
                    if currentIndent > lastList.indent {
                        listStack.append((type: listType, indent: currentIndent))
                    } else if currentIndent < lastList.indent {
                        while !listStack.isEmpty && listStack.last!.indent > currentIndent {
                            listStack.removeLast()
                        }
                        if listStack.isEmpty || listStack.last!.type != listType {
                            listStack.append((type: listType, indent: currentIndent))
                        }
                    } else if lastList.type != listType {
                        listStack.removeLast()
                        listStack.append((type: listType, indent: currentIndent))
                    }
                }

                let level = listStack.count - 1
                let marker = listType == "ul" ? "\u{2022}" : "\(listIndex(at: level))."
                let content = match.content
                let fullText = marker + "\t" + content + "\n"

                let color = themeTextColor
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: bodyFont,
                    .foregroundColor: color
                ]
                let style = paragraphStyle(lineHeight: lineHeightMultiple, spacing: paragraphSpacing / 2)
                let baseIndent = CGFloat(level) * listIndentStep
                style.headIndent = baseIndent + listMarkerColumn
                style.firstLineHeadIndent = baseIndent
                style.tabStops = [NSTextTab(textAlignment: .left, location: baseIndent + listMarkerColumn, options: [:])]
                attrs[.paragraphStyle] = style
                attrs[.kern] = letterSpacing
                output.append(NSAttributedString(string: fullText, attributes: attrs))
                continue
            }

            // Regular paragraph text
            closeAllLists()
            if inBlockquote {
                inBlockquote = false
            }
            paragraphBuffer.append(trimmed)
        }

        flushParagraph()
        closeAllLists()
        if inTable {
            output.append(renderTable(tableRows))
        }

        return output
    }

    private static func bodyAttributes() -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: bodyFontSize),
            .foregroundColor: NSColor.labelColor
        ]
        attrs[.paragraphStyle] = paragraphStyle(lineHeight: lineHeightMultiple, spacing: paragraphSpacing)
        attrs[.kern] = letterSpacing
        return attrs
    }

    private static func paragraphStyle(lineHeight: CGFloat, spacing: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight
        style.paragraphSpacing = spacing
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private struct ListItemMatch {
        let type: String
        let indent: Int
        let content: String
    }

    private static func matchListItem(_ line: String) -> ListItemMatch? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("- ") {
            return ListItemMatch(type: "ul", indent: leadingSpaces, content: String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("* ") {
            return ListItemMatch(type: "ul", indent: leadingSpaces, content: String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("+ ") {
            return ListItemMatch(type: "ul", indent: leadingSpaces, content: String(trimmed.dropFirst(2)))
        }

        if let match = trimmed.range(of: #"^\d+\. "#, options: .regularExpression) {
            let content = String(trimmed[match.upperBound...])
            return ListItemMatch(type: "ol", indent: leadingSpaces, content: content)
        }

        return nil
    }

    private static func renderTable(_ rows: [[String]]) -> NSAttributedString {
        guard !rows.isEmpty else { return NSAttributedString(string: "") }

        let result = NSMutableAttributedString(string: "")
        // Monospaced: the columns are aligned by space-padding, which only lines up in a
        // fixed-width font. A proportional font made the padded columns ragged.
        let headerFont = NSFont.monospacedSystemFont(ofSize: bodyFontSize * 0.9, weight: .bold)
        let cellFont = NSFont.monospacedSystemFont(ofSize: bodyFontSize * 0.9, weight: .regular)
        let textColor = NSColor.labelColor
        let borderColor = textColor.withAlphaComponent(0.25)

        let cellPadding = "  "
        let columnCount = rows.map(\.count).max() ?? 0

        // Calculate column widths
        var widths = Array(repeating: 0, count: columnCount)
        for row in rows {
            for (i, cell) in row.enumerated() {
                widths[i] = max(widths[i], cell.count)
            }
        }

        func pad(_ text: String, to width: Int) -> String {
            if text.count >= width { return text }
            return text + String(repeating: " ", count: width - text.count)
        }

        // Header row
        if let headerRow = rows.first {
            var line = ""
            for (i, cell) in headerRow.enumerated() {
                line += cellPadding + pad(cell, to: widths[i]) + cellPadding + "|"
            }
            line += "\n"
            var attrs: [NSAttributedString.Key: Any] = [
                .font: headerFont,
                .foregroundColor: textColor
            ]
            attrs[.paragraphStyle] = paragraphStyle(lineHeight: 1.0, spacing: 0)
            result.append(NSAttributedString(string: line, attributes: attrs))
        }

        // Separator
        var separator = ""
        for i in 0..<columnCount {
            let width = widths[i] + 4
            separator += String(repeating: "-", count: width) + "|"
        }
        separator += "\n"
        var sepAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: bodyFontSize * 0.9, weight: .regular),
            .foregroundColor: borderColor
        ]
        sepAttrs[.paragraphStyle] = paragraphStyle(lineHeight: 1.0, spacing: 0)
        result.append(NSAttributedString(string: separator, attributes: sepAttrs))

        // Body rows
        if rows.count > 1 {
            for row in rows.dropFirst() {
                var line = ""
                for (i, cell) in row.enumerated() {
                    line += cellPadding + pad(cell, to: widths[i]) + cellPadding + "|"
                }
                line += "\n"
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: cellFont,
                    .foregroundColor: textColor
                ]
                attrs[.paragraphStyle] = paragraphStyle(lineHeight: 1.0, spacing: 0)
                result.append(NSAttributedString(string: line, attributes: attrs))
            }
        }

        // Add spacing after table
        var spaceAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: bodyFontSize)
        ]
        spaceAttrs[.paragraphStyle] = paragraphStyle(lineHeight: 1.0, spacing: paragraphSpacing)
        result.append(NSAttributedString(string: "\n", attributes: spaceAttrs))

        return result
    }
}
