# Lineform for iOS — Ideas & Considerations

**Date:** 2026-07-18
**Purpose:** A running idea/consideration doc for an eventual Lineform iOS (iPhone/iPadOS) app. Seeded from the competitor scan — most serious Markdown *writing* apps ship iOS, and it's the most natural place to monetize. Not a plan or commitment; a place to collect thinking so the eventual project starts informed.
**Status:** Open working notes. Add to freely.

---

## 1. Why iOS, and why it matters

From the competitor scan (`2026-07-18-competitor-feature-scan.md`):
- **8 of 15 apps ship iOS/iPadOS** — and *every* app positioned as a writing tool (vs. a viewer or AI utility) has one: iA Writer, Bear, Byword, MWeb, Raven, iWriter Pro, uFocus, Clearly, Read.md. Mac-only tools (Ink MD, Resomark, the viewers) are the exception.
- **iOS is where casual writers pay.** The App Store is the natural monetization surface (see §6).
- **The "write on Mac, read/edit on iPhone" loop is table stakes** for a file-based writing app once iCloud is in play — and Lineform already owns an iCloud container.

The strategic prize: a **calm, native, file-based, no-AI, no-account** writer that syncs your *real files* across Mac + iPhone + iPad, in a market where the incumbents are either abandoned (Byword), subscription notes-databases (Bear), or expensive (iA Writer at $50/platform).

---

## 2. What Lineform already has that de-risks iOS

The Mac codebase is unusually portable to iOS because of deliberate architecture:

- **Real files, not a database.** iCloud Drive files sync natively to iOS with zero server work. This is the single biggest advantage over Bear's model.
- **iCloud container already declared** (`iCloud.com.lineform.app`, public document scope). The sync backbone exists.
- **Pure-logic seams already factored out** and unit-tested, mostly UI-agnostic:
  - Rendering: `MarkdownBlockGrouping`, `MarkdownPreviewRenderer`, `MermaidImageProvider`, `MathImageProvider` (SwiftMath/BeautifulMermaid are cross-platform SPM).
  - Search: `EditorSearchResolver`, `CrossFileSearchResolver`, `QuickOpenIndex`.
  - Reading model: `ReadingProfile`, themes, fonts.
  - Document model: `LineformDocument`, `DocumentSaveStatus`.
- **SwiftUI-first** UI, so navigation and many views can share code via `#if os(iOS)`.

The hard part is the **editor**: Lineform's Write mode is a deeply customized AppKit `NSTextView` (`LineformTextView`) with TextKit, scroll-anchoring, and syntax highlighting. iOS needs a `UITextView`/TextKit re-implementation of the same behaviors. That's the main engineering cost.

---

## 3. What must be re-built for iOS (the real work)

| Area | Mac today | iOS reality |
|---|---|---|
| **Editor core** | `NSTextView` + TextKit (`LineformTextView`) | Re-implement on `UITextView`/TextKit 2. Biggest lift. |
| **Syntax highlighting** | Visible-window-scoped, line-local analyzer | `MarkdownRangeAnalyzer` is UI-free — reuse it; re-wire the apply layer. |
| **Toolbar / menus** | AppKit toolbar, menu commands | iOS needs an inline formatting bar + keyboard accessory row (see §4). |
| **Windowing / tabs** | Multi-window, tab bar | iOS: navigation stack; iPad: multi-window/Stage Manager, maybe columns. |
| **Sidebar / file browser** | `OutlineFileBrowserStore`, FSEvents | Store logic reusable; **FSEvents is macOS-only** — iOS uses `NSFilePresenter`/`NSMetadataQuery` for iCloud. |
| **Quick Look ext** | macOS appex | iOS has its own Quick Look + share/document providers. |
| **Print/PDF** | `NSPrintOperation` | `UIPrintInteractionController` / `UIGraphicsPDFRenderer`. |

**Rendering (Read/Preview) is the most reusable** — the block renderer, Mermaid, and math providers are the kind of code that ports cleanly. A phased approach could ship **read-first** (a great iOS Markdown *reader* that syncs) before the full editor.

---

## 4. iOS-specific features to design for (from competitors)

