# Spec 4 — Mermaid Rendering + Local Diagram Log

Date: 2026-07-01
Part of: [Agent-Reader decomposition](./2026-07-01-agent-reader-decomposition.md) (unit 4)
Source features: F5 + the local half of F7.

## Goal

Render ```mermaid fenced blocks as native diagrams in **Read and Preview (Split)** modes, so
agent-written diagrams are readable in Lineform. Write mode always shows source. A local,
privacy-safe failure log records rendering failures for triage.

## Verified library API (from source, tag 1.0.4)

`lukilabs/beautiful-mermaid-swift`, product **`BeautifulMermaid`** (`import BeautifulMermaid`),
macOS 12+, pure Swift (no WebView/JS), MIT. Pulls transitive `elk-swift` (SPM auto-resolves).

- `public static func MermaidRenderer.renderImage(source: String, theme: DiagramTheme = .default, scale: CGFloat? = nil) throws -> BMImage?` — `BMImage` is `NSImage` on macOS. Returns nil or throws on failure.
- `public struct DiagramTheme` with `init(background: String, foreground: String)` (hex strings) — the two-color mono mode.

So the call is: `let image = try? MermaidRenderer.renderImage(source: src, theme: DiagramTheme(background: bgHex, foreground: fgHex), scale: 2.0)` → `NSImage??`; flatten; nil → fallback.

## Architecture reality

- **SPM is already wired** (Sparkle) in the hand-authored `project.pbxproj` with the standard
  five objects (`XCRemoteSwiftPackageReference`, `XCSwiftPackageProductDependency`,
  `PBXBuildFile` in the app Frameworks phase, target `packageProductDependencies`, project
  `packageReferences`) + a `Package.resolved` pin. Adding BeautifulMermaid replicates those
  five objects (fresh `1F…` IDs, `kind = exactVersion; version = "1.0.4"`) + one pin.
- **Preview is NSAttributedString → NSTextView** (`Lineform/Preview/MarkdownPreviewRenderer.swift`,
  `MarkdownPreviewViewRepresentable.swift`), no WebView. The renderer walks lines and toggles
  `inFence` on ` ``` `/`~~~` (`:33-39`). Read and Split use this renderer; Write uses the source
  editor. So rendering here is **automatically confined to Read + Preview**.
- **Reader theme colors**: `Theme.theme(for: profile).backgroundColor` / `.textColor`
  (`Theme.swift:39-40, 109-121`). Column width: `EditorReadingLayout.textContainerWidth(...)`
  (`EditorPresentation.swift:12-14`).
- **App is sandboxed** → `FileManager.homeDirectoryForCurrentUser` is the container; the diagram
  log lives at `~/Library/Application Support/Lineform/DiagramLog/` (container path, no extra
  entitlement), resolved by `DiagramLog.directory(home:)` in `Lineform/Preview/DiagramLog.swift`
  (kept out of `LineformCLIPaths`, which is compiled standalone into the CLI helper).
