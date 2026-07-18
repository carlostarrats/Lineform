import Foundation

/// The Markdown syntax reference shown in the sidebar's Info tab. Pure data so it
/// is testable and independent of the view. Copy is deliberately terse for the
/// narrow sidebar column (see MarkdownReferenceTests.testExplanationsStayConcise).
struct MarkdownReference {
    struct Row: Identifiable, Equatable {
        var syntax: String
        var explanation: String
        /// Most rows render `syntax` in a monospaced "code" style. A few (e.g.
        /// "Block Spacing") are a plain label, not literal syntax.
        var rendersSyntaxAsCode: Bool = true

        var id: String { syntax }

        /// VoiceOver reads a coherent phrase — explanation first, then the raw
        /// syntax — instead of spelling out Markdown punctuation on its own.
        var accessibilityLabel: String { "\(explanation) Syntax: \(syntax)" }
    }

    struct Section: Identifiable, Equatable {
        var title: String
        var rows: [Row]

        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "Markdown Basics", rows: [
            Row(syntax: "# Title", explanation: "Top-level heading."),
            Row(syntax: "## Section", explanation: "Smaller heading (more # = smaller)."),
            Row(syntax: "**bold**", explanation: "Bold."),
            Row(syntax: "_italic_", explanation: "Italic."),
            Row(syntax: "- bullet", explanation: "Bulleted list."),
            Row(syntax: "1. item", explanation: "Numbered list."),
            Row(syntax: "- [ ] to do", explanation: "Task, not done."),
            Row(syntax: "- [x] done", explanation: "Task, done. Click to toggle."),
            Row(syntax: "> quote", explanation: "Blockquote."),
            Row(syntax: "> [!NOTE]", explanation: "Callout. Also TIP, IMPORTANT, WARNING, CAUTION. Add a title after the marker."),
            Row(syntax: "~~text~~", explanation: "Strikethrough."),
            Row(syntax: "`code`", explanation: "Inline code."),
            Row(syntax: "---", explanation: "Divider."),
            Row(syntax: "[text](url)", explanation: "Link."),
            Row(syntax: "![alt](url)", explanation: "Image (shown as a placeholder)."),
            Row(syntax: "| a | b |", explanation: "Table: header row, then |---|---|, then rows. Colons set alignment."),
            Row(syntax: "Block Spacing", explanation: "Adds space around blocks in Read and Preview.", rendersSyntaxAsCode: false),
        ]),
        Section(title: "Diagrams", rows: [
            Row(syntax: "```mermaid", explanation: "Fenced mermaid block renders as a diagram in Read/Preview. Write shows source."),
        ]),
        Section(title: "Math", rows: [
            Row(syntax: "$x^2 + y^2$", explanation: "Inline math."),
            Row(syntax: "$$…$$", explanation: "Centered equation block."),
            Row(syntax: "\\frac{a}{b}", explanation: "LaTeX supported: fractions, roots, Greek, sums, integrals."),
            Row(syntax: "it costs $5", explanation: "Plain dollar amounts stay as text."),
        ]),
        Section(title: "Search", rows: [
            Row(syntax: "Return", explanation: "While searching, jumps to the next match; wraps around."),
        ]),
    ]
}
