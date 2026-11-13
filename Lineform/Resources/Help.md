# Lineform Help

Lineform is a free native Mac Markdown editor focused on calm writing, readable typography, local files, and accessible reading controls.

## Core Tasks

- Open and save `.md`, `.markdown`, and `.txt` files. File ▸ Open replaces a pristine untitled tab; if the current tab contains work or belongs to a file, the selected document opens as another tab in the same window.
- Make Lineform the default app for `.md` and `.markdown` files when the one-time invitation appears, or at any time from Settings. Choosing Not Now dismisses only the invitation; the Settings action remains available.
- Switch between Write, Read, and Preview modes. Press ⌘E to toggle Write and Read.
- Open several documents at once in tabs (⌘T for a new tab, ⌘[ and ⌘] to move between them).
- Toggle the outline when headings are useful.
- Search the document from the toolbar with match highlighting; press Return to jump to the next match. Find & Replace, search across every file in the workspace, and ⌘K to jump to a file by name.
- Format Markdown headings, emphasis, inline code, lists, and links.
- Set a heading level with ⌘1 through ⌘6, and ⌘0 to turn a heading back into ordinary text. Pressing a line's current level clears it. Levels 3 to 6 also live under Format ▸ Heading.
- Keep lists going as you type: Return after a bullet, numbered item, task checkbox, or blockquote starts the next one. Press Return again on an empty marker to end the list.
- Write tables without counting pipes: Format ▸ Insert Table (⌃⌘T) starts one, Tab and Shift-Tab move between cells, and Tab in the last cell adds a row. Format ▸ Reformat Table (⌃⌘R) lines the columns up in the source.
- See misspellings underlined as you write, using the spell checker built into macOS. Right-click a word for a suggestion, or to learn or ignore it. Code, math, front matter, and link and image addresses are skipped, and nothing is autocorrected. Turn it off under Edit ▸ Spelling and Grammar.
- Convert between Markdown and plain text.
- Save As keeps your Markdown file; Export As writes a copy as HTML, PDF, Styled PDF, or Rich Text (.rtf). Print with ⌘P.
- Exported HTML keeps your image and link paths exactly as you wrote them, so a page saved beside your Markdown file still finds its images.
- Use Reading Experience to adjust type, spacing, themes, reading ruler, and typewriter mode. Each reading style keeps your own adjustments when you switch away and back; Reset to Default resets only the style you are on.
- Keep versions of a passage: select it, right-click, and choose Add to History. The sidebar opens on History with that passage focused. Click Add Replacement below its versions, type another word, phrase, or sentence, and press Return: it becomes the passage's current version and appears in your text (Esc closes the field without adding anything). A passage you leave without adding a replacement is not kept — there was nothing to compare. Later, click the History tab in the sidebar, or choose View ▸ History (⌘Y), to see the passages with history. Click one to focus it — the rest of the text fades back and a small counter such as 2/3 shows which version you are on — then use ← and → or the sidebar to switch versions — the text you leave showing is your document, and one ⌘Z afterwards puts it back. Click Exit at the top of the History sidebar, or press Esc, to return to writing; the sidebar goes back to the tab you were on. History is kept on your Mac, never inside the file; versions untouched for 30 days are removed, and Settings ▸ Clear History removes everything. An untitled document keeps its history only while it stays the document you are working in; save it to keep its history.
- Have a document read aloud from Edit ▸ Speech.
- Use your own AI, if you want one. Lineform has no AI built in. Choose Lineform ▸ Connect Your AI…, pick Claude, ChatGPT, Google, or Other (any OpenAI-compatible server, including a model running on your Mac), and paste your API key (each page says how to create one; choose Standard or Higher quality for the model — you can change it any time) — API keys are billed per use by the provider, separately from a Claude, ChatGPT, or Gemini subscription. Then, in Write mode, select some text and right-click: Rewrite ▸ Trim, Cut in half, or Rewrite; Proofread; or Mark ▸ Weakest sentences or Long sentences. Whatever you selected comes back as one suggestion over your text: the original struck through and dimmed, the new wording highlighted after it. Accept or reject it on the card, or press Return to accept and Esc to reject; typing ends the review too. Nothing changes in your file until you accept a change, each accepted change is one ⌘Z, and accepted changes are kept in History (the first time you accept one, the sidebar opens on History to show it). Mark only highlights sentences; Esc clears them. Markdown structure — code, math, front matter, links' addresses, markers — is never sent and never changed, so the AI can't break your formatting (and can't fix a typo that touches `*`, `_`, or `~`). The AI items appear only while an AI is connected.
- Use native macOS Writing Tools on selected text where the system provides them.
- Preview Markdown files straight from Finder with Quick Look.

## What Read and Preview Render

- Headings, emphasis, lists, blockquotes, and horizontal rules.
- Tables, and task checkboxes you can click to tick off.
- Fenced code blocks with syntax highlighting for common languages, and a copy button on hover.
- Callouts written as `> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`, or `> [!CAUTION]`.
- Mermaid diagrams and LaTeX math, drawn natively.
- Images stored on your Mac. Images at a web address are never downloaded — they always show a placeholder.

## Local-First Privacy

Documents stay wherever the user saves them. Lineform does not add accounts, analytics, or document upload. If you connect your own AI, only the prose of a selection you act on is sent (for Mark, the sentences your selection touches), only when you choose an action, directly to the provider you connected, under your account and their terms; your key is kept in your Mac's Keychain. Lineform ▸ Connect Your AI… ▸ Disconnect deletes the key. History is stored in Lineform's own folder on your Mac (`~/Library/Application Support/Lineform/History`, inside Lineform's app container), never in your files.

## Credits

Lineform bundles Atkinson Hyperlegible from Braille Institute of America, Inc. and OpenDyslexic from Abbie Gonzalez under the SIL Open Font License 1.1.