- **Markdown keyboard accessory row** — a row above the keyboard with `#`, `*`, `[]`, `>`, code, link, etc. **Byword, MWeb, and iA all have this; it's expected on iOS.** Highest-value iOS-native UI.
- **Files app integration** — open/edit any `.md` from the iOS Files app (Clearly does exactly this). Document-based app + document provider.
- **Share extension** — "Share to Lineform" to capture text/URLs into a new doc.
- **Handoff / Continuity** — start on iPhone, continue on Mac. Natural for an Apple-ecosystem file app.
- **Focus mode + typewriter scrolling** — translates directly; especially good on iPad with a keyboard.
- **iPad**: external-keyboard shortcuts (reuse Mac command set), Stage Manager/multi-window, trackpad, Apple Pencil (only if it fits — probably not for a text writer), landscape split Write/Preview.
- **Widgets / lock-screen** — quick "new note" or "recent files" (keep calm, optional).
- **Dynamic Type + accessibility** — Lineform's a11y values (Atkinson/OpenDyslexic, AA contrast, VoiceOver) should carry to iOS; Dynamic Type is expected.
- **Dark mode / theme parity** — reader themes should match Mac.
- **Offline-first** — already the model; ensure iCloud eviction (`ensureDownloaded`) has an iOS equivalent.

---

## 5. Sync — the make-or-break

- **iCloud Drive documents** is the on-brand answer: real files, no account, no server, works with the existing container. Users' `.md` files appear in the iOS Files app and on Mac. **This is the whole pitch — don't build a proprietary sync.**
- Watch: iCloud file **eviction/download** on iOS (dataless files), conflict handling (`NSFileVersion`), and the laziness invariants the Mac app is careful about. `UbiquitousItemDownloader` already abstracts download on Mac — mirror it.
- **Byword's #1 complaint was sync flakiness** (Dropbox inconsistency, iCloud rich-text not syncing). Getting iCloud sync *boringly reliable* is a competitive advantage on its own.
- Non-iCloud folders (Dropbox, Working Copy/Git) via the Files app document picker — supported "for free" through document-based app APIs; MWeb/iWriter lean on this.

---

## 6. Monetization models to weigh

The user raised charging; iOS is the natural surface. Options, with trade-offs:

1. **iOS paid, Mac free/source-available (recommended to explore).**
   - Preserves the open, source-available ethos on desktop; captures value where people pay.
   - Clean story: "free on your Mac, a few dollars on your phone."
   - Precedent: many indie apps monetize the mobile companion.

2. **Universal purchase (one price, all Apple devices).**
   - Simplest for users; iA Writer notably does *not* do this (charges per platform) and gets criticized for it — a universal purchase is a friendly differentiator.
   - Question: does the Mac app stay free while iOS is paid, or does a universal purchase mean the Mac app also becomes paid on the App Store (while source stays public)?

3. **One-time / lifetime vs. subscription.**
   - One-time reads as calm/trustworthy/no-lock-in — *strongly* on-brand. Subscriptions draw the loudest complaints in this category.
   - Raven's model (lifetime now → subscription later) is a hedge worth studying, but subscription risks the ethos.

4. **Optional paid sync tier** — *avoid.* iCloud is free and already the model; a sync paywall would betray "local-first, no account." Only relevant if a proprietary sync were ever built (don't).

**License caveat:** Lineform is PolyForm Shield 1.0.0. Charging for a source-available app is legitimate but needs a deliberate decision about how the paid App Store build relates to the public source. Resolve this in a positioning pass *before* pricing. (Also flagged in the feature-scan doc §6.)

---

## 7. Phasing idea (rough, not a plan)

- **Phase 0 — decide the money/positioning question first** (§6 + license). It shapes everything.
- **Phase 1 — iOS reader** that syncs iCloud files and renders beautifully (reuses the most-portable code; Read.md proves a reader alone has a market). Low editor risk, fast to ship, validates sync.
- **Phase 2 — full editor** (`UITextView`/TextKit port, keyboard accessory row, formatting bar, focus mode).
- **Phase 3 — iPad polish** (multi-window, external keyboard, split view) + share extension + Files integration + Handoff.

Read-first lets the hardest part (the editor port) come after sync and rendering are proven on device.

---

## 8. Open questions to resolve later

- Does the Mac app stay free while iOS is paid, or unify pricing?
- How does a paid App Store build coexist with PolyForm Shield source-available? (blocking for §6)
- TextKit 1 vs. 2 on iOS for the editor — match the Mac choices where possible.
- Minimum iOS version (SwiftUI/TextKit feature floor)?
- iPad: is it a scaled iPhone app or a distinct desktop-class layout (columns like the Mac)?
- Reuse the Mac command/shortcut set on iPad hardware keyboards — how much lifts directly?
- Mermaid/math raster caching and orientation flips (the Mac has documented per-platform quirks) — re-verify on iOS render paths.
