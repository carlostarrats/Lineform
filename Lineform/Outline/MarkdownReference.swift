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

    /// Resolved against an explicit bundle so the tests can assert a non-English rendering.
    /// `String(localized:…locale:)` cannot do this — `locale:` formats interpolated values, it
    /// does not choose the .lproj. See `testLanguageResolutionComesFromTheBundleNotTheLocale`.
    static func sections(in bundle: Bundle = .main) -> [Section] {
        [
        Section(title: String(localized: "Markdown Basics", bundle: bundle), rows: [
            Row(syntax: "# Title", explanation: "Top-level heading. ⌘1 sets it, ⌘0 clears it."),
            Row(syntax: "## Section", explanation: "Smaller heading (more # = smaller). ⌘2 to ⌘6 set the level."),
            Row(syntax: "**bold**", explanation: "Bold."),
            Row(syntax: "_italic_", explanation: "Italic. *asterisks* work too; underscores inside a word are left alone."),
            Row(syntax: "- bullet", explanation: "Bulleted list. Return starts the next; Return on an empty one ends it."),
            Row(syntax: "1. item", explanation: "Numbered list. Return keeps the count going."),
            Row(syntax: "  - nested", explanation: "Indent two spaces to nest a list item."),
            Row(syntax: "- [ ] to do", explanation: "Task, not done. Return starts the next one."),
            Row(syntax: "- [x] done", explanation: "Task, done. Click to toggle."),
            Row(syntax: "> quote", explanation: "Blockquote. Return continues it."),
            Row(syntax: "> [!NOTE]", explanation: "Callout. Also TIP, IMPORTANT, WARNING, CAUTION. Add a title after the marker."),
            Row(syntax: "~~text~~", explanation: "Strikethrough."),
            Row(syntax: "`code`", explanation: "Inline code."),
            Row(syntax: "```swift", explanation: "Fenced code block. Highlighted in Read and Preview, with a copy button."),
            Row(syntax: "---", explanation: "Divider. At the very top of a file, --- opens front matter instead."),
            Row(syntax: "[text](url)", explanation: "Link."),
            Row(syntax: "![alt](url)", explanation: "Image. Local files show in Read and Preview; web addresses stay a placeholder."),
            Row(syntax: "| a | b |", explanation: "Header row, then |---|---|, then rows. Colons align. ⌃⌘T inserts, ⌃⌘R tidies."),
            // A keycap legend, so it stays "Tab" in every language — but it routes through the
            // catalog anyway, because a language that DOES relabel the key has nowhere else to say so.
            Row(syntax: String(localized: "Tab", bundle: bundle),
                explanation: "Inside a table, moves to the next cell. Shift-Tab goes back.",
                rendersSyntaxAsCode: false),
            Row(syntax: String(localized: "Block Spacing", bundle: bundle),
                explanation: "Adds space around blocks in Read and Preview.",
                rendersSyntaxAsCode: false),
        ]),
        Section(title: String(localized: "Diagrams", bundle: bundle), rows: [
            Row(syntax: "```mermaid", explanation: "Fenced mermaid block renders as a diagram in Read/Preview. Write shows source."),
            Row(syntax: "flowchart LR", explanation: "Also sequence, class, ER, state, xy, and pie. Other types show their source."),
        ]),
        Section(title: String(localized: "Math", bundle: bundle), rows: [
            Row(syntax: "$x^2 + y^2$", explanation: "Inline math."),
            Row(syntax: "$$…$$", explanation: "Centered equation block."),
            Row(syntax: "\\frac{a}{b}", explanation: "LaTeX supported: fractions, roots, Greek, sums, integrals."),
            Row(syntax: "it costs $5", explanation: "Plain dollar amounts stay as text."),
        ]),
        Section(title: String(localized: "Spelling", bundle: bundle), rows: [
            Row(syntax: String(localized: "Spelling", bundle: bundle),
                explanation: "Misspellings underline as you type. Nothing is autocorrected.",
                rendersSyntaxAsCode: false),
            Row(syntax: String(localized: "Skipped", bundle: bundle),
                explanation: "Code, math, front matter, and link addresses are never flagged.",
                rendersSyntaxAsCode: false),
        ]),
        Section(title: String(localized: "Search", bundle: bundle), rows: [
            // "Return" is a KEY NAME rendered as code — it stays verbatim.
            Row(syntax: "Return", explanation: "While searching, jumps to the next match; wraps around."),
        ]),
        ]
    }

    /// Every existing reader keeps working, so this refactor is not a churn event.
    static var sections: [Section] { sections() }
}
