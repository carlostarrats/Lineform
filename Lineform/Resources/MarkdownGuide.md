# Lineform Markdown Guide

Lineform edits real Markdown files. The app keeps the source visible so the file remains portable in Finder, iCloud Drive, Git, and other editors.

## Common Syntax

- `# Heading`
- `**Bold**`
- `_Italic_`
- `` `Code` ``
- `~~Strikethrough~~`
- `- Bullet`
- `1. Numbered item`
- `- [ ] Task` and `- [x] Done`
- `> Quote`
- `[Link](https://example.com)`
- `![Image](picture.png)`
- `---` for a horizontal rule

## Blocks That Render in Read and Preview

- **Fenced code**, with the language after the opening fence:

      ```swift
      let greeting = "Hello"
      ```

- **Tables**, using pipes and a divider row:

      | Column | Column |
      |---|---|
      | Cell   | Cell   |

- **Callouts**, written as a quote with a type marker:

      > [!NOTE]
      > Useful context while reading.

  The types are `NOTE`, `TIP`, `IMPORTANT`, `WARNING`, and `CAUTION`. In any other editor they degrade to an ordinary quote.

- **Math**, inline with `$E = mc^2$` and as a block between `$$` lines.

- **Diagrams**, in a fenced block marked `mermaid`.

## Writing Tips

- Use headings to shape the document outline.
- Keep paragraphs short when reading comfort matters.
- Use fenced code blocks for code that should not be rewritten by editing tools.
- Put an image on a line of its own — that is what makes it render.
- Use Reading Experience controls when line length, contrast, current-line guidance, or cursor centering needs to change.
