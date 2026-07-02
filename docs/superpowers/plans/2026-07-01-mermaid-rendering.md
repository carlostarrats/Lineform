# Mermaid Rendering + Diagram Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Checkbox steps.

**Goal:** Render ```mermaid blocks as native diagrams in Read/Preview via BeautifulMermaid, with a safe captioned-source fallback and a local deduped failure log; Export/Clear log menu items.

**Architecture:** Add the `BeautifulMermaid` SPM package (existing Sparkle pattern). Isolate the library behind one defensive wrapper (`MermaidImageProvider`, `try?` → fallback). Intercept ```mermaid fences in the NSAttributedString preview renderer → image attachment or captioned source fallback. Pure logic (size guard, cache key, hex color, log dedup) is unit-tested; the diagram log persists JSON under Application Support.

**Tech Stack:** Swift, AppKit, SwiftPM (BeautifulMermaid 1.0.4 + transitive elk-swift), XCTest, macOS 14+.

## Global Constraints
- Verify with `xcodebuild build` (compile only; NEVER `xcodebuild test` this session — see memory `cli-test-runs-cause-tcc-prompts`). Tests are written but run in the final pass.
- Rendering confined to Read + Preview by construction (only `MarkdownPreviewRenderer` changes; Write/source untouched).
- Library isolated in `MermaidImageProvider`; every render is `try?` → fallback. Size guard 20,000 chars.
- Diagram log: no file names/paths/identity — only source snippet, error, app version, count, last-seen; deduped by source hash. Under `~/Library/Application Support/Lineform/DiagramLog/`.
- SPM objects: replicate the Sparkle 5-object pattern with fresh IDs; `kind = exactVersion; version = "1.0.4"`. Let `xcodebuild -resolvePackageDependencies` populate `Package.resolved` (do not hand-write elk-swift).
- Spec: `docs/superpowers/specs/2026-07-01-mermaid-rendering-design.md`.

## New IDs (pbxproj)
- BuildFile `1F0000010000000000000203` (BeautifulMermaid in Frameworks)
- ProductDependency `1F0000130000000000000002` (BeautifulMermaid)
- PackageReference `1F0000140000000000000002` (XCRemoteSwiftPackageReference beautiful-mermaid-swift)
- Source files: `MermaidRendering.swift` 230, `DiagramLog.swift` 231; tests `MermaidRenderingTests.swift` 232, `DiagramLogTests.swift` 233.

---

### Task 1: Add the BeautifulMermaid SPM dependency
- [ ] Add PBXBuildFile after the Sparkle one (line 85):
  `1F0000010000000000000203 /* BeautifulMermaid in Frameworks */ = {isa = PBXBuildFile; productRef = 1F0000130000000000000002 /* BeautifulMermaid */; };`
- [ ] Add to the app Frameworks phase files (after the Sparkle entry):
  `1F0000010000000000000203 /* BeautifulMermaid in Frameworks */,`
- [ ] Add to target `packageProductDependencies` (after Sparkle):
  `1F0000130000000000000002 /* BeautifulMermaid */,`
- [ ] Add to project `packageReferences` (after Sparkle):
  `1F0000140000000000000002 /* XCRemoteSwiftPackageReference "beautiful-mermaid-swift" */,`
- [ ] Add XCRemoteSwiftPackageReference (in that section):
  ```
  1F0000140000000000000002 /* XCRemoteSwiftPackageReference "beautiful-mermaid-swift" */ = {
      isa = XCRemoteSwiftPackageReference;
      repositoryURL = "https://github.com/lukilabs/beautiful-mermaid-swift";
      requirement = { kind = exactVersion; version = 1.0.4; };
  };
  ```
- [ ] Add XCSwiftPackageProductDependency (in that section):
  ```
  1F0000130000000000000002 /* BeautifulMermaid */ = {
      isa = XCSwiftPackageProductDependency;
      package = 1F0000140000000000000002 /* XCRemoteSwiftPackageReference "beautiful-mermaid-swift" */;
      productName = BeautifulMermaid;
  };
  ```
