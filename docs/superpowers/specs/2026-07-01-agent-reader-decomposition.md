# Agent-Reader Release — Decomposition Index

Date: 2026-07-01

This is the roadmap for the "Agent-Reader" body of work. The source spec
(`lineform-agent-reader-spec.md`, kept on the maintainer's Desktop) is **eight settled
features** plus a maintainer decision to **remove the existing AI features first**. That is
far too much for a single spec/plan/implement cycle, so it is decomposed into the
independent units below.

Positioning of the release: **where you read and edit what your agent wrote.** No AI
features, no sessions, no git, no vault.

## How to work these

Each unit gets its **own** spec → plan → implement cycle:

1. Brainstorm the unit → write its spec to `docs/superpowers/specs/`.
2. Run `writing-plans` → write its plan to `docs/superpowers/plans/`.
3. **`/clear`** the session.
4. Execute the plan in a fresh session via the `executing-plans` skill.
5. Move to the next unit.

Clearing context between units keeps token cost down and focus tight; the specs and plans
on disk carry all the state a fresh session needs. Do **not** clear mid-unit (between a
unit's spec and its plan) — that context is still live.

## Units, in build order

The order follows the source spec's build order. Later units depend on earlier ones; the
web gate (Privacy/Terms) must be live before the reporting build ships.

| # | Spec | Source features | Depends on | Notes |
|---|------|-----------------|-----------|-------|
| 0 | **Remove AI features** | (maintainer ask) | — | Archive-then-strip. Clears the Editor surface later units touch. Spec: `2026-07-01-remove-ai-features-design.md`. |
| 1 | **Live reload (watch)** | F3 | 0 | Self-contained, immediately dogfoodable, no new deps. NSFilePresenter reload on clean docs, debounced. |
| 2 | **Hidden folder visibility** | F4 | — | Small sidebar toggle in `OutlineFileBrowserStore`. |
| 3 | **CLI helper + stdin** | F1 + F2 | — | Paired: stdin is literally `lineform -`. Bundled helper, installer menu item, temp-file piping + housekeeping. |
| 4 | **Mermaid rendering + local failure log** | F5 + local half of F7 | 0 | Paired: the local diagram log is the mermaid failure sink. `beautiful-mermaid-swift` via SPM, native render, theme mapping, fallback, a11y. |
| 5 | **Diagram report (Worker + dialog)** | rest of F7 | 4, 6 | Cloudflare Worker + report dialog + network entitlement growth. **Gated: unit 6 must be live first.** |
| 6 | **Privacy + Terms pages** | F8 | — | Two static Cloudflare pages. Gate for unit 5. Linked from About + site footer. |
| 7 | **Agent hook recipe page** | F6 | all | Docs only. Verified end-to-end against current Claude Code. Natural last step; demos everything above. |

## Explicit non-goals (whole release)

Folder/project watching beyond open documents; opening directories from the CLI; MCP
server; AI features of any kind; relative-link navigation; inline image work beyond what
exists; Raycast/Shortcuts/App Intents/Services/Share extensions; forking or proactively
patching beautiful-mermaid-swift; any telemetry or automatic reporting; monetization.

## Status

- [x] 0 — Remove AI features
- [x] 1 — Live reload
- [x] 2 — Hidden folders
- [x] 3 — CLI + stdin
- [x] 4 — Mermaid + local log
- [ ] 5 — Diagram report
- [ ] 6 — Privacy + Terms
- [ ] 7 — Hook recipes
