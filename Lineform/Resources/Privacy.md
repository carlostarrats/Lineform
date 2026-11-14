# Privacy

Lineform is local-first.

- Documents are ordinary Markdown or text files.
- Files stay local unless the user stores them in iCloud Drive or another synced folder.
- There is no account system.
- There is no analytics collection by default.
- There is no document upload. Lineform's developer never receives your documents or anything you write.
- AI is never built in and is off until you connect one. If you choose Lineform ▸ Connect Your AI… and connect Claude (Anthropic), ChatGPT (OpenAI), Google, or another OpenAI-compatible server, here is exactly what happens:
  - **Nothing is sent when you connect.** The Connect button names who will receive your text. Connecting stores your key and makes no request — not even to check the key.
  - **Only what you choose, only when you choose it.** Text is sent only when you select a passage and pick an AI action (Rewrite, Proofread, or Find) from the right-click menu. Only the prose of that selection is sent; for Find, that is the sentences your selection touches, each one whole, and no other sentence. Markdown structure is never sent: not code blocks or inline code, math, front matter, links' web addresses, image paths, HTML, tables' separators, list and heading markers, or emphasis characters. The rest of your document and its file name are never sent.
  - **Straight to the provider you chose.** The text goes directly from your Mac to that provider, under your own account and that provider's terms and privacy policy. It never passes through Lineform or its developer. With a model on your own Mac (for example Ollama or LM Studio via Other), it never leaves your Mac.
  - **Your key stays in your Keychain.** Your API key is stored only in your Mac's Keychain, never in a file or in Lineform's settings, and is not synced. It is sent only to the provider it belongs to, with an action you chose.
  - **Nothing changes until you accept it.** Suggestions are shown for review; your file changes only when you accept a change.
  - **To stop,** open Lineform ▸ Connect Your AI… and click Disconnect. That deletes the key from your Keychain. Connecting a different provider also deletes the previous provider's key.
- Images written as a web address are never downloaded. Only image files already on your Mac are displayed; a remote image always stays a placeholder.
- History (the versions you keep with Replace With…) is stored only on your Mac, in Lineform's own folder: `~/Library/Application Support/Lineform/History`, inside the app's sandbox container. It is never written into your Markdown file and never sent anywhere. Versions untouched for 30 days are removed automatically, history for a deleted file is removed, and Settings ▸ Clear History removes all of it at once without changing your files.
- Reading a document aloud uses the speech voices built into macOS. Nothing is sent anywhere.
- Spell checking uses the checker built into macOS. There is no bundled dictionary and no online lookup — your words are checked on your Mac, and nothing is sent anywhere. Words you teach it are stored by macOS in your own user dictionary.
- Lineform checks once a day for announcements — occasional news such as a new version. It reads a small public file from the Lineform website and nothing else: no account, no identifier, no information about you, your Mac, or your documents is sent, and nothing about the check is stored. You can turn it off in Settings, and when it is off Lineform makes no network request at all.
- If a Mermaid diagram fails to render, a local, anonymous diagram log is kept on your device (the diagram source, the error, and the app version — no file names or paths). It never leaves your Mac. There is no way to send it: the only time Lineform sends any of your text anywhere is an AI action you choose, as described above.
