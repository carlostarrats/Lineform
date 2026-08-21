# Competitor-scan features — batch execution order & shared seams

> **HISTORICAL — DO NOT EXECUTE.** This dated design or implementation record is not a current
> task list. Use `AGENTS.md` and `docs/architecture/` for shipping behavior and invariants.

**Date:** 2026-07-18
**Scope:** Coordination doc for the seven implementation plans drafted from the
2026-07-18 competitor feature scan (entries G, C, B, E, D, F, A). Read this before
executing any of them; each individual plan is self-contained but they touch two
shared seams, so **order matters**.

## The seven plans

| Entry | Plan file | Isolated? |
|---|---|---|
| G | `2026-07-18-view-mode-keyboard-shortcut.md` | ✅ fully isolated |
| C | `2026-07-18-code-block-highlighting-copy.md` | touches shared seams |
| B | `2026-07-18-callouts-admonitions.md` | touches shared seams |
| A | `2026-07-18-inline-local-image-rendering.md` | touches shared seams |
| D | `2026-07-18-rtf-export-menu.md` | touches render signature |
| F | `2026-07-18-pdf-export-themes.md` | touches render signature |
| E | `2026-07-18-read-aloud-tts.md` | consumes `MarkdownBlock` cases |

## Recommended execution order

**G → C → B → A → D → F → E**

Rationale: G is isolated (do it first, cheap win). C/B/A each add a *block* construct
and are the structural changes — do them before the consumers. D and F only add
defaulted render parameters. E consumes the final `MarkdownBlock` enum, so it goes
last (see its plan's CROSS-PLAN ORDERING note).

You do NOT have to follow this order strictly — the two safety nets below make any
order compile-safe — but this order minimizes rework.

## Shared seam 1 — `MarkdownPreviewRenderer.render(...)` parameters

Four plans add an **additive, defaulted** parameter to the render path. Each defaults
to a no-op so on-screen Read/Preview stays byte-identical and earlier features are
unaffected:

| Plan | New parameter | No-op default |
|---|---|---|
| C | `highlightsCode: Bool` | `true` on screen / `false` from `DocumentExportRenderer` |
| D | `imagesAsText: Bool` | `false` |
| F | `headingScale: CGFloat` | `1.0` |
| A | `documentDirectory: URL?` | `nil` (relative paths unresolved → placeholder) |

**Rule:** whichever plan you execute later, keep the earlier parameters (they are
defaulted, so this is automatic). Never remove a sibling's parameter. The on-screen
preview must remain byte-identical whenever every flag is at its no-op default.

## Shared seam 2 — `MarkdownBlock` enum + every `switch` over it

Three plans add an **additive case** to `MarkdownBlock` in `MarkdownBlockGrouping.swift`:

| Plan | New case |
|---|---|
| C | `.fencedCode(...)` — routes ` ``` `/`~~~` code out of `.lines` |
| B | `.callout(kind:title:body:lastLineIndex:)` — promotes a `[!TYPE]` blockquote |
| A | `.image(...)` — an own-line `![alt](path)` |

**Safety net:** Swift `switch` statements over `MarkdownBlock` are **exhaustive**, so
adding a case forces a compile error in every consumer that doesn't handle it. The
consumers are: the renderer block dispatch (each plan updates it), and E's
`SpeechTextExtractor`. This means the compiler *guarantees* you can't forget a case —
but you must handle each meaningfully, not with a silent `default`.

**Consumer handling reference:**
- Renderer dispatch: `.fencedCode` → `appendCodeBlock`; `.callout` → `appendCallout`;
  `.image` → `appendImageBlock` (each plan adds its own arm).
- E's `SpeechTextExtractor`: `.fencedCode` → **skip** (never spoken); `.callout` →
  speak title + body (drop the `[!TYPE]` marker); `.image` → speak alt text.

**Do not add a `default:` arm to these switches** — it would silently swallow a future
case and defeat the safety net. Handle each case explicitly.

## Byte-identical invariants to keep green

Each plan pins a "nothing else changed" test; do not weaken them:
- C: non-code block routing byte-identical; export code monochrome.
- B: existing blockquote render byte-identical after the `appendQuoteLines` refactor.
- A: non-image routing byte-identical; no network ever.
- D: `imagesAsText: false` leaves render byte-identical.
- F: `standard` preset == today's export (inherits the user's face + line-height).

## Project mechanics (applies to every plan)

- New `.swift` files (product + test) must be registered in the hand-edited pbxproj —
  4 sections, sequential `1F0000xx` IDs, objectVersion 56, no synced groups (see the
  `pbxproj-handrolled-ids` memory note). Product files → **Lineform** target; test
  files → **LineformTests** target.
- Default test gate (per CLAUDE.md):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
- CLI test runs re-sign ad-hoc and can trigger a one-time TCC "Documents access"
  prompt — expected, dev-only; answer it or the run blocks.
- No new SPM dependencies in this batch (C is a native tokenizer; E is system AV; the
  rest are native AppKit/TextKit).
