# Cross-File Search (All Files scope) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "All Files" scope to the existing native search field that renders content-search results as a transient read-only page over the current tab, opening picks like sidebar clicks.

**Architecture:** Pure match/snippet/rank logic in `CrossFileSearchResolver` (the `EditorSearchResolver` pattern); async debounced off-main file reading in `CrossFileSearchModel` (ObservableObject, latest-wins generation guard); presentation in `CrossFileSearchResultsView` overlaid in `EditorContainerView`'s existing `editorPrimaryShell` ZStack; entry via SwiftUI `.searchScopes` on the existing `.searchable` field.

**Tech Stack:** Swift / SwiftUI, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-17-cross-file-search-design.md` — read it first.

## Global Constraints

- **Never rebuild, wrap, or replace the native `.searchable` toolbar field with AppKit.** The only additions to it are `.searchScopes`. No styling attempts on the system scope bar.
- **iCloud-laziness invariant:** nothing scans iCloud at launch or view construction. The only scan trigger added is inside the All Files activation gesture, guarded by `fileBrowserStore.hasPerformedICloudScan` (the exact ⌘K pattern at `EditorContainerView.swift:253-256`).
- **No persisted index, no FSEvents watcher, no cross-file replace, no new menu items or keyboard shortcuts.**
- **pbxproj is hand-rolled** (objectVersion 56, no synced groups). Every new file is added by editing 4 sections with sequential `1F0000xx` IDs (template below). Build after every pbxproj edit.
- **Verification gate** (run from repo root; this is the default plan, ~370 tests, seconds):
  ```sh
  xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO
  ```
  **TCC caveat:** the ad-hoc re-signed test host may prompt "'Lineform' would like to access files in your Documents folder." Warn the user before the first test run of a session and wait for them to click Allow. Never assume an unattended run finished. For intermediate verification during a task, prefer build-only (`xcodebuild build … -quiet`) and run the test suite at task boundaries.
- Today's `git log` tip is `9e18d59` on branch `work-2026-07-18-4`.

### pbxproj 4-section template

To add a file `Foo.swift` with sequence ID `3B1` (app target; for test files the Sources
phase and group differ, noted per task):

1. **PBXBuildFile** section — after line containing `QuickOpenPalette.swift in Sources */ = {isa = PBXBuildFile`:
   `		1F00000100000000000003B1 /* Foo.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1F00000200000000000003B1 /* Foo.swift */; };`
2. **PBXFileReference** section — after line containing `QuickOpenPalette.swift */ = {isa = PBXFileReference`:
   `		1F00000200000000000003B1 /* Foo.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Foo.swift; sourceTree = "<group>"; };`
3. **Group children** — Editor group: after the line `1F00000200000000000003A8 /* QuickOpenPalette.swift */,`; LineformTests group: after `1F00000200000000000003A7 /* QuickOpenIndexTests.swift */,`.
4. **Sources build phase** — app target: after `1F00000100000000000003A8 /* QuickOpenPalette.swift in Sources */,`; tests target: after `1F00000100000000000003A7 /* QuickOpenIndexTests.swift in Sources */,`.

ID assignments for this plan (do not reuse):
- `3B1` `Lineform/Editor/CrossFileSearchResolver.swift` (app)
- `3B2` `LineformTests/CrossFileSearchResolverTests.swift` (tests)
- `3B3` `Lineform/Editor/CrossFileSearchModel.swift` (app)
- `3B4` `LineformTests/CrossFileSearchModelTests.swift` (tests)
- `3B5` `Lineform/Editor/CrossFileSearchResultsView.swift` (app)

---

### Task 1: CrossFileSearchResolver (pure logic)

**Files:**
- Create: `Lineform/Editor/CrossFileSearchResolver.swift`
- Create: `LineformTests/CrossFileSearchResolverTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj` (IDs `3B1` app, `3B2` tests — template above)

**Interfaces:**
- Consumes: `QuickOpenEntry` (`Lineform/Outline/QuickOpenIndex.swift:4` — fields `id: String`, `url: URL`, `name: String`, `relativePath: String`, `rootTitle: String`), `EditorSearchResolver.matches(in:query:)` (`Lineform/Editor/EditorSearchResolver.swift` — literal, case- and diacritic-insensitive, trims the query, returns `[NSRange]`).
- Produces (later tasks rely on these exact signatures):
  - `struct CrossFileSearchSnippet: Equatable { let lineText: String; let matchRange: NSRange }`
  - `struct CrossFileSearchResult: Identifiable, Equatable { let id: String; let url: URL; let name: String; let relativePath: String; let rootTitle: String; let matchCount: Int; let snippet: CrossFileSearchSnippet }`
  - `CrossFileSearchResolver.result(for entry: QuickOpenEntry, text: String, query: String) -> CrossFileSearchResult?`
  - `CrossFileSearchResolver.ranked(_ results: [CrossFileSearchResult]) -> [CrossFileSearchResult]`

- [ ] **Step 1: Register both new (still empty) files in pbxproj**

Create the two files with a bare `import Foundation` line each, then apply the 4-section template for `3B1` (app) and `3B2` (tests).

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -quiet`
Expected: no errors.

- [ ] **Step 2: Write the failing tests**

Full contents of `LineformTests/CrossFileSearchResolverTests.swift`:

```swift
import XCTest
@testable import Lineform

final class CrossFileSearchResolverTests: XCTestCase {
    private func entry(name: String = "notes.md", relativePath: String = "projects/notes.md") -> QuickOpenEntry {
        QuickOpenEntry(
            id: "/tmp/\(relativePath)",
            url: URL(fileURLWithPath: "/tmp/\(relativePath)"),
            name: name,
            relativePath: relativePath,
            rootTitle: "Workspace"
        )
    }

    func testFindsLiteralMatchWithCountAndFirstLineSnippet() {
        let text = "# Title\nThe launch plan is here.\nlaunch again"
        let result = CrossFileSearchResolver.result(for: entry(), text: text, query: "launch")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.matchCount, 2)
        XCTAssertEqual(result?.snippet.lineText, "The launch plan is here.")
        XCTAssertEqual(result?.snippet.matchRange, NSRange(location: 4, length: 6))
        XCTAssertEqual(result?.name, "notes.md")
        XCTAssertEqual(result?.rootTitle, "Workspace")
    }

    func testMatchingIsCaseAndDiacriticInsensitiveLikeInFileSearch() {
        let text = "Café LAUNCH day"
        XCTAssertEqual(CrossFileSearchResolver.result(for: entry(), text: text, query: "cafe launch")?.matchCount, 1)
        // Must agree with EditorSearchResolver on the same inputs.
        XCTAssertEqual(
            CrossFileSearchResolver.result(for: entry(), text: text, query: "cafe launch")?.matchCount,
            EditorSearchResolver.matches(in: text, query: "cafe launch").count
        )
    }

    func testNoMatchReturnsNilAndEmptyQueryReturnsNil() {
        XCTAssertNil(CrossFileSearchResolver.result(for: entry(), text: "nothing here", query: "absent"))
        XCTAssertNil(CrossFileSearchResolver.result(for: entry(), text: "anything", query: "   "))
    }

    func testLongLineSnippetIsElidedAroundTheMatch() {
        let prefix = String(repeating: "a", count: 200)
        let suffix = String(repeating: "b", count: 200)
        let text = prefix + " needle " + suffix
        let result = CrossFileSearchResolver.result(for: entry(), text: text, query: "needle")
        XCTAssertNotNil(result)
        let snippet = result!.snippet
        XCTAssertLessThanOrEqual(snippet.lineText.count, 124) // 120 cap + up to two "…"
        // The reported range must still point at "needle" within the elided line.
        let found = (snippet.lineText as NSString).substring(with: snippet.matchRange)
        XCTAssertEqual(found.lowercased(), "needle")
    }

    func testSnippetComesFromFirstMatchingLineAndStripsTrailingNewline() {
        let text = "first needle line\nsecond needle line\n"
        let result = CrossFileSearchResolver.result(for: entry(), text: text, query: "needle")
        XCTAssertEqual(result?.snippet.lineText, "first needle line")
    }

    func testRankedOrdersByMatchCountThenNameThenPath() {
        func make(_ name: String, _ path: String, _ count: Int) -> CrossFileSearchResult {
            CrossFileSearchResult(
                id: path, url: URL(fileURLWithPath: "/\(path)"), name: name,
                relativePath: path, rootTitle: "Workspace", matchCount: count,
                snippet: CrossFileSearchSnippet(lineText: "x", matchRange: NSRange(location: 0, length: 1))
            )
        }
        let ranked = CrossFileSearchResolver.ranked([
            make("b.md", "b.md", 1),
            make("a.md", "z/a.md", 1),
            make("a.md", "a/a.md", 1),
            make("c.md", "c.md", 5),
        ])
        XCTAssertEqual(ranked.map(\.relativePath), ["c.md", "a/a.md", "z/a.md", "b.md"])
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/CrossFileSearchResolverTests 2>&1 | tail -20`
Expected: compile FAILURE ("cannot find 'CrossFileSearchResolver' in scope"). (First test run of the session: warn the user about the possible TCC prompt.)

- [ ] **Step 4: Write the implementation**

Full contents of `Lineform/Editor/CrossFileSearchResolver.swift`:

```swift
import Foundation

/// One line of context around a cross-file match. `matchRange` locates the query hit
/// WITHIN `lineText` (post-elision), so the UI can emphasize it.
struct CrossFileSearchSnippet: Equatable {
    let lineText: String
    let matchRange: NSRange
}

/// One file's cross-file search result.
struct CrossFileSearchResult: Identifiable, Equatable {
    let id: String            // full URL path — the OutlineFileTreeItem.id rule
    let url: URL
    let name: String
    let relativePath: String
    let rootTitle: String
    let matchCount: Int
    let snippet: CrossFileSearchSnippet
}

/// Pure per-file matching + ranking behind the All Files search scope. Matching reuses
/// `EditorSearchResolver.matches` (literal, case- and diacritic-insensitive, trimmed
/// query) so cross-file search agrees with in-file search by construction. No I/O —
/// callers supply the file text. The `EditorSearchResolver` pattern: fully unit-testable.
enum CrossFileSearchResolver {
    /// Longest snippet line shown before eliding around the match.
    static let snippetMaximumLength = 120

    static func result(for entry: QuickOpenEntry, text: String, query: String) -> CrossFileSearchResult? {
        let matches = EditorSearchResolver.matches(in: text, query: query)
        guard let first = matches.first else { return nil }
        return CrossFileSearchResult(
            id: entry.id,
            url: entry.url,
            name: entry.name,
            relativePath: entry.relativePath,
            rootTitle: entry.rootTitle,
            matchCount: matches.count,
            snippet: snippet(in: text, around: first)
        )
    }

    /// Display order: most matches first, then name, then relative path — the
    /// QuickOpenIndex stable/deterministic tie-break style.
    static func ranked(_ results: [CrossFileSearchResult]) -> [CrossFileSearchResult] {
        results.sorted { lhs, rhs in
            if lhs.matchCount != rhs.matchCount { return lhs.matchCount > rhs.matchCount }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.relativePath < rhs.relativePath
        }
    }

    /// The first match's line, whitespace-trimmed, elided to `snippetMaximumLength`
    /// characters centered on the match when the line is longer. The returned range
    /// re-locates the match within the (possibly elided) snippet text.
    static func snippet(in text: String, around match: NSRange) -> CrossFileSearchSnippet {
        let nsText = text as NSString
        let lineRange = nsText.lineRange(for: match)
        var line = nsText.substring(with: lineRange) as NSString
        var matchInLine = NSRange(location: match.location - lineRange.location, length: match.length)

        // Strip the trailing newline (and any trailing whitespace) without disturbing
        // the match offset, then strip leading whitespace and shift the offset.
        let trimmedTrailing = (line as String).replacingOccurrences(
            of: "\\s+$", with: "", options: .regularExpression
        ) as NSString
        line = trimmedTrailing
        let leadingTrimmed = (line as String).replacingOccurrences(
            of: "^\\s+", with: "", options: .regularExpression
        ) as NSString
        let leadingRemoved = line.length - leadingTrimmed.length
        line = leadingTrimmed
        matchInLine.location = max(0, matchInLine.location - leadingRemoved)
        matchInLine.length = min(matchInLine.length, max(0, line.length - matchInLine.location))

        guard line.length > snippetMaximumLength else {
            return CrossFileSearchSnippet(lineText: line as String, matchRange: matchInLine)
        }

        // Center a window of snippetMaximumLength characters on the match.
        let half = (snippetMaximumLength - matchInLine.length) / 2
        var start = max(0, matchInLine.location - half)
        if start + snippetMaximumLength > line.length {
            start = max(0, line.length - snippetMaximumLength)
        }
        let window = NSRange(location: start, length: min(snippetMaximumLength, line.length - start))
        var display = line.substring(with: window)
        var shifted = NSRange(location: matchInLine.location - start, length: matchInLine.length)
        if start > 0 {
            display = "…" + display
            shifted.location += 1
        }
        if window.location + window.length < line.length {
            display += "…"
        }
        shifted.length = min(shifted.length, max(0, (display as NSString).length - shifted.location))
        return CrossFileSearchSnippet(lineText: display, matchRange: shifted)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/CrossFileSearchResolverTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 6 tests passing. If the elision math fails a boundary assertion, fix the implementation — do not loosen the test.

- [ ] **Step 6: Commit**

```bash
git add Lineform/Editor/CrossFileSearchResolver.swift LineformTests/CrossFileSearchResolverTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add CrossFileSearchResolver: pure per-file match/snippet/rank logic"
```

---

### Task 2: CrossFileSearchModel (async orchestration)

**Files:**
- Create: `Lineform/Editor/CrossFileSearchModel.swift`
- Create: `LineformTests/CrossFileSearchModelTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj` (IDs `3B3` app, `3B4` tests)

**Interfaces:**
- Consumes: Task 1's `CrossFileSearchResolver.result(for:text:query:)` / `.ranked(_:)` / `CrossFileSearchResult`; `QuickOpenEntry`.
- Produces (Task 3 relies on these):
  - `enum EditorSearchScope: Hashable { case thisFile, allFiles }`
  - `protocol CrossFileSearchFileReading: Sendable { func readSearchableText(at url: URL) -> String? }`
  - `struct CrossFileSearchFileReader: CrossFileSearchFileReading` (production reader: skips iCloud-evicted and >1 MB files)
  - `@MainActor final class CrossFileSearchModel: ObservableObject` with `@Published private(set) var results: [CrossFileSearchResult]`, `@Published private(set) var isSearching: Bool`, `init(reader: CrossFileSearchFileReading = CrossFileSearchFileReader(), debounceInterval: TimeInterval = 0.3)`, `@discardableResult func search(query: String, entries: [QuickOpenEntry]) -> Task<Void, Never>?`, `func reset()`

- [ ] **Step 1: Register both new (empty, `import Foundation`) files in pbxproj (IDs `3B3`, `3B4`), verify build**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -quiet`
Expected: no errors.

- [ ] **Step 2: Write the failing tests**

Full contents of `LineformTests/CrossFileSearchModelTests.swift`:

```swift
import XCTest
@testable import Lineform

/// Injectable reader over an in-memory corpus — no disk, no iCloud.
private struct StubReader: CrossFileSearchFileReading {
    let texts: [String: String]   // keyed by URL path
    func readSearchableText(at url: URL) -> String? { texts[url.path] }
}

@MainActor
final class CrossFileSearchModelTests: XCTestCase {
    private func entry(_ path: String) -> QuickOpenEntry {
        QuickOpenEntry(
            id: path, url: URL(fileURLWithPath: path),
            name: (path as NSString).lastPathComponent,
            relativePath: String(path.dropFirst()), rootTitle: "Workspace"
        )
    }

    func testSearchPublishesRankedResultsAcrossTheCorpus() async {
        let reader = StubReader(texts: [
            "/a.md": "needle once",
            "/b.md": "needle and needle again",
            "/c.md": "nothing relevant",
        ])
        let model = CrossFileSearchModel(reader: reader, debounceInterval: 0)
        await model.search(query: "needle", entries: [entry("/a.md"), entry("/b.md"), entry("/c.md")])?.value
        XCTAssertEqual(model.results.map(\.name), ["b.md", "a.md"])
        XCTAssertEqual(model.results.first?.matchCount, 2)
        XCTAssertFalse(model.isSearching)
    }

    func testUnreadableFilesAreSkippedSilently() async {
        let reader = StubReader(texts: ["/a.md": "needle"])   // /gone.md reads nil
        let model = CrossFileSearchModel(reader: reader, debounceInterval: 0)
        await model.search(query: "needle", entries: [entry("/gone.md"), entry("/a.md")])?.value
        XCTAssertEqual(model.results.map(\.name), ["a.md"])
    }

    func testEmptyQueryClearsResultsWithoutSearching() async {
        let model = CrossFileSearchModel(reader: StubReader(texts: [:]), debounceInterval: 0)
        await model.search(query: "needle", entries: [])?.value
        XCTAssertNil(model.search(query: "   ", entries: [entry("/a.md")]))
        XCTAssertEqual(model.results, [])
        XCTAssertFalse(model.isSearching)
    }

    func testStaleSearchNeverPublishesOverANewerOne() async {
        let reader = StubReader(texts: ["/old.md": "alpha", "/new.md": "beta"])
        let model = CrossFileSearchModel(reader: reader, debounceInterval: 0)
        let stale = model.search(query: "alpha", entries: [entry("/old.md")])
        let fresh = model.search(query: "beta", entries: [entry("/new.md")])
        await stale?.value
        await fresh?.value
        XCTAssertEqual(model.results.map(\.name), ["new.md"])
    }

    func testResetClearsResultsAndCancelsInFlightWork() async {
        let reader = StubReader(texts: ["/a.md": "needle"])
        let model = CrossFileSearchModel(reader: reader, debounceInterval: 0)
        let task = model.search(query: "needle", entries: [entry("/a.md")])
        model.reset()
        await task?.value
        XCTAssertEqual(model.results, [])
        XCTAssertFalse(model.isSearching)
    }

    func testProductionReaderSkipsOversizedFilesAndReadsNormalOnes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossFileSearchModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let normal = directory.appendingPathComponent("normal.md")
        try "hello needle".write(to: normal, atomically: true, encoding: .utf8)
        let huge = directory.appendingPathComponent("huge.md")
        try String(repeating: "x", count: 1_100_000).write(to: huge, atomically: true, encoding: .utf8)

        let reader = CrossFileSearchFileReader()
        XCTAssertEqual(reader.readSearchableText(at: normal), "hello needle")
        XCTAssertNil(reader.readSearchableText(at: huge))
        XCTAssertNil(reader.readSearchableText(at: directory.appendingPathComponent("absent.md")))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/CrossFileSearchModelTests 2>&1 | tail -20`
Expected: compile FAILURE ("cannot find 'CrossFileSearchFileReading' in scope").

- [ ] **Step 4: Write the implementation**

Full contents of `Lineform/Editor/CrossFileSearchModel.swift`:

```swift
import Foundation

/// Which universe the toolbar search field is searching. `.thisFile` is the settled
/// in-document behavior; `.allFiles` drives the cross-file results page.
enum EditorSearchScope: Hashable {
    case thisFile
    case allFiles
}

/// Reads one candidate file's text for cross-file search, or nil to skip it.
/// Abstracted (the UbiquitousItemDownloader pattern) so tests use an in-memory corpus.
protocol CrossFileSearchFileReading: Sendable {
    func readSearchableText(at url: URL) -> String?
}

/// Production reader. Skips: iCloud-evicted (dataless) files — searching them would
/// force-download the container; files over `maximumByteCount` (1 MB — far beyond any
/// real Markdown document) so one giant stray file can't stall a scan; anything
/// unreadable or non-UTF-8.
struct CrossFileSearchFileReader: CrossFileSearchFileReading {
    static let maximumByteCount = 1_048_576

    func readSearchableText(at url: URL) -> String? {
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = values.ubiquitousItemDownloadingStatus,
           status != .current {
            return nil
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= Self.maximumByteCount else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// Debounced, cancellable, latest-wins orchestration for the All Files scope: reads each
/// candidate file off the main thread, matches via CrossFileSearchResolver, and publishes
/// ranked results on the main actor. Owns no watcher and touches no view — constructed by
/// EditorContainerView, reset whenever the scope leaves `.allFiles` or the document swaps.
@MainActor
final class CrossFileSearchModel: ObservableObject {
    @Published private(set) var results: [CrossFileSearchResult] = []
    @Published private(set) var isSearching = false

    private let reader: CrossFileSearchFileReading
    private let debounceInterval: TimeInterval
    private var generation = 0
    private var pendingTask: Task<Void, Never>?

    init(reader: CrossFileSearchFileReading = CrossFileSearchFileReader(), debounceInterval: TimeInterval = 0.3) {
        self.reader = reader
        self.debounceInterval = debounceInterval
    }

    /// Latest-wins (the ICloudSettingViewModel generation-guard pattern): each call bumps
    /// the generation and cancels the prior task; a stale task re-checks before publishing.
    /// Returns the search task so tests can await it; nil when the query is empty.
    @discardableResult
    func search(query: String, entries: [QuickOpenEntry]) -> Task<Void, Never>? {
        generation += 1
        let expected = generation
        pendingTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return nil
        }

        isSearching = true
        let reader = reader
        let interval = debounceInterval
        let task = Task { [weak self] in
            if interval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { () -> [CrossFileSearchResult] in
                var collected: [CrossFileSearchResult] = []
                for entry in entries {
                    guard !Task.isCancelled else { return collected }
                    guard let text = reader.readSearchableText(at: entry.url) else { continue }
                    if let result = CrossFileSearchResolver.result(for: entry, text: text, query: trimmed) {
                        collected.append(result)
                    }
                }
                return CrossFileSearchResolver.ranked(collected)
            }.value
            guard let self, !Task.isCancelled else { return }
            guard self.generation == expected else { return }
            self.results = found
            self.isSearching = false
        }
        pendingTask = task
        return task
    }

    func reset() {
        generation += 1
        pendingTask?.cancel()
        pendingTask = nil
        results = []
        isSearching = false
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/CrossFileSearchModelTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`, 6 tests passing.

- [ ] **Step 6: Commit**

```bash
git add Lineform/Editor/CrossFileSearchModel.swift LineformTests/CrossFileSearchModelTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add CrossFileSearchModel: debounced off-main cross-file scan with latest-wins guard"
```

---

### Task 3: Results page view + EditorContainerView wiring

**Files:**
- Create: `Lineform/Editor/CrossFileSearchResultsView.swift`
- Modify: `Lineform/Editor/EditorContainerView.swift` (exact anchors below)
- Modify: `Lineform.xcodeproj/project.pbxproj` (ID `3B5` app)

**Interfaces:**
- Consumes: Task 1's `CrossFileSearchResult`/`CrossFileSearchSnippet`, Task 2's `EditorSearchScope`/`CrossFileSearchModel`; existing `QuickOpenIndex.flatten`, `openSidebarFile(_:)` (`EditorContainerView.swift:887`), `currentTheme: Theme` (`.backgroundColor`, `.textColor`, `.usesDarkChrome` — see `EditorContainerView.swift:638`), `fileBrowserStore.hasPerformedICloudScan` / `.refreshICloud()` / `.refreshWorkspace()`.
- Produces: the user-facing feature. No later task consumes code from this one.

- [ ] **Step 1: Register `CrossFileSearchResultsView.swift` (empty, `import SwiftUI`) in pbxproj (ID `3B5`), verify build**

- [ ] **Step 2: Write the results page view**

Full contents of `Lineform/Editor/CrossFileSearchResultsView.swift`:

```swift
import SwiftUI

/// The All Files search results page: a transient, READ-ONLY layer over the current tab's
/// content area (never a floating card — that was explicitly rejected in brainstorming as
/// convoluted). Opaque theme background, editor-family typography, one row per matching
/// file. Clicking a row is a sidebar-click-equivalent open; Esc dismisses. This view never
/// takes text input — typing stays in the toolbar search field.
struct CrossFileSearchResultsView: View {
    let query: String
    let results: [CrossFileSearchResult]
    let isSearching: Bool
    let theme: Theme
    var onOpen: (CrossFileSearchResult) -> Void
    var onDismiss: () -> Void

    @State private var hoveredResultID: String?

    static let columnMaximumWidth: CGFloat = 560

    private var primaryColor: Color { Color(nsColor: theme.textColor) }
    private var secondaryColor: Color { primaryColor.opacity(0.55) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .frame(maxWidth: Self.columnMaximumWidth, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: theme.backgroundColor))
        .onExitCommand { onDismiss() }
        .accessibilityLabel("All files search results")
    }

    private var header: some View {
        Text(headerText)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(secondaryColor)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerText: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Search All Files" }
        if isSearching && results.isEmpty { return "Searching…" }
        let files = results.count == 1 ? "1 file" : "\(results.count) files"
        return "\(files) matching \u{201C}\(trimmed)\u{201D}"
    }

    @ViewBuilder
    private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            hint("Type to search all files…")
        } else if results.isEmpty && !isSearching {
            hint("No matches in any file.")
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(results) { result in
                    resultRow(result)
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(secondaryColor)
    }

    private func resultRow(_ result: CrossFileSearchResult) -> some View {
        Button {
            onOpen(result)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(result.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primaryColor)
                    Text(result.relativePath)
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(result.matchCount == 1 ? "1 match" : "\(result.matchCount) matches")
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryColor)
                }
                Text(snippetText(result.snippet))
                    .font(.system(size: 12.5))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hoveredResultID == result.id ? primaryColor.opacity(0.06) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredResultID = hovering ? result.id : (hoveredResultID == result.id ? nil : hoveredResultID)
        }
        .accessibilityLabel(accessibilityText(result))
    }

    /// The snippet line with the matched substring emphasized (semibold, primary color).
    private func snippetText(_ snippet: CrossFileSearchSnippet) -> AttributedString {
        var attributed = AttributedString(snippet.lineText)
        let nsLine = snippet.lineText as NSString
        guard snippet.matchRange.location != NSNotFound,
              NSMaxRange(snippet.matchRange) <= nsLine.length,
              let range = Range(snippet.matchRange, in: attributed) else {
            return attributed
        }
        attributed[range].font = .system(size: 12.5, weight: .semibold)
        attributed[range].foregroundColor = primaryColor
        return attributed
    }

    private func accessibilityText(_ result: CrossFileSearchResult) -> String {
        let matches = result.matchCount == 1 ? "1 match" : "\(result.matchCount) matches"
        return "\(result.name), \(result.relativePath), \(matches)"
    }
}
```

- [ ] **Step 3: Wire the scope into EditorContainerView**

All edits in `Lineform/Editor/EditorContainerView.swift` (line anchors are from commit `9e18d59` — re-locate by content if drifted):

**3a. State (after `@State private var searchQuery = ""`, line 21):**

```swift
    @State private var searchScope: EditorSearchScope = .thisFile
    @StateObject private var crossFileSearchModel = CrossFileSearchModel()
```

**3b. Scope bar (directly under `.searchable(text: $searchQuery, placement: .toolbar, prompt: "Search")`, line 198):**

```swift
        .searchScopes($searchScope) {
            Text("This File").tag(EditorSearchScope.thisFile)
            Text("All Files").tag(EditorSearchScope.allFiles)
        }
```

**3c. Query changes (replace the existing `.onChange(of: searchQuery)` body at line 483-485):**

```swift
        .onChange(of: searchQuery) { _, _ in
            if searchScope == .allFiles {
                updateCrossFileSearch()
            } else {
                refreshSearchMatches(selectFirstWhenNeeded: true, navigatesToActiveMatch: true)
            }
        }
```

**3d. Scope changes (new modifier, directly after the `.onChange(of: searchQuery)` block):**

```swift
        .onChange(of: searchScope) { _, newScope in
            switch newScope {
            case .allFiles:
                // Entering All Files: stop the in-file highlight machinery and, first time
                // in this window session, trigger the deferred scans — the same explicit
                // user-gesture trigger ⌘K uses, so the iCloud-laziness invariant holds.
                searchMatches = []
                activeSearchIndex = nil
                if !fileBrowserStore.hasPerformedICloudScan {
                    fileBrowserStore.refreshICloud()
                    fileBrowserStore.refreshWorkspace()
                }
                updateCrossFileSearch()
            case .thisFile:
                crossFileSearchModel.reset()
                refreshSearchMatches(selectFirstWhenNeeded: true, navigatesToActiveMatch: false)
            }
        }
```

**3e. Return key (replace the `.onSubmit(of: .search)` body at line 486-488 — Return keeps its next-match meaning only in This File scope; in All Files it does nothing in v1):**

```swift
        .onSubmit(of: .search) {
            guard searchScope == .thisFile else { return }
            advanceToNextSearchMatch()
        }
```

**3f. The results page overlay (in `editorPrimaryShell`'s `ZStack(alignment: .top)`, directly AFTER the `if isShowingFindReplace && displayMode != .read { … }` block that ends near line 626):**

```swift
            // All Files search results: a transient READ-ONLY page over the content area
            // (spec: never a floating card, never a laid-out top strip — as a full-bleed
            // opaque layer inside the existing ZStack it leaves the top-edge hierarchy
            // unchanged, so the translucent toolbar's sampled color cannot shift).
            if searchScope == .allFiles {
                CrossFileSearchResultsView(
                    query: searchQuery,
                    results: crossFileSearchModel.results,
                    isSearching: crossFileSearchModel.isSearching,
                    theme: currentTheme,
                    onOpen: { result in
                        openSidebarFile(result.url)
                        clearAllSearchState()
                    },
                    onDismiss: { clearAllSearchState() }
                )
            }
```

**3g. The clean-slate helper (new function, place directly after `resetTransientDocumentState()` which starts at line 1277):**

```swift
    /// Locked spec behavior: after opening a cross-file result (or backing out), NO search
    /// residue may remain anywhere — empty query, no highlights, scope back to This File
    /// (which also dismisses the results page and, because search deactivates, the system
    /// scope bar), search focus resigned.
    private func clearAllSearchState() {
        searchQuery = ""
        searchMatches = []
        activeSearchIndex = nil
        searchScope = .thisFile
        crossFileSearchModel.reset()
        isSearchFocused = false
    }
```

**3h. Document-swap cleanup (inside `resetTransientDocumentState()`, after the `quickOpenQuery = ""` line):**

```swift
        searchScope = .thisFile
        crossFileSearchModel.reset()
```

- [ ] **Step 4: Build and run the full default test gate**

Run: `xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -quiet` then the full gate:
`xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`. The existing search/find-replace tests must stay green — if any fail, the wiring changed settled behavior; fix the wiring, never the settled tests.

- [ ] **Step 5: Commit**

```bash
git add Lineform/Editor/CrossFileSearchResultsView.swift Lineform/Editor/EditorContainerView.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add All Files search scope: results page over content, sidebar-click opens"
```

---

### Task 4: Docs + manual QA handoff

**Files:**
- Modify: `CLAUDE.md` (the Main Features bullet list)
- No code changes. (If QA finds issues, fix in follow-up commits on this branch.)

**Interfaces:** none — documentation and verification only.

- [ ] **Step 1: Add the feature bullet to CLAUDE.md**

In the `## Main Features` list, directly after the "Find & Replace" bullet, add:

```markdown
- Cross-file search (All Files scope): the native toolbar search field gains SwiftUI `.searchScopes` — **This File** (default, the settled in-document search) and **All Files**, which renders a transient READ-ONLY results page over the current tab's content area (`CrossFileSearchResultsView`; never a floating card and never a laid-out top strip — the toolbar-sampling rule) listing every scanned Workspace/iCloud file whose *contents* contain the query (one row per file: name, relative path, first-match snippet with the hit emphasized, match count; ranked by match count via `CrossFileSearchResolver.ranked`). Matching reuses `EditorSearchResolver.matches` (literal, case- and diacritic-insensitive) so cross-file agrees with in-file search by construction; ranking/snippets are pure tested logic in `Lineform/Editor/CrossFileSearchResolver.swift`; `CrossFileSearchModel` reads candidate files off-main (0.3s debounce, latest-wins generation guard, skips iCloud-evicted and >1 MB files) with no persisted index and no FSEvents watcher (candidates = the store's last scan, the ⌘K universe incl. the 80-per-folder cap; first All Files activation triggers the deferred iCloud scan exactly like ⌘K, so the laziness invariant holds). Clicking a result opens via `openSidebarFile` (new tab / switch to existing) and then `clearAllSearchState()` wipes ALL search residue (query, highlights, scope back to This File — which also dismisses the system scope bar); Esc and document swaps do the same. The scope bar is system-drawn and deliberately unstyled; the search field itself is never wrapped or rebuilt. No cross-file replace, no saved searches, no new shortcuts (deliberate). See `docs/superpowers/specs/2026-07-17-cross-file-search-design.md`.
```

- [ ] **Step 2: Launch the real app for user QA**

Build and launch the FRESH Debug product (never `open -a Lineform` — stale-copy gotcha):

```bash
cd "/Users/carlostarrats/Documents/Projects/Lineform Bundle/Lineform"
xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -quiet
pkill -x Lineform; sleep 1
open "$(xcodebuild -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/Lineform.app"
```

Ask the user to drive this checklist (agent cannot type/click in the app — TCC):

1. Click into search → scope bar appears with This File / All Files; This File search behaves exactly as before (yellow highlights, Return steps matches).
2. Switch to All Files, type a word known to exist in several workspace files → results page replaces the content area, rows show name/path/snippet/count, list updates while typing.
3. Click a result → opens in a new tab (or switches to the existing tab); search field empty, no scope bar, no highlights, original tab shows its document untouched.
4. All Files → Esc → document returns exactly as it was; scope bar gone on next search-field click (This File preselected).
5. Repeat 2 in Read mode and Split mode → page overlays correctly, mode preserved on dismiss.
6. Dark theme (Quiet/Night) → results page uses the theme background/ink.
7. Narrow window (< 840pt) → scope bar + compact toolbar coexist sanely.

- [ ] **Step 3: Commit docs (and any QA fixes)**

```bash
git add CLAUDE.md
git commit -m "Document the All Files cross-file search scope"
```

---

## Self-Review Notes

- Spec coverage: entry/scope bar (Task 3b), transient read-only page (3f + view), sidebar-click open (3f), clean-slate on jump/Esc/swap (3g/3h), This-File-only Return (3e), no forced mode switch (nothing touches `displayMode`), scan guard (3d), eviction + size skip (Task 2 reader), matching parity (Task 1 delegates to `EditorSearchResolver.matches`), ranking (Task 1), states (view `content`), accessibility (view labels), tests split pure-vs-manual per spec.
- Deliberately not implemented (spec "Not in scope"): keyboard nav of the page, new shortcuts/menu items, watcher, index, replace.
- Type names cross-checked across tasks: `CrossFileSearchSnippet`/`CrossFileSearchResult`/`CrossFileSearchResolver`/`CrossFileSearchFileReading`/`CrossFileSearchFileReader`/`CrossFileSearchModel`/`EditorSearchScope`/`CrossFileSearchResultsView`/`clearAllSearchState()` — consistent.
