# Privacy

Lineform is local-first.

- Documents are ordinary Markdown or text files.
- Files stay local unless the user stores them in iCloud Drive or another synced folder.
- There is no account system.
- There is no analytics collection by default.
- There is no document upload.
- Images written as a web address are never downloaded. Only image files already on your Mac are displayed; a remote image always stays a placeholder.
- Reading a document aloud uses the speech voices built into macOS. Nothing is sent anywhere.
- Spell checking uses the checker built into macOS. There is no bundled dictionary and no online lookup — your words are checked on your Mac, and nothing is sent anywhere. Words you teach it are stored by macOS in your own user dictionary.
- Text piped into the `lineform` command line tool is written to a local file in `~/Library/Application Support/Lineform/Piped/` and opened as a normal document. These piped files stay on your device and are automatically deleted after about 7 days of inactivity.
- Lineform checks once a day for announcements — occasional news such as a new version. It reads a small public file from the Lineform website and nothing else: no account, no identifier, no information about you, your Mac, or your documents is sent, and nothing about the check is stored. You can turn it off in Settings, and when it is off Lineform makes no network request at all.
- If a Mermaid diagram fails to render, a local, anonymous diagram log is kept on your device (the diagram source, the error, and the app version — no file names or paths). It never leaves your Mac unless you choose to send a report: a failed diagram offers a quiet "Report this" link, and only if you confirm does Lineform send exactly the diagram source, the error message, and the app version to the developer. Nothing is ever sent automatically.
