# Lineform

**A free, local-first Markdown editor for macOS.**

[![Download Lineform for macOS](https://img.shields.io/badge/Download-Lineform%20for%20macOS-111111?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/carlostarrats/Lineform/releases/latest/download/Lineform-1.0.dmg)
[![Visit the website](https://img.shields.io/badge/Website-lineform--site.vercel.app-f2f2f2?style=for-the-badge)](https://lineform-site.vercel.app)

Lineform is a native Mac Markdown editor for calm writing, readable long-form text, and real local files. It opens ordinary `.md`, `.markdown`, and `.txt` files so your documents stay portable across Finder, iCloud Drive, Git, and other editors.

## Download

Download the latest DMG from GitHub Releases:

**[Download Lineform for macOS](https://github.com/carlostarrats/Lineform/releases/latest/download/Lineform-1.0.dmg)**

More release files and notes are available on the [Lineform Releases page](https://github.com/carlostarrats/Lineform/releases). The product website is at [lineform-site.vercel.app](https://lineform-site.vercel.app).

## What It Does

- Write Markdown and plain text in a native macOS document app.
- Switch between Write, Read, and Preview modes.
- Preview Markdown beside the source in split view.
- Navigate documents from their headings.
- Search inside the current file with match navigation.
- Format headings, lists, links, emphasis, and inline code.
- Save Markdown, save plain text, or export PDF.
- Adjust reading font, size, line height, spacing, width, theme, reading ruler, and typewriter mode.
- Use selected-text AI editing when Apple Intelligence is available, then review suggestions before accepting.

## Privacy

Lineform is local-first.

- No account system.
- No analytics collection by default.
- No document upload.
- Documents stay wherever you save them.
- Files remain ordinary Markdown or text files.
- Intelligent editing uses Apple system capabilities when available, and the editor remains usable without them.

## Updates

Lineform includes a **Check for Updates...** menu item in the app menu.

Release builds use [Sparkle](https://sparkle-project.org) for update checks once a Sparkle EdDSA public key and published appcast are configured. Development or unsigned test builds may show an "Updates are not configured for this build" message.

## Requirements

- macOS 15.0 or later

## About

Lineform V1.0 is the first public version of the app. It is built as a native macOS document app with SwiftUI, AppKit, and TextKit.

## Credits

Lineform uses [Sparkle](https://sparkle-project.org) for macOS update checking.

Lineform bundles accessibility-focused reader fonts under the SIL Open Font License 1.1:

- Atkinson Hyperlegible, copyright 2020 Braille Institute of America, Inc.
- OpenDyslexic, copyright Abbie Gonzalez, with Reserved Font Name OpenDyslexic.

Harper, an Automattic open-source project, is credited as inspiration and comparison material for private, local-first writing assistance. Harper is not bundled with Lineform and is not a runtime dependency.

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

Release packaging notes live in [docs/release/github-sparkle-release.md](docs/release/github-sparkle-release.md).

## License

Lineform is source-available under the PolyForm Shield License 1.0.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
