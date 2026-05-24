# Lineform

Lineform is a native macOS Markdown editor for calm writing, real files, and readable long-form text.

It edits ordinary `.md`, `.markdown`, and `.txt` files directly, with a minimal interface built around native macOS behavior. The app is local-first: documents stay wherever you save them, and the editor does not add accounts, analytics, document upload, or external AI services.

## Features

- Native macOS document app built with Swift, SwiftUI, AppKit, and TextKit.
- Real Markdown files that remain portable across Finder, iCloud Drive, Git, and other editors.
- Write, Read, and Split modes for drafting, reading, and side-by-side review.
- Markdown outline navigation from document headings.
- Reading controls for type size, line height, paragraph spacing, margins, column width, themes, focus, ruler, and caret width.
- Apple Books-style reader themes, with accessibility adjustments layered on top.
- Native Writing Tools and Apple Intelligence-backed editing actions when available.
- Plain UTF-8 Markdown and text file handling.
- App Sandbox entitlement with user-selected file read/write access.

## Requirements

- macOS 15.0 or later
- Xcode with macOS SDK support
- Swift 6

## Build

Open `Lineform.xcodeproj` in Xcode and run the `Lineform` scheme.

From Terminal:

```sh
xcodebuild build \
  -project Lineform.xcodeproj \
  -scheme Lineform \
  -destination 'platform=macOS'
```

## Test

```sh
xcodebuild test \
  -project Lineform.xcodeproj \
  -scheme Lineform \
  -destination 'platform=macOS'
```

## Privacy

Lineform is local-first.

- Documents are ordinary Markdown or text files.
- Files stay local unless you put them in iCloud Drive or another synced folder.
- There is no account system.
- There is no analytics collection by default.
- There is no document upload.
- Intelligent editing uses Apple system capabilities where available.
- The editor remains fully usable when intelligent editing is unavailable.

## Project Status

Lineform is early software. The current app version is `0.1.0`.

## License

No open-source license has been selected yet. Until a license is added, all rights are reserved.
