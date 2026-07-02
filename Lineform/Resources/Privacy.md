# Privacy

Lineform is local-first.

- Documents are ordinary Markdown or text files.
- Files stay local unless the user stores them in iCloud Drive or another synced folder.
- There is no account system.
- There is no analytics collection by default.
- There is no document upload.
- Text piped into the `lineform` command line tool is written to a local file in `~/Library/Application Support/Lineform/Piped/` and opened as a normal document. These piped files stay on your device and are automatically deleted after about 7 days of inactivity.
- If a Mermaid diagram fails to render, a local, anonymous diagram log is kept on your device (the diagram source, the error, and the app version — no file names or paths). It never leaves your Mac unless you choose to send a report: a failed diagram offers a quiet "Report this" link, and only if you confirm does Lineform send exactly the diagram source, the error message, and the app version to the developer. Nothing is ever sent automatically.
