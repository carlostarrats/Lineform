# Spec 6 — Privacy + Terms Pages

Date: 2026-07-01
Part of: [Agent-Reader decomposition](./2026-07-01-agent-reader-decomposition.md) (unit 6)
Source feature: F8. **Gate for unit 5** (must be live before the diagram-report build ships).

## Goal

Two short, static, plain-language pages — **Privacy** and **Terms** — hosted on Cloudflare
Pages (same account that will host the unit-5 Worker), linked from the app's About window and
the website footer. They disclose exactly what leaves the device before the report flow ships.

## Content (from F8)

**Privacy** states plainly:
- Local-first; no accounts; no analytics by default; no document upload.
- Documents never leave the device **except**: (a) update checks via Sparkle (version check only,
  no document content); (b) a diagram report **only when the user taps "Report this"** on a
  failed diagram — containing only the diagram text, the error, and the app version, stored as a
  private GitHub issue; no file names, paths, or identifiers.
- Piped input (`lineform -`) is stored locally in `~/Library/Application Support/Lineform/Piped/`
  and auto-deleted after 7 days.
- The local diagram log stays on the device.

**Terms** (short, plain):
- Provided as-is, no warranty.
- Diagram reports you submit become developer-owned bug data used to improve rendering.
- The source is licensed under PolyForm Shield (link).
- Use at your own risk.

## Design

- Static self-contained HTML in `web/` (`privacy.html`, `terms.html`, `index.html`), inline CSS,
  calm/native aesthetic, no trackers, no external requests. Deployed to a Cloudflare **Pages**
  project via `wrangler pages deploy web --project-name lineform`.
- **App linking**: add **Privacy Policy** and **Terms of Use** items to the Help menu (in
  `AppCommands`) that open the Pages URLs via `NSWorkspace`. Titles as `AppMenuConfiguration`
  constants, asserted in `AppCommandNotificationTests`. (This is the discoverable in-app link the
  spec's "About window" intent calls for; the standard About panel can't host live links cleanly.)
- **README**: link Privacy + Terms.
- **Website footer** (the separate `lineform-site` Vercel project): out of this repo — recorded
  as a hand-off in the release notes / to the maintainer.

## Non-goals
- No dynamic content, no analytics, no cookies, no external assets.
- No change to the bundled in-app `Privacy.md` beyond what units 3–4 already added (it stays the
  local help copy; the web page is the canonical public policy).

## Verification
- Pages deploy succeeds; both URLs load and render; no external network requests (self-contained).
- App builds; Help menu opens the URLs; title-constant tests written (run in final pass).
- Content matches F8 disclosures exactly (esp. the "only when user taps Report" wording), so it is
  accurate before unit 5 ships.

## Risk / notes
- The URLs are hardcoded in the app once known; keep them stable (the Pages project name is fixed
  so the `*.pages.dev` subdomain is stable; a custom domain can be added later without changing
  the app if a redirect is kept).
