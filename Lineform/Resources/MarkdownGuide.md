# Lineform Markdown Guide

Lineform edits real Markdown files. The app keeps the source visible so the file remains portable in Finder, iCloud Drive, Git, and other editors.

## Common Syntax

- `# Heading` — one to six `#` set the level. ⌘1 to ⌘6 set it from the keyboard, ⌘0 turns a
  heading back into ordinary text, and pressing a line's current level clears it.
- `**Bold**`
- `_Italic_` or `*Italic*` — underscores inside a word are left alone, so `make_test_file` and
  `__init__` stay exactly as written
- `` `Code` ``
- `~~Strikethrough~~`
- `- Bullet`
- `1. Numbered item`
- `- [ ] Task` and `- [x] Done`
- `> Quote`
- `[Link](https://example.com)`
- `![Image](picture.png)`
- `---` for a horizontal rule

Return after a bullet, numbered item, task checkbox, or quote starts the next one, and numbering
keeps counting. Return again on an empty marker ends the list instead of leaving a stray marker
behind.

Misspelled words are underlined as you write, using the spell checker built into macOS. Right-click
one for a suggestion, or to learn or ignore the word. Code, math, front matter, and link and image
addresses are left alone, so a file path or a variable name is never flagged. The whole feature is
switched off under Edit ▸ Spelling and Grammar.

## Blocks That Render in Read and Preview

- **Fenced code**, with the language after the opening fence:

      ```swift
      let greeting = "Hello"
      ```

- **Tables**, using pipes and a divider row:

      | Column | Column |
      |---|---|
      | Cell   | Cell   |

  Insert Table (⌃⌘T) starts one, Tab moves between cells, and Reformat Table (⌃⌘R) pads the
  pipes so the columns line up in the file. Alignment is set by colons in the divider row —
  `:---` left, `---:` right, `:---:` centred — and Reformat keeps whichever you wrote.

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
