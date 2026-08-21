# Read-aloud / text-to-speech

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

**Date:** 2026-07-18
**Status:** Approved (direction), pending implementation
**Competitor-scan entry:** E

## Problem

Lineform positions itself around "readable long-form text" and already invests in accessibility
(AA contrast tests, Atkinson Hyperlegible / OpenDyslexic fonts, VoiceOver descriptions). A
native read-aloud directly serves both. macOS ships a built-in `startSpeaking:` on `NSTextView`,
but in Write mode it would read the **raw markdown** aloud — literally speaking "hash", "star
star", backticks — which is useless. The value-add is speaking the **rendered / markdown-stripped**
text, with simple transport controls.

## Decisions

- **Native `AVSpeechSynthesizer`** — offline, free, **no network, no new entitlement**
  (consistent with local-first). Isolated behind a `SpeechController`.
- **Speaks stripped text, not raw markdown.** A pure `SpeechTextExtractor` produces a clean
  spoken string from the document.
- **Content rules:** headings, paragraphs, list items, blockquotes, callouts, and table cells
  are spoken as plain text with inline markers (`#`, `*`, `_`, backticks, link syntax) removed;
  image placeholders are read as their alt text. **Fenced code, `$$`/`$` math, and ```mermaid
  blocks are skipped** (not readable long-form prose).
- **Start point:** if there is a selection → speak the selection; else speak from the caret to
  the end (Write/Split) or the whole document (Read, no caret). Speech stops at the end.
- **Controls:** an **Edit ▸ Speech** submenu (macOS convention) with **Start Speaking**,
  **Pause / Resume**, **Stop**. No default keyboard shortcut in v1 (macOS assigns none;
  avoids collisions).
- **System default voice + rate** in v1. A Reading-Experience rate/voice control is a clean
  later addition.

## Architecture

### 1. `SpeechTextExtractor` — `Lineform/ReadingExperience/SpeechTextExtractor.swift` (pure, tested)

```swift
enum SpeechTextExtractor {
    /// Convert document text (from `startIndex`..end, or a selection substring) into a clean
    /// spoken string: markers stripped, code/math/mermaid skipped, blocks joined by sentence
    /// breaks so the synthesizer paces naturally.
    static func spokenText(from markdown: String) -> String
}
```

Reuses `MarkdownBlockGrouping.markdownBlocks(in:)` to walk blocks, then strips inline markup
using the existing inline tokenizer (or a focused marker-stripping pass) so bold/italic/code/link
punctuation is removed but the words remain. Skipped block kinds emit nothing. Pure and
deterministic — no AV dependency in this type.

### 2. `SpeechController` — `Lineform/ReadingExperience/SpeechController.swift`

Wraps `AVSpeechSynthesizer` behind a small protocol so it is testable without audio:

```swift
protocol SpeechSynthesizing { func speak(_ text: String); func pause(); func continueSpeaking(); func stop(); var isSpeaking: Bool { get }; var isPaused: Bool { get } }

final class SpeechController: ObservableObject {
    @Published private(set) var state: SpeechState   // .idle, .speaking, .paused
    func startSpeaking(_ text: String)               // builds an AVSpeechUtterance, system voice/rate
    func pauseOrResume()
    func stop()
}
```

Owns one synthesizer; `AVSpeechSynthesizerDelegate` updates `state` on finish so the menu
enable/disable and Pause/Resume label stay correct. `stop()` on document close / app quit.

### 3. Menu wiring — `AppCommands.swift`

Add an **Edit ▸ Speech** submenu (sibling of the system speech convention):

- **Start Speaking** — resolves the active window's document + selection/caret, runs it through
  `SpeechTextExtractor.spokenText`, calls `SpeechController.startSpeaking`. Posts a
  window-scoped notification carrying the resolved spoken text (the `printDocument`/`exportPDF`
  pattern), handled in `EditorContainerView`, which owns the window's `SpeechController`.
- **Pause / Resume** — toggles; label reflects `SpeechController.state`.
- **Stop** — stops.

Items disable when there is no document (the current-file menu-state pattern).

### 4. Selection / caret resolution

`EditorContainerView` already bridges the active `NSTextView`; on Start Speaking it reads the
selected range (speak substring) or the caret location (speak from there to end). In Read mode
with no caret, speak the whole document. This mirrors how existing commands reach the active
editor.

## Testing

- **Unit (default plan):**
  - `SpeechTextExtractor.spokenText` — markers stripped (bold/italic/code/link), headings read
    as text, lists/blockquotes/callouts read, tables read cell-by-cell, **code/math/mermaid
    skipped**, image → alt text, blocks separated so pacing is natural.
  - `SpeechController` state machine driven by a fake `SpeechSynthesizing` — idle→speaking→paused
    →speaking→idle transitions; `stop` resets; finish callback returns to idle.
- **Manual:** Start/Pause/Resume/Stop across Write/Read/Split; selection vs. caret vs. whole-doc;
  confirm no markdown symbols are spoken and code blocks are silent.

## Out of scope (v1)

- Spoken-word highlight-follow (karaoke highlight via `willSpeakRangeOfSpeechString` → document
  range mapping) — a good accessibility follow-up, deferred to keep v1 lean.
- Voice / rate / pitch pickers (uses system defaults; a Reading-Experience control can come
  later).
- Reading code, math, or diagrams aloud.
- Persisted playback position / resume-across-sessions.

## Risk

Low. `AVSpeechSynthesizer` is native and offline; the only owned logic is the pure extractor
(fully testable) and a small state machine. No new dependency, no entitlement, no network, no
file-size impact.
