# HTML Export + Export As Submenu — Design

**Date:** 2026-07-26
**Backlog item:** 4 of `docs/research/2026-07-25-feature-backlog.md`
**Supersedes:** the 2026-07-18 decision that folded all export targets into the Save As Format
picker (`docs/architecture/export-and-print.md`). That picker goes away; export moves back to its
own menu.

## Goal

Export the open document as a real `.html` file, and separate exporting from saving: **Save As**
retargets your Markdown file, **Export As** writes a copy in another format.

## Menu

```
File
  Save                ⌘S
  Save As…           ⇧⌘S     → NSSavePanel, .md, no Format popup
  Export As          ▸ HTML…
                       PDF…
                       Styled PDF…
                       Rich Text (.rtf)…
```

`Export As` is a `Menu` inside the existing `CommandGroup(replacing: .saveItem)`, directly below
Save As. Each row posts the window-scoped `exportDocument` notification carrying its format — the
pattern `saveAsDocument` and `printDocument` already use. No keyboard shortcuts on the export
rows.

Save As loses its Format popup entirely and always drives the backing document's
`save(to:ofType:for:.saveAsOperation)`, unchanged from today. The ⇧⌘S → PDF path is deliberately
broken rather than shimmed; a transitional duplicate would mean maintaining two paths forever.

### Icons

New entries in `MainMenuIconDecorator`'s title-keyed map:

| Row | Symbol |
|---|---|
| Export As | `square.and.arrow.up` |
| HTML… | `chevron.left.forwardslash.chevron.right` |
| PDF… | `doc.plaintext` |
| Styled PDF… | `doc.richtext` |
| Rich Text (.rtf)… | `textformat` |

`square.and.arrow.up` pairs against Save's `square.and.arrow.down` — bytes land in your file
vs. a copy leaves.

**Unverified:** the decorator hooks `NSMenu.didAddItemNotification` on the menu that posts it, and
walking `NSApp.mainMenu` instead is a known-broken approach (CLAUDE.md). A submenu is its own
`NSMenu` and should post its own notifications, but this must be confirmed in a real build — map
entries existing is not evidence the icons render.

## Panel

`exportDocument(format:)` presents one `NSSavePanel` with **no Format popup** — the menu row
already chose. The accessory is only the Paper Size row, and only for PDF / Styled PDF, defaulting
to `defaultExportPaperSize` exactly as today. HTML and RTF get a bare panel. Default filename is
the document's base name plus the format extension.

Write paths are otherwise unchanged: `writePDFAtomically` for both PDFs, `rtfData` for RTF, a new
HTML path (`Data.write(.atomic)`). Each format keeps its own SwiftUI `.alert` state;
`htmlExportErrorFileName` joins the existing three and is never cross-wired.

The `SaveAsConflict` cross-tab guard stays on the **Markdown path only**. It exists because
another tab's stale snapshot can autosave back over a `.md` just written; `.html`, `.pdf`, and
`.rtf` are not openable document types, so no tab can hold one.

## HTML renderer

New pure file `Lineform/Preview/MarkdownHTMLRenderer.swift`, alongside the other emitters over the
same block model. It walks the existing `[MarkdownBlock]` from `MarkdownBlockGrouping` — the seam
that file's own doc comment describes — and sits *parallel* to the `NSAttributedString` renderer,
not on top of it. `String` in, `String` out, so it lives in the default test plan with no window
and no `NSPrintOperation`.

### The one rule

**Output is one-to-one with what the user wrote.** Image paths, link URLs, and remote `http(s)`
URLs are emitted exactly as authored — never resolved, rewritten, inlined, or replaced. Someone
exporting HTML is technical and their intent is what they typed; if they keep the `.html` beside
the `.md`, their relative paths keep working, locally and on a web server. Self-contained output
is what PDF is for.

This reverses the backlog's `data:` URI constraint, which was written for a paste-into-email case
that has since been cut from scope.

### Block mapping

| Block | HTML |
|---|---|
| heading | `<h1>`–`<h6>` |
| paragraph | `<p>` |
| list | `<ul>` / `<ol>` / `<li>`; task items as disabled `<input type="checkbox">` |
| blockquote | `<blockquote>` |
| callout | `<blockquote class="callout callout-note">` (kind lowercased) |
| table | `<table>`/`<thead>`/`<tbody>` with per-column `text-align` |
| fenced code | `<pre><code class="language-x">`, escaped, **no color spans** |
| horizontal rule | `<hr>` |
| image | `<img src="…">` with the path exactly as written |

Inline bold, italic, strikethrough, code, and links reuse the same token scan the preview uses.
`&`, `<`, `>`, and `"` are escaped in both text and attribute values.

**Math and mermaid are the only embedded bytes.** They have no user-authored path — the app
generates the picture from the `$$…$$` or ` ```mermaid ` source at export time — so they emit as
`data:` URI `<img>` with the original source in `alt`. Nothing the user wrote is rewritten there;
without embedding they could not appear at all.

No syntax-highlight colors: the class is the portable convention every destination reads, inline
colors get overridden anyway, and they would bake one theme's ink into a document that outlives
it.

### Document shell

`<!doctype html>`, `<meta charset="utf-8">`, `<title>` from the filename, and one small embedded
`<style>` — neutral light page, system font stack, readable measure. No reading theme, no dark
page, no external resources, matching the existing "a PDF is always the white page" rule.

### Image provider

The emitter takes an **injected closure** for math/mermaid image bytes: the real path renders, the
tests pass a stub. Calling the AppKit renderers directly would move the whole HTML suite into the
hosted plan, which is slower and reserved for things that genuinely need a window.

## Testing

`MarkdownHTMLRendererTests`, default plan: one case per block type; `&<>"` escaping in text and
attributes; **paths emitted verbatim** (relative, absolute, and remote, none rewritten); math and
mermaid embedding via the stub provider; task checkbox state; table alignment; code-fence language
class; and no unescaped `<` surviving from source text.

Existing Save As tests update for the Markdown-only panel. Icon rendering on the submenu is
verified by hand in a real build, not by a test.

## Not doing

Copy as HTML (Read mode is already selectable — ⌘C pastes formatted text into Gmail, Word, and
Pages today, so the clipboard case is largely covered). No Export As shortcut, no persisted
last-used format, no syntax-highlight colors, no dark or themed HTML, no second raw-source HTML
variant — a `<pre>` of escaped `#` markers is strictly worse than the `.md` it came from.
