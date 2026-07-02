# Spec 5 — Diagram Failure Report (Worker + dialog)

Date: 2026-07-01
Part of: [Agent-Reader decomposition](./2026-07-01-agent-reader-decomposition.md) (unit 5)
Source feature: rest of F7. **Gated on unit 6** (Privacy/Terms) — now live.

## Goal

Let a user optionally send a failed Mermaid diagram to the developer to improve rendering. A
quiet "Report this" affordance on a fallback block POSTs exactly `{ source, error, appVersion }`
to a Cloudflare Worker, which files/【comments】 a private GitHub issue. Fully user-initiated,
anonymous.

## Components

### Cloudflare Worker (`worker/`)
- Accepts **POST** only (else 405). CORS not required (native app client).
- Validates the payload is JSON with string `source`, `error`, `appVersion`; rejects bodies
  `> 64 KB` (413) and malformed shape (400).
- Rate-limit per client IP (~10/hour) via a KV counter; IPs are used transiently for limiting
  and are **not stored, not logged, never written into issues**.
- Computes `hash = sha256(source)`. Dedup: if an **open** issue in the private
  `carlostarrats/lineform-reports` repo carries the label `hash:<first 40 hex chars of hash>`
  (GitHub label names cap at 50 characters, so the label uses a 160-bit prefix), POST a
  count-bump comment; else create a new issue with that label. GitHub API token is a
  **Worker secret** (`GITHUB_TOKEN`), never in the app or the repo.
- Issue body: fenced diagram source (fence sized past any backtick run in the source), error
  and app version neutralized into inline code, full hash. Nothing else.
- Returns 200 on success, 4xx/5xx otherwise.

### App
- `DiagramReportService` (testable): builds the exact 3-field payload and POSTs it via
  `URLSession` to the Worker endpoint; returns success/failure. Payload contains **exactly**
  `source`, `error`, `appVersion` — asserted by a test.
- **Report affordance**: the Mermaid fallback block gets a quiet "Report this" link
  (`NSLinkAttributeName` with a `lineform-report:<hash>` URL). The preview text view handles the
  link click (`textView(_:clickedOnLink:)`), looks up the pending report by hash from a
  `DiagramReportRegistry` the renderer populated, and presents the dialog:
  - Title "Report rendering issue?"; body "The diagram text and error will be sent to the
    developer to improve rendering."; buttons **Report** / **Not Now**.
  - On Report → `DiagramReportService.send`; success → brief "Thanks — sent."; failure →
    "Couldn't send. Saved locally." (it is already in the local diagram log).
- **Entitlement**: `com.apple.security.network.client` already present — no change. README
  privacy section notes the app now contacts the single Worker endpoint (only on Report).

## Non-goals
- No automatic/telemetry reporting; every send is an explicit tap.
- No identifiers, file names, paths, locale, or hardware info in the payload.
- No app-side GitHub token (only the Worker holds it).

## Verification
- Worker: `curl` the deployed endpoint — 405 for GET, 400 for bad shape, 413 for >64 KB, and a
  well-formed POST returns 200 (or a clear error until the token secret is set). Rate-limit
  after ~10 posts.
- App: builds; `DiagramReportService` payload test (exactly 3 fields) written (run in final pass).
- Manual (final pass, Xcode): a malformed diagram → "Report this" → dialog → Report → issue
  appears in `lineform-reports` (once the token is set).

## External dependency — DONE (went live 2026-07-02)
The Worker needed a **fine-grained GitHub PAT** (repo access: `lineform-reports`; permissions:
Issues read/write), created interactively and stored via `wrangler secret put GITHUB_TOKEN`.
All setup is now complete:
- `lineform` workers.dev subdomain registered on the account.
- Private `carlostarrats/lineform-reports` repo created.
- Worker deployed at `https://lineform-diagram-report.lineform.workers.dev` (KV rate-limiter bound).
- `GITHUB_TOKEN` secret set (fine-grained PAT, `lineform-reports` Issues read/write only).
- Verified end-to-end: valid POST → issue filed; duplicate → count-bump comment; GET→405,
  bad shape→400, oversize→413, missing token→503.

If the token is ever revoked or expires, the Worker returns an error and the app falls back to
"Couldn't send. Saved locally." (safe) until a new secret is set.

## Risk / notes
- Deployed Worker is safe without the token (fails closed → app falls back to local log).
- The `*.workers.dev` endpoint URL is hardcoded in the app; keep the Worker name stable.
