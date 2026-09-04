# Lineform



## What It Does

- Write Markdown and plain text in a native macOS document app.
- Keep work saved with native macOS autosave for existing files.
- Start in a normal untitled editor window when no document is open. File ▸ Open replaces that tab while it is still pristine, or adds the selected file as a tab beside work already in progress.
- Optionally make Lineform the default app for `.md` and `.markdown` files from its one-time invitation or Settings.
- See external edits automatically: an open document reloads when its file changes on disk, so what your tools (or agents) write shows up without reopening.
- Browse your writing in the Files sidebar — your Lineform iCloud Drive folder and any workspace folder you choose — and switch files in the same window, Apple Notes-style.
- Optionally show hidden folders in the Files sidebar (like `.claude` or `.github`) to reach Markdown that lives alongside your code.
- See Mermaid diagrams rendered natively in Read and Preview modes (Write mode shows the source); a malformed or very large diagram falls back to a labeled source block rather than blocking the window.
- Write LaTeX math inline with `$…$` and as centered blocks with `$$…$$`, rendered natively in Read and Preview modes (Write mode shows the source); invalid math falls back to its source. Ordinary dollar amounts like "$5" are left untouched.
- Switch between Write, Read, and Preview modes.
- Preview Markdown beside the source in split view.
- Navigate documents from their headings.
- Search inside the current file with match navigation, across every file in the workspace, or jump to a file by name with ⌘K.
- Format headings, lists, links, emphasis, and inline code — set a heading level with ⌘1 to ⌘6 (⌘0 for body text), and keep bullets, numbered items, checkboxes, and quotes going with Return.
- Write tables without counting pipes: Insert Table (⌃⌘T), Tab between cells, and Reformat Table (⌃⌘R) to line the columns up in the source.
- Have a document read aloud from **Edit ▸ Speech**, which skips code, math, and diagrams.
- See misspellings underlined as you write, checked by macOS on your Mac — code, math, front matter, and link addresses are skipped, and nothing is autocorrected.
- Use Apple's native Writing Tools in the editor, with Markdown structure (fenced code, front matter) protected from rewrites.
- Save Markdown or plain text, print (⌘P), or export a copy as HTML, PDF, Styled PDF, or Rich Text — headings, tables, math, and diagrams included, on a clean white page at a standard document size. Exported HTML keeps your image and link paths exactly as you wrote them.
- Preview Markdown files in Finder with Space, formatted rather than shown as raw text.
- Adjust reading font, size, line height, spacing, width, theme, reading ruler, and typewriter mode — including the bundled accessibility fonts Atkinson Hyperlegible and OpenDyslexic.

## Privacy

Lineform is local-first.

- No account system.
- No analytics collection by default.
- No document upload.
- Documents stay wherever you save them.
- Files remain ordinary Markdown or text files.

Lineform contacts the network in exactly one case: a once-a-day read of a small public announcements file on the Lineform website, which sends no identifier and can be turned off in Settings. **Your document content never leaves your device.**

Full [Privacy](https://lineform.app/privacy) and [Terms of Use](https://lineform.app/terms) are published online and linked from the app's menu.

## Support

For questions, bug reports, feature requests, or other help with Lineform, please use the
[Lineform Issues page](https://github.com/carlostarrats/Lineform/issues). Include your macOS
version, Lineform version, and the steps that reproduce a problem; never attach a document that
contains private writing unless you are comfortable sharing it publicly.

## Agent workflow

Lineform is a good place to read and review what your coding agent writes. An optional
[Claude Code](https://code.claude.com) hook can open every Markdown file your agent writes or
edits; the copy-paste recipe is in [`docs/agent-hooks.md`](docs/agent-hooks.md), verified against
Claude Code v2.1.198. Combined with live reload, the file refreshes in place as the agent works.

## Updates

Lineform is distributed through the Mac App Store, which handles updates. The app ships no
self-update mechanism of its own.

## Requirements

- macOS 14.0 or later
- Apple Silicon or Intel Mac (universal binary)

## About

Lineform is built as a native macOS document app with SwiftUI, AppKit, and TextKit. V1.0 was the first public version; the current release is 1.6.1.

## Credits

Lineform renders Mermaid diagrams with [BeautifulMermaid](https://github.com/lukilabs/beautiful-mermaid-swift) (MIT), a native Swift renderer.

Lineform renders LaTeX math with [SwiftMath](https://github.com/mgriebling/SwiftMath) (MIT), a native Swift renderer whose bundled math fonts are under the SIL Open Font License and the GUST Font License.

Lineform bundles accessibility-focused reader fonts under the SIL Open Font License 1.1:

- Atkinson Hyperlegible, copyright 2020 Braille Institute of America, Inc.
- OpenDyslexic, copyright Abbie Gonzalez, with Reserved Font Name OpenDyslexic.

## Build From Source

Open `Lineform.xcodeproj` in Xcode and run the `Lineform` scheme.

From Terminal:

```sh
xcodebuild build \
  -project Lineform.xcodeproj \
  -scheme Lineform \
  -destination 'platform=macOS'
```

Run the deterministic test suite serially:

```sh
xcodebuild test \
  -project Lineform.xcodeproj \
  -scheme Lineform \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO
```

Release notes for maintainers live in [docs/release/app-store-release.md](docs/release/app-store-release.md).

## License

Lineform is source-available under the PolyForm Shield License 1.0.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