- [ ] `plutil -lint` the pbxproj; then resolve: `xcodebuild -resolvePackageDependencies -project Lineform.xcodeproj -scheme Lineform 2>&1 | tail -20` (populates Package.resolved with beautiful-mermaid-swift + elk-swift). Expected: resolves without error.
- [ ] Commit: `git add Lineform.xcodeproj; git commit -m "Add BeautifulMermaid SPM dependency (1.0.4)"`

### Task 2: LineformCLIPaths — diagram log directory
- [ ] In `Lineform/CommandLineTool/LineformCommandLine.swift` `LineformCLIPaths`, add:
  ```swift
  static let diagramLogRelativePath = "Lineform/DiagramLog"
  static func diagramLogDirectory(home: URL) -> URL {
      home.appendingPathComponent("Library/Application Support", isDirectory: true)
          .appendingPathComponent(diagramLogRelativePath, isDirectory: true)
  }
  ```
- [ ] Add a test in `CommandLineToolTests.swift` for `diagramLogDirectory(home:)`.

### Task 3: Pure mermaid logic + library wrapper (`Lineform/Preview/MermaidRendering.swift`)
- [ ] Implement `MermaidHexColor.string(from:)`, `MermaidBlockPolicy` (maxSourceLength 20_000 + shouldAttemptRender), `MermaidCacheKey.key(...)`, `MermaidRenderOutcome`, `MermaidImageProvider` (imports BeautifulMermaid; NSCache; `try? MermaidRenderer.renderImage`). See spec for shapes.
- [ ] Tests `MermaidRenderingTests.swift`: size-guard boundary, cache-key stability/uniqueness, hex conversion (black→#000000, white→#ffffff, a known color).

### Task 4: Diagram log (`Lineform/Preview/DiagramLog.swift`)
- [ ] `DiagramLogEntry: Codable`, pure `DiagramLog.merge(_:adding:now:)` (dedup by sourceHash, bump count/lastSeen), `DiagramLogStore` (JSON at diagramLogDirectory; record/exportReadable/clear; failure-tolerant).
- [ ] Tests `DiagramLogTests.swift`: merge dedups + bumps count; distinct hashes append; exportReadable format (given entries → readable string) as a pure helper.

### Task 5: Preview renderer integration
- [ ] Refactor `MarkdownPreviewRenderer.render` to detect an opening fence whose info string is `mermaid`, collect the body until the closing fence, then emit either an image attachment (sized to column width, a11y label "Mermaid diagram" + value = source) via an injected `MermaidImageProvider`, or the captioned-source fallback (caption "Mermaid diagram (source)" + monospaced source) and `DiagramLogStore.record` on `.failed`.
- [ ] Inject `mermaidProvider: MermaidImageProvider = .init()` and `diagramLog: DiagramLogStore = .init()` into `render` (or the struct) with defaults; thread the container width from `MarkdownPreviewViewRepresentable`.
- [ ] Add a renderer test: inject a provider returning `.failed`/`.skipped` → assert the output contains the caption + source text and (for `.failed`) a log record via an injected fake log.

### Task 6: Export/Clear Diagram Log menu items
- [ ] `AppMenuConfiguration`: `exportDiagramLogCommandTitle = "Export Diagram Log..."`, `clearDiagramLogCommandTitle = "Clear Diagram Log..."`.
- [ ] `AppCommands` app-info group: two buttons calling a `DiagramLogStore` (NSSavePanel export; NSAlert-confirmed clear) — mirror the Install-CLI item / CommandLineToolInstaller alert style.
- [ ] Assert both titles in `AppCommandNotificationTests`.

### Task 7: Build + docs + index
- [ ] `xcodebuild build ...` → BUILD SUCCEEDED (also Release config once).
- [ ] Docs: CLAUDE.md Main Features + README (mermaid rendering; diagram log), credits (BeautifulMermaid MIT) in README/notices. Privacy.md: diagram log is local, no identity.
- [ ] Index: check off `- [x] 4 — Mermaid + local log`.
- [ ] Commit; merge to main; new branch.

## Notes
- All new source files need pbxproj entries (app target: MermaidRendering, DiagramLog; test target: the test files) — additive, IDs 230–233.
- Only `MermaidImageProvider` imports BeautifulMermaid.
- Do not run `xcodebuild test` this session; the final pass runs the suite.
