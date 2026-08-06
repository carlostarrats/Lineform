import Foundation

/// The Markdown syntax reference shown in the sidebar's Info tab. Pure data so it
/// is testable and independent of the view. Copy is deliberately terse for the
/// narrow sidebar column — in EVERY language, since the column does not get wider
/// in German (see MarkdownReferenceTests.testExplanationsStayConciseInEveryLanguage).
struct MarkdownReference {
    struct Row: Identifiable, Equatable {
        /// A stable identity that does NOT depend on translated text. Left nil, it falls back to
        /// `syntax` — safe for the 24 literal-syntax rows, which are document content and never
        /// localize. The five LABEL rows (`rendersSyntaxAsCode == false`) localize their syntax and
        /// so must carry one explicitly, or their `ForEach` identity would be keyed on a translated
        /// string.
        /// `testEveryIdentityIsStableAcrossLanguages` asserts this in both directions.
        var identifier: String?
        var syntax: String
        var explanation: String
        /// Most rows render `syntax` in a monospaced "code" style. A few (e.g. "Block Spacing",
        /// and the `Tab`/`Return` keycaps) are a plain label, not literal syntax. This is the one
        /// predicate the whole row hangs off: a label row's `syntax` cell is app chrome, so it
        /// localizes and it offers no copy button; a code row's is document content, so it never
        /// localizes and it does.
        var rendersSyntaxAsCode: Bool = true

        var id: String { identifier ?? syntax }

        /// The string this row puts on the pasteboard, or nil when it has nothing to offer.
        ///
        /// Only literal Markdown is worth copying. A label row's cell is a translated UI word —
        /// copying `スペル` into a Markdown file means nothing there, and the button offering it is
        /// the bug, not the translation.
        ///
        /// This is an OPTIONAL rather than an `offersCopy: Bool` on purpose: the view unwraps it to
        /// build the copy button, so the button cannot be constructed for a row that has no
        /// copyable text. A `Bool` gate is one deletable `if` away from the bug; this one does not
        /// compile if the check is removed. Asserted by
        /// `MarkdownReferenceTests.testOnlyLiteralSyntaxRowsOfferCopy`.
        var copyableSyntax: String? { rendersSyntaxAsCode ? syntax : nil }

        /// What the copy affordance puts on the pasteboard and what it is CALLED, resolved together.
        ///
        /// The row is collapsed for assistive tech (`.accessibilityElement(children: .ignore)`),
        /// which suppresses the visual copy `Button` — so the affordance also exists as a row-level
        /// `.accessibilityActions` mirror. Both read this one value: the pasteboard text and the
        /// label are unwrapped in a single step, so a row cannot end up with one and not the other,
        /// and the button and its mirror cannot come to speak different words.
        ///
        /// nil for the five LABEL rows, exactly like `copyableSyntax` — they have no copy button and
        /// must have no copy action either.
        func copyAffordance(in bundle: Bundle = .main) -> CopyAffordance? {
            guard let syntax = copyableSyntax else { return nil }
            // Localized HERE, at the definition site: the label is a `String`, so `Button(label)` /
            // `Label(label, systemImage:)` take SwiftUI's verbatim overload and would ship English
            // for a literal built at the call site. `Copy %@` is an existing catalog key, shared
            // with the Read-mode code-block pill. It speaks the SYNTAX — never `Row.id`, which is
            // an internal slug for the five label rows.
            return CopyAffordance(text: syntax, label: String(localized: "Copy \(syntax)", bundle: bundle))
        }

        /// VoiceOver reads a coherent phrase — explanation first, then the raw syntax — instead
        /// of spelling out Markdown punctuation on its own. The CONNECTIVE localizes; the syntax
        /// never does. This is a method, not a property, because it must be resolvable against an
        /// explicit bundle for the per-language tests — and because a `String` property passed to
        /// `.accessibilityLabel(_:)` takes SwiftUI's verbatim overload, which shipped this phrase
        /// in English however complete the catalog was.
        func accessibilityLabel(in bundle: Bundle = .main) -> String {
            String(localized: "\(explanation) Syntax: \(syntax)", bundle: bundle)
        }
    }

    /// The copy affordance's two halves, produced only by `Row.copyAffordance()`.
    struct CopyAffordance: Equatable {
        /// The literal Markdown written to the pasteboard.
        let text: String
        /// The localized name spoken by VoiceOver and shown in the actions rotor.
        let label: String
    }

    struct Section: Identifiable, Equatable {
        /// Stable identity. Every section title localizes, so `id` can never be derived from it.
        var id: String
        var title: String
        var rows: [Row]
    }

