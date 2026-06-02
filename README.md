# Lineform

Lineform is a free native macOS Markdown editor for calm writing, real local files, and readable long-form text.

It is built around ordinary UTF-8 Markdown and plain text files, so documents stay portable across Finder, iCloud Drive, Git, and other editors.

## Features

- Native macOS document app built with SwiftUI, AppKit, and TextKit.
- Opens and saves ordinary Markdown and plain text files.
- Write mode for editing source Markdown.
- Read mode for a calmer rendered reading view.
- Preview mode for side-by-side Markdown editing and rendered preview.
- Markdown outline navigation from document headings.
- Native toolbar search with match highlighting and next/previous navigation.
- Markdown formatting commands for headings, emphasis, inline code, lists, and links.
- Format conversion between Markdown and plain text.
- Save, Save As, and PDF export support.
- Reading Experience controls for font, size, line height, block spacing, column width, themes, reading ruler, and typewriter mode.
- Reader themes and accessibility-focused font options, including Atkinson Hyperlegible and OpenDyslexic.
- Basic selected-text AI editing when Apple Intelligence is available: select text, toggle AI in Write mode, describe the edit, then review before accepting.
- Defensive intelligent editing validation to avoid prompt artifacts, stale selections, empty suggestions, and unsafe Markdown changes.
- Local-first privacy with no account system, analytics, or document upload.
- Standard macOS About panel showing the V1.0 app version.

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

## Download and Updates

Public builds are distributed as a drag-to-Applications DMG through GitHub Releases:

<https://github.com/carlostarrats/Lineform/releases>

Lineform uses Sparkle 2 for update checks. Release builds need a Sparkle EdDSA public key in the `SPARKLE_PUBLIC_ED_KEY` build setting, and the appcast is expected at:

```text
https://carlostarrats.github.io/Lineform/appcast.xml
```

See `docs/release/github-sparkle-release.md` for the release order and packaging commands.

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
(
  touch /private/tmp/lineform-run-live-intelligence-evals
  trap 'rm -f /private/tmp/lineform-run-live-intelligence-evals' EXIT
  xcodebuild test \
    -project Lineform.xcodeproj \
    -scheme Lineform \
    -destination 'platform=macOS' \
    -only-testing:LineformTests/IntelligentEditingEvaluationTests/testLiveFoundationModelsEvalIsOptIn \
    -only-testing:LineformTests/IntelligentEditingEvaluationTests/testLiveFoundationModelsOptionEvalIsOptIn
)
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

Lineform V1.0 is the first public version of the app.

## Credits

Lineform bundles accessibility-focused reader fonts under the SIL Open Font License 1.1:

- Atkinson Hyperlegible, copyright 2020 Braille Institute of America, Inc.
- OpenDyslexic, copyright Abbie Gonzalez, with Reserved Font Name OpenDyslexic.

The bundled license files live in `Lineform/Resources/Fonts`.

Harper, an Automattic open-source project, is credited as inspiration and comparison material for private, local-first writing assistance. Harper is not bundled with Lineform and is not a runtime dependency.

## License

Lineform is source-available under the PolyForm Shield License 1.0.0. See `LICENSE` and `NOTICE`.
