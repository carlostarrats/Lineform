# Save-State Status Communication — Design

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

**Date:** 2026-07-04
**Status:** Approved for planning
**Area:** `Lineform/Editor` (status bar), `Lineform/Documents` (save status)

## Problem

The bottom editor status bar shows only neutral grey metadata — `Last save: 3:41 PM  |  340 words — 1,982 characters`, or `Not saved yet  |  …` for untitled documents. It never distinguishes **saved** from **unsaved**. Because existing files autosave silently, a user can close or walk away from a document assuming it was written when it wasn't — or, conversely, not realize the app is quietly protecting their work. There is no honest, always-visible signal for either state.

The goal: give the user clear, consistent communication of **when their work is on disk and when it isn't**, without disturbing the calm-writing feel. Never let the user *assume* autosave — show them.

## Principles

- **Severity is carried by color**, applied only to *added* status words — never to the existing metadata.
  - **Red** = not saved at all (untitled document; nothing will save it until the user picks a location). A genuine call to action.
  - **Amber** = temporarily unsaved (established document with pending edits). Milder — autosave is coming. An FYI, not a threat.
  - **Green** = just saved / confirmed. Transient reassurance.
- **The metadata never changes color.** The word count, character count, and `Last save: …` time are always grey, in every state.
- **Communication is additive**, not a replacement. We add status words; we do not swap the existing metadata text out.
- **Honest about who saved.** A save confirmation names the actor: *you* (`Saved`) vs *the app* (`Autosaved`).

## States and layout

The status bar (`EditorStatusBar`) has a right-aligned metadata `Text` and, to its left, an indicator slot (today used only by the green `Updated` external-reload flash). We keep the metadata slot grey and permanent, and extend the left slot to carry the new save-state words.

### Right side — metadata (always grey, unchanged)

`Last save: 3:41 PM  |  340 words — 1,982 characters`

The counts and last-save time are always `.secondary` grey. The only exception is the untitled label below, which is not metadata.

### Untitled / never-saved document

Rendered in the metadata line, but the `Not saved yet` **label** is **red** while the ` | N words — N characters` portion stays grey:

> <span style="color:red">**Not saved yet**</span>  `  |  12 words — 68 characters`

`Not saved yet` is treated as an *added communication word*, so it is colored; the counts are metadata, so they stay grey. This state **persists** until the first real save — untitled documents do not autosave. No green flash ever fires for an untitled document (nothing auto-writes it).

### Left slot — one item at a time

| Condition | Left slot shows | Color | Duration |
|---|---|---|---|
| Established doc, dirty (pending edits) | `Unsaved changes` | **Amber** | While dirty |
| After a manual save (⌘S / Save / Save As) | `Saved` | **Green** | Fades after ~4s |
| After an autosave flush | `Autosaved` | **Green** | Fades after ~4s |
| After an external disk reload | `Updated` + `arrow.clockwise` | Green (existing) | Fades after ~4s (unchanged) |
| Clean & idle | *(empty)* | — | — |

No icon on the new red/amber/green words (matches the "no icon" decision). The existing `Updated` flash keeps its `arrow.clockwise` because it means something different (the file changed on disk, not a local save).

There is no conflict between `Unsaved changes` (amber) and `Updated` (green): live external reload only applies to **clean** documents, so a dirty document never shows `Updated`.

### Lifecycle — editing an established document

1. **Clean & idle:** left empty · `Last save: 3:41 PM  |  …` (grey)
2. **First keystroke:** document is instantly dirty → left shows amber `Unsaved changes` immediately (no delay)
3. **Continued typing:** stays amber `Unsaved changes`
4. **Pause → autosave writes:** amber replaced by green `Autosaved` (fades ~4s); right side updates to the new `Last save:` time
5. **Type again:** back to amber `Unsaved changes`

During a long session the left slot naturally pulses amber-while-editing → green-when-caught-up. This pulsing is an accepted, deliberate part of the design (the whole point is to make save state visible).

## Color specification

