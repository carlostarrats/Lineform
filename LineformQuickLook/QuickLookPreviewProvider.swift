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
        }
        h1, h2, h3, h4, h5, h6 {
            margin-top: 1.2em;
            margin-bottom: 0.4em;
            font-weight: 600;
            line-height: 1.3;
        }
        h1 { font-size: 1.8em; }
        h2 { font-size: 1.4em; }
        h3 { font-size: 1.2em; }
        h4 { font-size: 1.1em; }
        h5 { font-size: 1em; }
        h6 { font-size: 0.9em; }
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
            padding: 10px;
            border-radius: 5px;
            overflow-x: auto;
            margin: 0.8em 0;
        }
        pre code {
            background: none;
            padding: 0;
        }
        blockquote {
            border-left: 3px solid #d2d2d7;
            margin: 0.8em 0;
            padding-left: 1em;
            color: #6e6e73;
        }
        ul, ol {
            margin: 0.6em 0;
            padding-left: 1.8em;
        }
        li {
            margin: 0.2em 0;
        }
        a {
            color: #0066cc;
            text-decoration: none;
        }
        hr {
            border: none;
            border-top: 1px solid #d2d2d7;
            margin: 1.5em 0;
        }
        table {
            border-collapse: collapse;
            margin: 0.8em 0;
            width: 100%;
        }
        th, td {
            border: 1px solid #d2d2d7;
            padding: 6px 10px;
            text-align: left;
        }
        th {
            background: #f5f5f7;
            font-weight: 600;
        }
        """

    private static func renderMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var html = ""
        var inCodeBlock = false
        var inList = false
        var listType = ""
        var inBlockquote = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    html += "</code></pre>\n"
                    inCodeBlock = false
                } else {
                    html += "<pre><code>"
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                html += escapeHTML(line) + "\n"
                continue
            }

            if trimmed.isEmpty {
                if inList {
                    html += listType == "ul" ? "</ul>\n" : "</ol>\n"
                    inList = false
                }
                if inBlockquote {
                    html += "</blockquote>\n"
                    inBlockquote = false
                }
                continue
            }

            if trimmed.hasPrefix("# ") {
                html += "<h1>" + renderInline(String(trimmed.dropFirst(2))) + "</h1>\n"
                continue
            }
            if trimmed.hasPrefix("## ") {
                html += "<h2>" + renderInline(String(trimmed.dropFirst(3))) + "</h2>\n"
                continue
            }
            if trimmed.hasPrefix("### ") {
                html += "<h3>" + renderInline(String(trimmed.dropFirst(4))) + "</h3>\n"
                continue
            }
            if trimmed.hasPrefix("#### ") {
                html += "<h4>" + renderInline(String(trimmed.dropFirst(5))) + "</h4>\n"
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                html += "<hr>\n"
                continue
            }

            if trimmed.hasPrefix("> ") {
                if !inBlockquote {
                    html += "<blockquote>\n"
                    inBlockquote = true
                }
                html += "<p>" + renderInline(String(trimmed.dropFirst(2))) + "</p>\n"
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if !inList || listType != "ul" {
                    if inList {
                        html += listType == "ul" ? "</ul>\n" : "</ol>\n"
                    }
                    html += "<ul>\n"
                    inList = true
                    listType = "ul"
                }
                html += "<li>" + renderInline(String(trimmed.dropFirst(2))) + "</li>\n"
                continue
            }

            if let match = trimmed.range(of: #"^\d+\. "#, options: .regularExpression) {
                if !inList || listType != "ol" {
                    if inList {
                        html += listType == "ul" ? "</ul>\n" : "</ol>\n"
                    }
                    html += "<ol>\n"
                    inList = true
                    listType = "ol"
                }
                let content = String(trimmed[match.upperBound...])
                html += "<li>" + renderInline(content) + "</li>\n"
                continue
            }

            if inList {
                html += listType == "ul" ? "</ul>\n" : "</ol>\n"
                inList = false
            }
            if inBlockquote {
                html += "</blockquote>\n"
                inBlockquote = false
            }
            html += "<p>" + renderInline(trimmed) + "</p>\n"
        }

        if inCodeBlock {
            html += "</code></pre>\n"
        }
        if inList {
            html += listType == "ul" ? "</ul>\n" : "</ol>\n"
        }
        if inBlockquote {
            html += "</blockquote>\n"
        }

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
