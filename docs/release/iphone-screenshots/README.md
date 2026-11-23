# iPhone screenshots (drafts)

Draft App Store screenshots for the iPhone app, at the required 6.9" size (1320 × 2868, portrait).
They come from a **Debug** simulator build, not the release candidate: re-capture from the build
being submitted before upload. The plan they follow is in `../app-store-release.md` ▸ iPhone ▸
Screenshots.

| File | Shows |
|---|---|
| `01-write.png` | Write mode on the sample document: heading, paragraph, list with task items, the start of a Mermaid block. |
| `02-read-diagram-math.png` | Read mode, scrolled to the Mermaid flowchart, inline and block LaTeX math, and a blockquote. |
| `03-preview.png` | Preview: Write above, Read below, with the linked-scroll button. |
| `04-menu-files.png` | The Menu sheet on Files (On My iPhone, Workspace), over Write. |
| `05-styling-sheet.png` | The Styling sheet (Reading: themes, Font, Font Size, Line Height) over Read. |

Not captured: **the AI review** (screen 6 of the plan). It needs a connected AI provider and a real
reply, which a key-less simulator cannot produce. Capture it on a device or simulator with a test
key, and keep the key out of view.

## How they were made (2026-11-23)

- Simulator: a new iPhone 17 Pro Max on iOS 26.5 (deleted afterwards), status bar overridden to
  9:41, full battery and signal (`xcrun simctl status_bar … override`).
- App: the Debug `LineformiOS.app` built by the `LineformiOS` test run, installed with
  `xcrun simctl install`.
- First run skipped by writing `LineformiOSFirstRunCompleted.v1 = YES` into the app's defaults
  (`xcrun simctl spawn <udid> defaults write com.lineform.app …`).
- `sample-document.md` (in this folder) copied into the app's on-device `Documents` folder
  (`xcrun simctl get_app_container <udid> com.lineform.app data`), then opened from Menu ▸ Files.
- Taps with AXe by accessibility label (Menu, Read, Preview, Reading Experience); captures with
  `xcrun simctl io <udid> screenshot`.
- Light appearance, the default Original theme and SF Pro. Debug has no iCloud, so Files shows On
  My iPhone; a release build signed into iCloud shows the iCloud root instead.

Known draft blemishes: in `01-write.png` live spell checking underlines "litres" (an en-US
simulator); in `03-preview.png` the floating buttons overlap the last visible list line.
