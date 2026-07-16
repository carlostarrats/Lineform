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
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 20, height: 20)

        scrollView.documentView = textView
        self.view = scrollView
    }

    nonisolated func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping @Sendable (Error?) -> Void) {
        Task { @MainActor in
            do {
                let markdown = try String(contentsOf: url, encoding: .utf8)
                let html = MarkdownToHTML.convert(markdown)

                if let data = html.data(using: .utf8) {
                    textView.drawsBackground = false
                    textView.backgroundColor = .clear

                    let attributedString = try NSAttributedString(
                        data: data,
                        options: [
                            .documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue
                        ],
                        documentAttributes: nil
                    )

                    textView.textStorage?.setAttributedString(attributedString)
                }

                handler(nil)
            } catch {
                handler(error)
            }
        }
    }
}

enum MarkdownToHTML {
    static func convert(_ markdown: String) -> String {
        var html = "<!DOCTYPE html>\n"
        html += "<html>\n<head>\n"
        html += "<meta charset=\"UTF-8\">\n"
        html += "<style>\n"
        html += stylesheet
        html += "</style>\n"
        html += "</head>\n<body>\n"
        html += renderMarkdown(markdown)
        html += "</body>\n</html>"
        return html
    }

    private static let stylesheet = """
        body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
            font-size: 13px;
            line-height: 1.6;
            color: #1d1d1f;
            background: transparent;
            padding: 0;
            margin: 0;
            max-width: 100%;
        }
        h1, h2, h3, h4, h5, h6 {
            margin-top: 1.2em;
            margin-bottom: 0.4em;
            font-weight: 600;
            line-height: 1.3;
        }
        h1 { font-size: 1.8em; border-bottom: 1px solid #e5e5e7; padding-bottom: 0.3em; }
        h2 { font-size: 1.4em; border-bottom: 1px solid #e5e5e7; padding-bottom: 0.3em; }
        h3 { font-size: 1.2em; }
        h4 { font-size: 1.1em; }
        h5 { font-size: 1em; }
        h6 { font-size: 0.9em; color: #6e6e73; }
        p {
            margin: 0.6em 0;
        }
        code {
            font-family: "SF Mono", Monaco, "Cascadia Code", monospace;
            background: #f5f5f7;
            padding: 2px 5px;
            border-radius: 3px;
            font-size: 0.9em;
        }
        pre {
            background: #f5f5f7;
            padding: 12px;
            border-radius: 6px;
            overflow-x: auto;
            margin: 0.8em 0;
            border: 1px solid #e5e5e7;
        }
        pre code {
            background: none;
            padding: 0;
            border-radius: 0;
            font-size: 0.85em;
            line-height: 1.5;
        }
        blockquote {
            border-left: 4px solid #0071e3;
            margin: 0.8em 0;
            padding: 0.5em 1em;
            color: #6e6e73;
            background: #f5f5f7;
            border-radius: 0 4px 4px 0;
        }
        blockquote p {
            margin: 0.3em 0;
        }
        ul, ol {
            margin: 0.6em 0;
            padding-left: 2em;
        }
        ul ul, ul ol, ol ul, ol ol {
            margin: 0.3em 0;
        }
        li {
            margin: 0.3em 0;
        }
        li > p {
            margin: 0.2em 0;
        }
        a {
            color: #0066cc;
            text-decoration: none;
        }
        a:hover {
            text-decoration: underline;
        }
        hr {
            border: none;
            border-top: 2px solid #e5e5e7;
            margin: 2em 0;
        }
        table {
            border-collapse: collapse;
            margin: 1em 0;
            width: 100%;
            font-size: 0.9em;
        }
        th, td {
            border: 1px solid #d2d2d7;
            padding: 8px 12px;
            text-align: left;
        }
        th {
            background: #f5f5f7;
            font-weight: 600;
        }
        tr:nth-child(even) {
            background: #fafafa;
        }
        img {
            max-width: 100%;
            height: auto;
        }
        @media (prefers-color-scheme: dark) {
            body {
                color: #f5f5f7;
            }
            h1, h2 {
                border-bottom-color: #424245;
            }
            h6 {
                color: #98989d;
            }
            code {
                background: #2d2d2f;
            }
            pre {
                background: #2d2d2f;
                border-color: #424245;
            }
            blockquote {
                border-left-color: #0a84ff;
                background: #2d2d2f;
                color: #98989d;
            }
            th {
                background: #2d2d2f;
            }
            th, td {
                border-color: #424245;
            }
            tr:nth-child(even) {
                background: #1d1d1f;
            }
            a {
                color: #0a84ff;
            }
            hr {
                border-top-color: #424245;
            }
        }
        """

