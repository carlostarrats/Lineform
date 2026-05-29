# Lineform

Lineform is a native macOS Markdown editor for calm writing, real local files, and readable long-form text.

It is built around ordinary UTF-8 Markdown and text files, so documents stay portable across Finder, iCloud Drive, Git, and other editors.

## Features

- Native macOS document app built with SwiftUI, AppKit, and TextKit.
- Real Markdown and plain text file handling.
- Write, Read, and Preview modes for drafting, reading, and side-by-side review.
- Markdown outline navigation from document headings.
- Native toolbar search with match highlighting and next/previous navigation.
- Markdown formatting commands for headings, emphasis, inline code, lists, and links.
- Format conversion between Markdown and plain text.
- Save and Save As support for Markdown, plain text, and PDF export.
- Reading Experience controls for font, size, line height, paragraph spacing, column width, themes, and reading aids.
- Reader themes and accessibility-focused font options, including Atkinson Hyperlegible and OpenDyslexic.
- Selected-text AI instruction flow when Apple Intelligence is available: select text, toggle AI in Write mode, describe the edit, then review before accepting.
- Defensive intelligent editing validation to avoid prompt artifacts, stale selections, empty suggestions, and unsafe Markdown changes.
- Local-first privacy with no account system, analytics, or document upload.

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

Run the deterministic test suite serially:

```sh
xcodebuild test \
  -project Lineform.xcodeproj \
  -scheme Lineform \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO
```

Run live Apple Intelligence evals only on machines where Apple Intelligence is available:

```sh
touch /private/tmp/lineform-run-live-intelligence-evals
xcodebuild test \
  -project Lineform.xcodeproj \
  -scheme Lineform \
  -destination 'platform=macOS' \
  -only-testing:LineformTests/IntelligentEditingEvaluationTests/testLiveFoundationModelsEvalIsOptIn \
  -only-testing:LineformTests/IntelligentEditingEvaluationTests/testLiveFoundationModelsOptionEvalIsOptIn
rm /private/tmp/lineform-run-live-intelligence-evals
```

See `docs/intelligent-editing-benchmarks.md` for the full intelligence benchmark and release gate.

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