    /// Resolved against an explicit bundle so the tests can assert a non-English rendering.
    /// `String(localized:…locale:)` cannot do this — `locale:` formats interpolated values, it
    /// does not choose the .lproj. See `testLanguageResolutionComesFromTheBundleNotTheLocale`.
    static func sections(in bundle: Bundle = .main) -> [Section] {
        [
        Section(id: "basics", title: String(localized: "Markdown Basics", bundle: bundle), rows: [
            Row(syntax: "# Title", explanation: String(localized: "Top-level heading. ⌘1 sets it, ⌘0 clears it.", bundle: bundle)),
            Row(syntax: "## Section", explanation: String(localized: "Smaller heading (more # = smaller). ⌘2 to ⌘6 set the level.", bundle: bundle)),
            Row(syntax: "**bold**", explanation: String(localized: "Bold.", bundle: bundle)),
            Row(syntax: "_italic_", explanation: String(localized: "Italic. *asterisks* work too; underscores inside a word are left alone.", bundle: bundle)),
            Row(syntax: "- bullet", explanation: String(localized: "Bulleted list. Return starts the next; Return on an empty one ends it.", bundle: bundle)),
            Row(syntax: "1. item", explanation: String(localized: "Numbered list. Return keeps the count going.", bundle: bundle)),
            Row(syntax: "  - nested", explanation: String(localized: "Indent two spaces to nest a list item.", bundle: bundle)),
            Row(syntax: "- [ ] to do", explanation: String(localized: "Task, not done. Return starts the next one.", bundle: bundle)),
            Row(syntax: "- [x] done", explanation: String(localized: "Task, done. Click to toggle.", bundle: bundle)),
            Row(syntax: "> quote", explanation: String(localized: "Blockquote. Return continues it.", bundle: bundle)),
            Row(syntax: "> [!NOTE]", explanation: String(localized: "Callout. Also TIP, IMPORTANT, WARNING, CAUTION. Add a title after the marker.", bundle: bundle)),
            Row(syntax: "~~text~~", explanation: String(localized: "Strikethrough.", bundle: bundle)),
            Row(syntax: "`code`", explanation: String(localized: "Inline code.", bundle: bundle)),
            Row(syntax: "```swift", explanation: String(localized: "Fenced code block. Highlighted in Read and Preview, with a copy button.", bundle: bundle)),
            Row(syntax: "---", explanation: String(localized: "Divider. At the very top of a file, --- opens front matter instead.", bundle: bundle)),
            Row(syntax: "[text](url)", explanation: String(localized: "Link.", bundle: bundle)),
            Row(syntax: "![alt](url)", explanation: String(localized: "Image. Local files show in Read and Preview; web addresses stay a placeholder.", bundle: bundle)),
            Row(syntax: "| a | b |", explanation: String(localized: "Header row, then |---|---|, then rows. Colons align. ⌃⌘T inserts, ⌃⌘R tidies.", bundle: bundle)),
            // A keycap legend: a LABEL row, by the rule on `rendersSyntaxAsCode` below. It stays
            // "Tab" in every language, but routes through the catalog anyway, because a language
            // that DOES relabel the key has nowhere else to say so. `Return` is the other one.
            Row(identifier: "tab", syntax: String(localized: "Tab", bundle: bundle),
                explanation: String(localized: "Inside a table, moves to the next cell. Shift-Tab goes back.", bundle: bundle),
                rendersSyntaxAsCode: false),
            Row(identifier: "block-spacing", syntax: String(localized: "Block Spacing", bundle: bundle),
                explanation: String(localized: "Adds space around blocks in Read and Preview.", bundle: bundle),
                rendersSyntaxAsCode: false),
        ]),
        Section(id: "diagrams", title: String(localized: "Diagrams", bundle: bundle), rows: [
            Row(syntax: "```mermaid", explanation: String(localized: "Fenced mermaid block renders as a diagram in Read/Preview. Write shows source.", bundle: bundle)),
            Row(syntax: "flowchart LR", explanation: String(localized: "Also sequence, class, ER, state, xy, and pie. Other types show their source.", bundle: bundle)),
        ]),
        Section(id: "math", title: String(localized: "Math", bundle: bundle), rows: [
            Row(syntax: "$x^2 + y^2$", explanation: String(localized: "Inline math.", bundle: bundle)),
            Row(syntax: "$$…$$", explanation: String(localized: "Centered equation block.", bundle: bundle)),
            Row(syntax: "\\frac{a}{b}", explanation: String(localized: "LaTeX supported: fractions, roots, Greek, sums, integrals.", bundle: bundle)),
            Row(syntax: "it costs $5", explanation: String(localized: "Plain dollar amounts stay as text.", bundle: bundle)),
        ]),
        Section(id: "spelling", title: String(localized: "Spelling", bundle: bundle), rows: [
            Row(identifier: "spelling", syntax: String(localized: "Spelling", bundle: bundle),
                explanation: String(localized: "Misspellings underline as you type. Nothing is autocorrected.", bundle: bundle),
                rendersSyntaxAsCode: false),
            Row(identifier: "skipped", syntax: String(localized: "Skipped", bundle: bundle),
                explanation: String(localized: "Code, math, front matter, and link addresses are never flagged.", bundle: bundle),
                rendersSyntaxAsCode: false),
        ]),
        Section(id: "search", title: String(localized: "Search", bundle: bundle), rows: [
            Row(identifier: "return", syntax: String(localized: "Return", bundle: bundle),
                explanation: String(localized: "While searching, jumps to the next match; wraps around.", bundle: bundle),
                rendersSyntaxAsCode: false),
        ]),
        ]
    }

    /// Every existing reader keeps working, so this refactor is not a churn event.
    static var sections: [Section] { sections() }
}