    private static func renderMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var html = ""
        var inCodeBlock = false
        var codeBlockLanguage = ""
        var listStack: [(type: String, indent: Int)] = []
        var inBlockquote = false
        var inTable = false
        var tableRows: [[String]] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            if !paragraphBuffer.isEmpty {
                let content = paragraphBuffer.joined(separator: " ")
                html += "<p>" + renderInline(content) + "</p>\n"
                paragraphBuffer = []
            }
        }

        func closeAllLists() {
            while !listStack.isEmpty {
                let list = listStack.removeLast()
                html += list.type == "ul" ? "</ul>\n" : "</ol>\n"
            }
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Code blocks
            if trimmed.hasPrefix("```") {
                flushParagraph()
                if inCodeBlock {
                    html += "</code></pre>\n"
                    inCodeBlock = false
                    codeBlockLanguage = ""
                } else {
                    codeBlockLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    html += "<pre><code>"
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                html += escapeHTML(line) + "\n"
                continue
            }

            // Empty line
            if trimmed.isEmpty {
                flushParagraph()
                if inBlockquote {
                    html += "</blockquote>\n"
                    inBlockquote = false
                }
                if inTable {
                    html += renderTable(tableRows)
                    tableRows = []
                    inTable = false
                }
                continue
            }

            // Table detection (line with |)
            if trimmed.contains("|") && trimmed.hasPrefix("|") {
                flushParagraph()
                closeAllLists()
                
                if !inTable {
                    inTable = true
                }
                
                let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .dropFirst()
                    .dropLast()
                    .map { String($0) }
                
                // Skip separator rows like |---|---|
                if cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) {
                    continue
                }
                
                tableRows.append(cells)
                continue
            }

            // Headings
            if trimmed.hasPrefix("# ") {
                flushParagraph()
                closeAllLists()
                html += "<h1>" + renderInline(String(trimmed.dropFirst(2))) + "</h1>\n"
                continue
            }
            if trimmed.hasPrefix("## ") {
                flushParagraph()
                closeAllLists()
                html += "<h2>" + renderInline(String(trimmed.dropFirst(3))) + "</h2>\n"
                continue
            }
            if trimmed.hasPrefix("### ") {
                flushParagraph()
                closeAllLists()
                html += "<h3>" + renderInline(String(trimmed.dropFirst(4))) + "</h3>\n"
                continue
            }
            if trimmed.hasPrefix("#### ") {
                flushParagraph()
                closeAllLists()
                html += "<h4>" + renderInline(String(trimmed.dropFirst(5))) + "</h4>\n"
                continue
            }
            if trimmed.hasPrefix("##### ") {
                flushParagraph()
                closeAllLists()
                html += "<h5>" + renderInline(String(trimmed.dropFirst(6))) + "</h5>\n"
                continue
            }
            if trimmed.hasPrefix("###### ") {
                flushParagraph()
                closeAllLists()
                html += "<h6>" + renderInline(String(trimmed.dropFirst(7))) + "</h6>\n"
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                closeAllLists()
                html += "<hr>\n"
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                closeAllLists()
                if !inBlockquote {
                    html += "<blockquote>\n"
                    inBlockquote = true
                }
                html += "<p>" + renderInline(String(trimmed.dropFirst(2))) + "</p>\n"
                continue
            }

            // List items with indentation tracking
            let listMatch = matchListItem(line)
            if let match = listMatch {
                flushParagraph()
                
                let currentIndent = match.indent
                let listType = match.type
                
                if listStack.isEmpty {
                    // First list item
                    html += listType == "ul" ? "<ul>\n" : "<ol>\n"
                    listStack.append((type: listType, indent: currentIndent))
                } else {
                    let lastList = listStack.last!
                    
                    if currentIndent > lastList.indent {
                        // Nested list - open new list
                        html += listType == "ul" ? "<ul>\n" : "<ol>\n"
                        listStack.append((type: listType, indent: currentIndent))
                    } else if currentIndent < lastList.indent {
                        // Dedent - close lists until we match
                        while !listStack.isEmpty && listStack.last!.indent > currentIndent {
                            let closed = listStack.removeLast()
                            html += closed.type == "ul" ? "</ul>\n" : "</ol>\n"
                        }
                        // If we closed all lists or the type changed, open new list
                        if listStack.isEmpty || listStack.last!.type != listType {
                            html += listType == "ul" ? "<ul>\n" : "<ol>\n"
                            listStack.append((type: listType, indent: currentIndent))
                        }
                    } else if lastList.type != listType {
                        // Same indent but different type - close and reopen
                        let closed = listStack.removeLast()
                        html += closed.type == "ul" ? "</ul>\n" : "</ol>\n"
                        html += listType == "ul" ? "<ul>\n" : "<ol>\n"
                        listStack.append((type: listType, indent: currentIndent))
                    }
                }
                
                html += "<li>" + renderInline(match.content)
                
                // Check if next line is a continuation (indented but not a list item)
                if index + 1 < lines.count {
                    let nextLine = lines[index + 1]
                    let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                    if !nextTrimmed.isEmpty && !nextTrimmed.hasPrefix("#") && !nextTrimmed.hasPrefix(">") &&
                       !nextTrimmed.hasPrefix("-") && !nextTrimmed.hasPrefix("*") &&
                       !nextTrimmed.hasPrefix("+") && !isOrderedListItem(nextTrimmed) &&
                       nextLine.hasPrefix(String(repeating: " ", count: match.indent + 2)) {
                        // This is a continuation, don't close the li yet
                        continue
                    }
                }
                
                html += "</li>\n"
                continue
            }

            // Regular paragraph text
            closeAllLists()
            if inBlockquote {
                html += "</blockquote>\n"
                inBlockquote = false
            }
            paragraphBuffer.append(trimmed)
        }

        // Close any open tags
        flushParagraph()
        closeAllLists()
        if inBlockquote {
            html += "</blockquote>\n"
        }
        if inTable {
            html += renderTable(tableRows)
        }
        if inCodeBlock {
            html += "</code></pre>\n"
        }

        return html
    }

    private struct ListItemMatch {
        let type: String
        let indent: Int
        let content: String
    }

    private static func matchListItem(_ line: String) -> ListItemMatch? {
        // Count leading spaces
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Unordered list: -, *, +
        if trimmed.hasPrefix("- ") {
            return ListItemMatch(type: "ul", indent: leadingSpaces, content: String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("* ") {
            return ListItemMatch(type: "ul", indent: leadingSpaces, content: String(trimmed.dropFirst(2)))
        }
        if trimmed.hasPrefix("+ ") {
            return ListItemMatch(type: "ul", indent: leadingSpaces, content: String(trimmed.dropFirst(2)))
        }

        // Ordered list: 1. 2. etc
        if let match = trimmed.range(of: #"^\d+\. "#, options: .regularExpression) {
            let content = String(trimmed[match.upperBound...])
            return ListItemMatch(type: "ol", indent: leadingSpaces, content: content)
        }

        return nil
    }

    private static func isOrderedListItem(_ text: String) -> Bool {
        return text.range(of: #"^\d+\. "#, options: .regularExpression) != nil
    }

    private static func renderTable(_ rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }

        var html = "<table>\n"

        // First row is header
        if let headerRow = rows.first {
            html += "<thead><tr>\n"
            for cell in headerRow {
                html += "<th>" + renderInline(cell) + "</th>\n"
            }
            html += "</tr></thead>\n"
        }

        // Remaining rows are body
        if rows.count > 1 {
            html += "<tbody>\n"
            for row in rows.dropFirst() {
                html += "<tr>\n"
                for cell in row {
                    html += "<td>" + renderInline(cell) + "</td>\n"
                }
                html += "</tr>\n"
            }
            html += "</tbody>\n"
        }

        html += "</table>\n"
        return html
    }

    private static func renderInline(_ text: String) -> String {
        var result = escapeHTML(text)

        result = result.replacingOccurrences(
            of: #"\*\*([^*]+)\*\*"#,
            with: "<strong>$1</strong>",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"__([^_]+)__"#,
            with: "<strong>$1</strong>",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: #"\*([^*]+)\*"#,
            with: "<em>$1</em>",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?<!\w)_([^_]+)_(?!\w)"#,
            with: "<em>$1</em>",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: #"~~([^~]+)~~"#,
            with: "<del>$1</del>",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: "<code>$1</code>",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: #"\[([^\]]+)\]\(([^\)]+)\)"#,
            with: "<a href=\"$2\">$1</a>",
            options: .regularExpression
        )

        return result
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