Add accessible **red** and **amber** colors alongside the existing accessible green, following the same per-appearance custom-RGB pattern already used for `updatedIndicatorColor` in `EditorStatusBar` (dark forest / bright mint). Both new colors must clear WCAG AA contrast against the status-bar background in light and dark, so raw system `.red` / `.orange` are not used. Exact RGB values to be dialed during implementation; the existing green stays as-is.

- **Red** (untitled): saturated but AA-contrast in both appearances.
- **Amber** (dirty established): clearly distinct from both red and the grey metadata; softer/warmer than the red.
- **Green** (saved / autosaved): reuse the existing `updatedIndicatorColor`.

## Data model / signals

All required signals already exist; no new persistence.

- **Dirty detection (amber trigger):** compare the live `document.text` against the last-written text, `DocumentSaveStatus.savedText(for: document.id)`. When `savedAt(for:)` is non-nil (established) and the live text differs from `savedText`, the document is dirty → amber `Unsaved changes`. When they match → clean. This is fully reactive: `document.text` changes on every keystroke and `savedText` is updated by `markSaved` on every write.
- **Untitled detection (red trigger):** `DocumentSaveStatus.savedAt(for: document.id) == nil` → `Not saved yet` in red. (This already drives the existing "Not saved yet" label; we only add color.)
- **Save confirmation (green trigger):** a save updates `savedAt`; the view already observes `.onChange(of: documentSaveStatus.savedAt(for: document.id))`. Hook the green flash there, reusing the existing `flashUpdatedIndicator()` timing (~4s auto-clear) as the model for a new save-confirmation flash.

## Open implementation risk — manual vs. autosave

To honor `Saved` vs `Autosaved`, we must distinguish who wrote the file. In SwiftUI, both autosave and manual save flow through `LineformDocument.fileWrapper(configuration:)` → `DocumentSaveStatus.markSaved(...)`; `WriteConfiguration` does **not** expose the save-operation kind, so the write path alone cannot tell them apart.

**Preferred approach:** flag manual saves at the command layer. The Save / Save As menu actions (⌘S) are user-initiated and interceptable; set a short-lived "manual save in progress" marker so the next `markSaved` is attributed to the user (`Saved`), and treat any unmarked write as an autosave (`Autosaved`). The plan must verify this hook is reliable (marker set before the write, cleared after; no cross-document leakage).

**Fallback (if manual/auto cannot be told apart cleanly):** show a single green `Saved` for every write. This is decided during implementation, verified against the running app, and confirmed with the user before finalizing — not guessed.

## Accessibility

- The new words get VoiceOver labels analogous to the existing `Updated` indicator ("Document updated from disk"): e.g. "Unsaved changes", "Not saved yet", "Saved", "Autosaved". Color is never the sole carrier of meaning — the words themselves state the status.
- The metadata's existing accessibility label is preserved.

## Scope / non-goals

- No change to autosave behavior, save timing, or the document model beyond attributing writes.
- No change to the `Updated` external-reload flash.
- No warning-triangle or other icons on the new states (explicitly declined).
- No change to Read mode (the status bar is already hidden there via `EditorStatusBar.isVisible`).
- No new persisted settings.

## Testing

- **Formatter/state-mapping unit tests** (pure, default plan): given save state (untitled / clean / dirty) and last-save date, assert the correct label text, which token is colored, and the left-slot content. Follow the existing `EditorStatusFormatter` test style.
- **Color helpers:** assert the red/amber/green resolve to the intended per-appearance values (mirroring any existing coverage of `updatedIndicatorColor`).
- **Manual vs. autosave attribution:** unit-test the marker logic (manual write → `Saved`; unmarked write → `Autosaved`).
- **Manual verification in the running app** (per repo quality bar): type in an established doc (amber appears instantly), pause (green `Autosaved`, then fades), ⌘S (green `Saved`), and open a fresh untitled doc (red `Not saved yet`, persists). Confirm the metadata stays grey throughout and light/dark both read clearly.