- **Menu surface**: `AppCommands.swift` app-info group (already hosts "Install Command Line
  Tool..."). Export/Clear Diagram Log go here.

## Design

### Dependency
Add BeautifulMermaid 1.0.4 (exactVersion) to the app target via the existing SPM pbxproj
pattern + `Package.resolved`. (elk-swift resolves transitively; it also gets a pin.)

### New file `Lineform/Preview/MermaidRendering.swift` (pure + a thin library wrapper)
- `enum MermaidHexColor { static func string(from: NSColor) -> String }` — sRGB `#RRGGBB` (pure-ish; NSColor conversion).
- `enum MermaidBlockPolicy { static let maxSourceLength = 20_000; static func shouldAttemptRender(source: String) -> Bool }` — size guard (pure, tested).
- `enum MermaidCacheKey { static func key(source: String, backgroundHex: String, foregroundHex: String, scale: CGFloat) -> String }` — stable hash (pure, tested).
- `final class MermaidImageProvider` — an `NSCache<NSString, NSImage>`; `func image(source:backgroundHex:foregroundHex:scale:) -> MermaidRenderOutcome` where `enum MermaidRenderOutcome { case image(NSImage); case skipped; case failed(String) }`. Calls `MermaidBlockPolicy.shouldAttemptRender` then `try? MermaidRenderer.renderImage`; caches successes. This is the ONLY file importing BeautifulMermaid, so the library is isolated behind one defensive seam.

### New file `Lineform/Preview/DiagramLog.swift` (pure dedup + IO)
- `struct DiagramLogEntry: Codable, Equatable { let sourceHash: String; var sourceSnippet: String; var error: String; var appVersion: String; var count: Int; var lastSeen: Date }` — no file names/paths/identity.
- `enum DiagramLog { static func merge(_ existing: [DiagramLogEntry], adding: DiagramLogEntry, now: Date) -> [DiagramLogEntry] }` — dedup by `sourceHash`: bump `count` + `lastSeen` if present, else append (pure, tested).
- `final class DiagramLogStore` — reads/writes `DiagramLog/log.json` (Codable array) under `DiagramLog.directory(home:)`; `record(source:error:appVersion:)`, `exportReadable(to: URL)`, `clear()`. IO failure-tolerant; entries capped (`DiagramLog.maxEntries`, oldest-seen dropped) and repeat failures of the same source+error skip the rewrite within a session.

### Paths
`DiagramLog.relativePath = "Lineform/DiagramLog"` + `DiagramLog.directory(home:)` live in `DiagramLog.swift`, mirroring `LineformCLIPaths.pipedDirectory` (but deliberately not on `LineformCLIPaths` — that file is compiled standalone into the CLI helper, which never touches the diagram log).

### Preview renderer integration (`MarkdownPreviewRenderer`)
Restructure the fence handling: when an opening fence's info string is `mermaid`, collect the
fenced body until the closing fence, then instead of emitting monospaced lines:
- Ask a `MermaidImageProvider` (injected; default real) for the image using the active theme's
  bg/fg hex + Retina scale.
- `.image(img)` → append an `NSTextAttachment` whose image is sized to fit the column width
  (scale down if wider; never upscale), with the paragraph's spacing. Set accessibility:
  the attachment run gets `.accessibilityLabel("Mermaid diagram")` and
  `.accessibilityValue(<raw source>)` so VoiceOver reads the content.
- `.skipped` (size guard) or `.failed(err)` → **fallback**: a small caption **"Mermaid diagram
  (source)"** (secondary style) then the raw source as a monospaced code block (current
  behavior). On `.failed`, record to the `DiagramLogStore`.
- Write mode is untouched (source editor).

The renderer gains injected `mermaidProvider` + `diagramLog` (defaults to real instances) so
tests can pass fakes. Rendering is synchronous with an in-memory image cache (NSCache); the
size guard bounds cost and the 0.12 s preview debounce coalesces typing. (Async-off-main is a
deliberate future refinement — kept synchronous here to avoid unverifiable threading in a
blind integration; the fallback + cache keep it safe and responsive after first render.)

### Menu (`AppCommands` + `AppMenuConfiguration`)
Add **Export Diagram Log** (NSSavePanel → `DiagramLogStore.exportReadable`) and **Clear Diagram
Log** (`DiagramLogStore.clear`, with an NSAlert confirm), mirroring the Install-CLI item. Titles
as constants, asserted in `AppCommandNotificationTests`.

## Non-goals

- No WebView/JS rendering (library is native).
- No diagram editing, no live diagram interaction, no inner scrollviews (tall diagrams scroll
  with the document).
- No network reporting (that's unit 5; this is the *local* log only).
- No async-attachment pipeline (synchronous + cache for v1; see note above).
- No change to Write-mode source display or the syntax highlighter.

## Verification

1. **Build** (Debug + the packaging/Release build) resolves the SPM package and compiles.
   `xcodebuild build` (compile-only; does not launch the app).
2. **Deterministic tests** (written; run in the final pass): `MermaidBlockPolicy` size-guard
   boundary (20,000), `MermaidCacheKey` stability/uniqueness, `MermaidHexColor` conversion,
   `DiagramLog.merge` dedup + count bump, fence info-string detection, and the renderer's
   fallback path (inject a provider returning `.failed`/`.skipped` → assert caption + source +
   a log record). All pure/injected — no library, no WebView.
3. **Manual (final pass, in Xcode — prompt-free):** open a doc with a valid mermaid block in
   Read/Preview → diagram renders, themed to the reader theme, width-constrained, VoiceOver
   reads the source; a malformed block → "Mermaid diagram (source)" fallback + a log entry;
   Export/Clear Diagram Log work. Write mode shows source. Note anything not exercised.

## Risk / notes

- **Blind integration:** the library render call is isolated in `MermaidImageProvider` and
  wrapped in `try?`; any failure → `.failed` → safe fallback (source block) + log. Worst case
  the feature degrades to captioned source blocks — acceptable, never broken.
- **SPM resolution** needs network on first build; the exact pin (1.0.4) + `Package.resolved`
  keep it deterministic. elk-swift is transitive.
- **pbxproj SPM objects** follow the existing Sparkle pattern exactly — additive, no new target.
- **Sandbox**: diagram log writes to the container Application Support (no entitlement);
  Export uses the user-selected NSSavePanel grant.
