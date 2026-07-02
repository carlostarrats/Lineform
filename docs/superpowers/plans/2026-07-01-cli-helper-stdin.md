# CLI Helper + stdin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship a bundled `lineform` command-line helper that opens files and stdin in the app, an installer menu item, and 7-day Piped-folder housekeeping — with all logic unit-tested and no new Xcode target.

**Architecture:** Pure, Foundation-only CLI logic lives in the app module (`Lineform/CommandLineTool/`) so tests reach it via `@testable import Lineform`. The helper entry point is a standalone `HelperTool/main.swift` (in no Xcode target) compiled + universal-lipo'd + signed by `packaging/build-release.sh` into `Lineform.app/Contents/Helpers/lineform`. The install menu item + Piped housekeeping are app-side. No new Xcode target → only safe additive `project.pbxproj` file entries.

**Tech Stack:** Swift, Foundation, AppKit (app-side only), `swiftc`/`lipo`/`codesign` (packaging), XCTest, macOS 14+.

## Global Constraints

- Verification gate (serial, per CLAUDE.md; machine quiet so the two hosted animation tests don't flake):
  `xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO`
- NO new Xcode target and NO new config list — only additive `PBXBuildFile`/`PBXFileReference`/group/Sources entries for the app + test targets (same pattern as units 1–2). Use fresh `1F0000010000000000000220`+ style IDs (highest existing suffix is ~214).
- Pure CLI logic must be Foundation-only and side-effect-free (no AppKit) so `swiftc` compiles it standalone for the helper.
- Helper ships WITHOUT the App Sandbox entitlement; app entitlements unchanged.
- Piped folder: `~/Library/Application Support/Lineform/Piped/`. All Piped IO must be failure-tolerant (never crash launch).
- Exact error strings (asserted in tests): `lineform: no such file: <path>`, `lineform: <path> is a directory (not supported yet)`, `lineform: empty input`, `lineform: input is not text`, and a >10MB message `lineform: input too large (limit 10 MB)`.
- Spec: `docs/superpowers/specs/2026-07-01-cli-helper-stdin-design.md`. Index: `docs/superpowers/specs/2026-07-01-agent-reader-decomposition.md`.

## File structure

**Create:**
- `Lineform/CommandLineTool/LineformCommandLine.swift` — pure logic (app target + compiled by packaging script). Types: `LineformCLICommand`, `LineformPipeValidation`, `LineformPipedHousekeeping`, `LineformCLIPaths`, `LineformCLIMessages`.
- `HelperTool/main.swift` — thin entry point, NOT in any Xcode target.
- `Lineform/App/CommandLineToolInstaller.swift` — app-side NSSavePanel + symlink (app target).
- `LineformTests/CommandLineToolTests.swift` — pure-logic tests (test target).

**Modify:**
- `Lineform/App/AppCommands.swift` + `AppMenuConfiguration` — add the Install menu item + title.
- `Lineform/App/FirstLaunchIntroOverlay.swift` (`LineformAppDelegate`) — Piped housekeeping on launch.
- `LineformTests/AppCommandNotificationTests.swift` — assert the new menu title constant.
- `packaging/build-release.sh` — build/lipo/sign the helper; universal check.
- `docs/release/github-sparkle-release.md`, `Lineform/Resources/Privacy.md`, `CLAUDE.md`, `README.md` — docs.
- `Lineform.xcodeproj/project.pbxproj` — add the 3 app/test files (NOT main.swift).

---

### Task 1: Pure CLI logic + tests

**Files:**
- Create: `Lineform/CommandLineTool/LineformCommandLine.swift`, `LineformTests/CommandLineToolTests.swift`
- Modify: `Lineform.xcodeproj/project.pbxproj`

**Interfaces (Produces):**
- `enum LineformCLICommand: Equatable { case open([String]); case readStdin; case version; case help; case invalid(String) }` + `static func parse(_ args: [String]) -> LineformCLICommand`
- `enum LineformPipeValidation: Equatable { case ok; case empty; case tooLarge; case notText }` + `static func validate(_ data: Data, maxBytes: Int = 10_000_000) -> LineformPipeValidation`
- `enum LineformCLIPaths { static let pipedRelativePath = "Lineform/Piped"; static func pipedFileName(timestamp: String) -> String; static func resolve(_ path: String, relativeTo base: URL) -> URL }`
- `enum LineformPipedHousekeeping { static func stale(entries: [(url: URL, modified: Date)], now: Date, olderThan: TimeInterval, openDocumentURLs: Set<URL>) -> [URL] }`
- `enum LineformCLIMessages { static func noSuchFile(_ p: String) -> String; static func isDirectory(_ p: String) -> String; static let emptyInput: String; static let notText: String; static let tooLarge: String; static let usage: String }`

- [ ] **Step 1: Write the failing tests**

Create `LineformTests/CommandLineToolTests.swift`:

```swift
import XCTest
@testable import Lineform

final class CommandLineToolTests: XCTestCase {
    func testParseOpenSingleAndMultiple() {
        XCTAssertEqual(LineformCLICommand.parse(["a.md"]), .open(["a.md"]))
        XCTAssertEqual(LineformCLICommand.parse(["a.md", "b.md"]), .open(["a.md", "b.md"]))
    }
    func testParseStdinDash() {
        XCTAssertEqual(LineformCLICommand.parse(["-"]), .readStdin)
    }
    func testParseVersionAndHelp() {
        XCTAssertEqual(LineformCLICommand.parse(["--version"]), .version)
        XCTAssertEqual(LineformCLICommand.parse(["--help"]), .help)
        XCTAssertEqual(LineformCLICommand.parse([]), .help)
    }
    func testParseUnknownFlagIsInvalid() {
        XCTAssertEqual(LineformCLICommand.parse(["--nope"]), .invalid("--nope"))
    }
    func testValidateEmpty() {
        XCTAssertEqual(LineformPipeValidation.validate(Data()), .empty)
    }
    func testValidateNUL() {
        XCTAssertEqual(LineformPipeValidation.validate(Data([0x41, 0x00, 0x42])), .notText)
    }
    func testValidateTooLargeBoundary() {
        XCTAssertEqual(LineformPipeValidation.validate(Data(repeating: 0x41, count: 11), maxBytes: 10), .tooLarge)
        XCTAssertEqual(LineformPipeValidation.validate(Data(repeating: 0x41, count: 10), maxBytes: 10), .ok)
    }
    func testPipedFileName() {
        XCTAssertEqual(LineformCLIPaths.pipedFileName(timestamp: "20260701-101112"), "piped-20260701-101112.md")
    }
    func testResolveAbsoluteAndRelative() {
        let base = URL(fileURLWithPath: "/work", isDirectory: true)
        XCTAssertEqual(LineformCLIPaths.resolve("/abs/x.md", relativeTo: base).path, "/abs/x.md")
        XCTAssertEqual(LineformCLIPaths.resolve("sub/x.md", relativeTo: base).path, "/work/sub/x.md")
    }
    func testStaleReturnsOldUnopenedOnly() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-8 * 24 * 3600)
        let recent = now.addingTimeInterval(-1 * 24 * 3600)
        let a = URL(fileURLWithPath: "/p/a.md"), b = URL(fileURLWithPath: "/p/b.md"), c = URL(fileURLWithPath: "/p/c.md")
        let result = LineformPipedHousekeeping.stale(
            entries: [(a, old), (b, recent), (c, old)],
            now: now,
            olderThan: 7 * 24 * 3600,
            openDocumentURLs: [c]
        )
        XCTAssertEqual(result, [a])   // a: old & closed; b: recent; c: old but open
    }
    func testMessages() {
        XCTAssertEqual(LineformCLIMessages.noSuchFile("x"), "lineform: no such file: x")
        XCTAssertEqual(LineformCLIMessages.isDirectory("d"), "lineform: d is a directory (not supported yet)")
        XCTAssertEqual(LineformCLIMessages.emptyInput, "lineform: empty input")
        XCTAssertEqual(LineformCLIMessages.notText, "lineform: input is not text")
    }
}
```

- [ ] **Step 2: Add the test file to the test target in pbxproj; run to verify it fails**

Add `CommandLineToolTests.swift` (suffix 221) to the `LineformTests` target (PBXBuildFile, PBXFileReference, LineformTests group children, test Sources phase). Run:
`xcodebuild test -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:LineformTests/CommandLineToolTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'LineformCLICommand' in scope`.

- [ ] **Step 3: Implement the pure logic**

Create `Lineform/CommandLineTool/LineformCommandLine.swift`:

```swift
import Foundation

enum LineformCLICommand: Equatable {
    case open([String])
    case readStdin
    case version
    case help
    case invalid(String)

    static func parse(_ args: [String]) -> LineformCLICommand {
        guard let first = args.first else { return .help }
        switch first {
        case "--version": return .version
        case "--help", "-h": return .help
        case "-": return .readStdin
        default:
            if first.hasPrefix("--") { return .invalid(first) }
            return .open(args)
        }
    }
}

enum LineformPipeValidation: Equatable {
    case ok, empty, tooLarge, notText

    static func validate(_ data: Data, maxBytes: Int = 10_000_000) -> LineformPipeValidation {
        if data.isEmpty { return .empty }
        if data.count > maxBytes { return .tooLarge }
        if data.contains(0x00) { return .notText }
        return .ok
    }
}

enum LineformCLIPaths {
    static let pipedRelativePath = "Lineform/Piped"

    static func pipedFileName(timestamp: String) -> String { "piped-\(timestamp).md" }

    static func resolve(_ path: String, relativeTo base: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return base.appendingPathComponent(path)
    }
}

enum LineformPipedHousekeeping {
    static func stale(
        entries: [(url: URL, modified: Date)],
        now: Date,
        olderThan: TimeInterval,
        openDocumentURLs: Set<URL>
    ) -> [URL] {
        entries.compactMap { entry in
            guard now.timeIntervalSince(entry.modified) > olderThan else { return nil }
            guard !openDocumentURLs.contains(entry.url) else { return nil }
            return entry.url
        }
    }
}

enum LineformCLIMessages {
    static func noSuchFile(_ path: String) -> String { "lineform: no such file: \(path)" }
    static func isDirectory(_ path: String) -> String { "lineform: \(path) is a directory (not supported yet)" }
    static let emptyInput = "lineform: empty input"
    static let notText = "lineform: input is not text"
    static let tooLarge = "lineform: input too large (limit 10 MB)"
    static let usage = """
    lineform — open Markdown/text files in Lineform.

    Usage:
      lineform <file> [<file> …]   Open one or more files
      lineform -                   Open text piped on stdin
      lineform --version           Print the app version
      lineform --help              Show this help
    """
}
```

- [ ] **Step 4: Add the source file to the app target in pbxproj; run to verify pass**

Add `LineformCommandLine.swift` (suffix 220) to the `Lineform` app target. Create a `CommandLineTool` group under the `Lineform` group (mirror the `App`/`Documents` group entries). Run the Step 2 command. Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add Lineform/CommandLineTool/LineformCommandLine.swift LineformTests/CommandLineToolTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add pure CLI helper logic (parse/validate/paths/housekeeping)"
```

---

### Task 2: Helper entry point (`HelperTool/main.swift`)

**Files:** Create `HelperTool/main.swift` (NOT added to any Xcode target).

**Interfaces:** Consumes the Task 1 pure logic (compiled alongside by the packaging script).

- [ ] **Step 1: Write main.swift**

```swift
import Foundation

// Thin CLI wrapper. Pure decisions live in LineformCommandLine.swift (shared with the app
// module for testing); this file only does IO + process hand-off. Compiled together with
// that file by packaging/build-release.sh into Contents/Helpers/lineform.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// The .app that contains this helper (…/Contents/Helpers/lineform → …/X.app), following the
/// install symlink to the real executable first.
func enclosingAppURL() -> URL? {
    let real = (try? FileManager.default.destinationOfSymbolicLink(atPath: CommandLine.arguments[0]))
        .map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    // …/Contents/Helpers/lineform → drop lineform, Helpers, Contents
    let app = real.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return app.pathExtension == "app" ? app : nil
}

func appVersion(_ app: URL) -> String {
    let plist = app.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
          let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
          let version = info["CFBundleShortVersionString"] as? String else { return "unknown" }
    return version
}

func openInApp(_ urls: [URL]) -> Never {
    guard let app = enclosingAppURL() else {
        fail("lineform: could not locate Lineform.app — reinstall the command line tool from Lineform → Install Command Line Tool…")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", app.path] + urls.map(\.path)
    do { try process.run(); process.waitUntilExit() } catch { fail("lineform: failed to open Lineform") }
    exit(process.terminationStatus == 0 ? 0 : 1)
}

let args = Array(CommandLine.arguments.dropFirst())
switch LineformCLICommand.parse(args) {
case .help:
    print(LineformCLIMessages.usage); exit(0)
case .version:
    print(enclosingAppURL().map(appVersion) ?? "unknown"); exit(0)
case .invalid(let flag):
    fail("lineform: unknown option: \(flag)")
case .open(let paths):
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    var urls: [URL] = []
    for path in paths {
        let url = LineformCLIPaths.resolve(path, relativeTo: base)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { fail(LineformCLIMessages.noSuchFile(path)) }
        if isDir.boolValue { fail(LineformCLIMessages.isDirectory(path)) }
        urls.append(url)
    }
    openInApp(urls)
case .readStdin:
    let data = FileHandle.standardInput.readDataToEndOfFile()
    switch LineformPipeValidation.validate(data) {
    case .empty: fail(LineformCLIMessages.emptyInput)
    case .notText: fail(LineformCLIMessages.notText)
    case .tooLarge: fail(LineformCLIMessages.tooLarge)
    case .ok: break
    }
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    let pipedDir = support.appendingPathComponent(LineformCLIPaths.pipedRelativePath, isDirectory: true)
    try? FileManager.default.createDirectory(at: pipedDir, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    let fileURL = pipedDir.appendingPathComponent(LineformCLIPaths.pipedFileName(timestamp: formatter.string(from: Date())))
    do { try data.write(to: fileURL) } catch { fail("lineform: could not write piped input") }
    openInApp([fileURL])
}
```

- [ ] **Step 2: Verify it compiles standalone with the shared logic**

```bash
cd "/Users/carlostarrats/Documents/Projects/Lineform Bundle/Lineform"
mkdir -p /private/tmp/lineform-helper-smoke
swiftc -O -o /private/tmp/lineform-helper-smoke/lineform \
  Lineform/CommandLineTool/LineformCommandLine.swift HelperTool/main.swift 2>&1 | tail -20
echo "exit: $?"
/private/tmp/lineform-helper-smoke/lineform --help
printf '# hi\n' | HOME=/private/tmp/lineform-helper-smoke /private/tmp/lineform-helper-smoke/lineform - ; echo "(open will fail without an app — expected; check the Piped file was written)"
ls -la /private/tmp/lineform-helper-smoke/Library/Application\ Support/Lineform/Piped/ 2>/dev/null
/private/tmp/lineform-helper-smoke/lineform /nope.md ; echo "exit=$?"
```
Expected: compiles; `--help` prints usage; the piped run writes a `piped-*.md` file (the subsequent open may fail because there's no enclosing app in the smoke dir — that's fine, we only verify the write + guards here); missing file prints the error and exits 1.

- [ ] **Step 3: Commit**

```bash
git add HelperTool/main.swift
git commit -m "Add lineform helper entry point (open/stdin/version/help)"
```

---

### Task 3: Package the helper (build + sign)

**Files:** Modify `packaging/build-release.sh`; `docs/release/github-sparkle-release.md`.

- [ ] **Step 1: Read the packaging script** to find the `xcodebuild` step, the `sign_release_item()` helper, the inside-out re-sign list, and the universal-binary check (per the map: `build-release.sh` around lines 22-88).

- [ ] **Step 2: Add a helper build step** after the app is built and before the app is signed. Insert a block that compiles the universal helper into the app bundle:

```bash
# Build the bundled `lineform` command-line helper (universal), placed in Contents/Helpers.
HELPER_DIR="$APP_PATH/Contents/Helpers"
mkdir -p "$HELPER_DIR"
HELPER_SRC=(Lineform/CommandLineTool/LineformCommandLine.swift HelperTool/main.swift)
swiftc -O -target arm64-apple-macos14.0  -o "$HELPER_DIR/lineform-arm64"  "${HELPER_SRC[@]}"
swiftc -O -target x86_64-apple-macos14.0 -o "$HELPER_DIR/lineform-x86_64" "${HELPER_SRC[@]}"
lipo -create -output "$HELPER_DIR/lineform" "$HELPER_DIR/lineform-arm64" "$HELPER_DIR/lineform-x86_64"
rm -f "$HELPER_DIR/lineform-arm64" "$HELPER_DIR/lineform-x86_64"
lipo -info "$HELPER_DIR/lineform"
```

(Use the script's actual variable for the built `.app` path — adapt `$APP_PATH` to the real name.)

- [ ] **Step 3: Sign the helper in the inside-out list** (before the outer app), hardened runtime, no sandbox entitlement, using the existing signing identity variable:

```bash
sign_release_item "$APP_PATH/Contents/Helpers/lineform"
```
(If `sign_release_item` injects app entitlements, sign the helper explicitly instead:
`codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/Helpers/lineform"` — no `--entitlements`.)

- [ ] **Step 4: Document** the helper build/sign step in `docs/release/github-sparkle-release.md` (a short subsection under the build/sign flow).

- [ ] **Step 5: Commit**

```bash
git add packaging/build-release.sh docs/release/github-sparkle-release.md
git commit -m "Package + sign the bundled lineform helper in Contents/Helpers"
```

---

### Task 4: Install menu item + installer

**Files:** Create `Lineform/App/CommandLineToolInstaller.swift`; modify `AppCommands.swift`, `LineformTests/AppCommandNotificationTests.swift`, `Lineform.xcodeproj/project.pbxproj`.

- [ ] **Step 1: Read** `AppCommands.swift` (the `.appInfo`/Check-for-Updates group and `AppMenuConfiguration`) and `AppCommandNotificationTests.swift` to match patterns.

- [ ] **Step 2: Write the installer** `Lineform/App/CommandLineToolInstaller.swift`:

```swift
import AppKit

enum CommandLineToolInstaller {
    static let bundledHelperSubpath = "Contents/Helpers/lineform"
    static let defaultInstallPath = "/usr/local/bin/lineform"

    static var bundledHelperURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent(bundledHelperSubpath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func manualCommand(destination: String = defaultInstallPath) -> String {
        let helper = bundledHelperURL?.path ?? "/Applications/Lineform.app/\(bundledHelperSubpath)"
        return "ln -s \"\(helper)\" \(destination)"
    }

    @MainActor
    static func presentInstaller() {
        guard let helper = bundledHelperURL else {
            showManualFallback(reason: "The command line tool isn’t available in this build.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Install Command Line Tool"
        panel.message = "Choose where to install the lineform command (default: /usr/local/bin)."
        panel.nameFieldStringValue = "lineform"
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: helper)
        } catch {
            showManualFallback(reason: "Couldn’t create the link at \(destination.path).")
        }
    }

    @MainActor
    private static func showManualFallback(reason: String) {
        let alert = NSAlert()
        alert.messageText = "Install manually"
        alert.informativeText = "\(reason)\n\nRun this in Terminal:\n\n\(manualCommand())"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
```

- [ ] **Step 3: Add the menu item** in `AppCommands.swift` (in the `.appInfo` group next to Check for Updates), and a title constant in `AppMenuConfiguration`:

```swift
static let installCommandLineToolCommandTitle = "Install Command Line Tool…"
```
```swift
Button(AppMenuConfiguration.installCommandLineToolCommandTitle) {
    CommandLineToolInstaller.presentInstaller()
}
```

- [ ] **Step 4: Add a constant assertion** in `AppCommandNotificationTests.swift`:

```swift
func testInstallCommandLineToolTitle() {
    XCTAssertEqual(AppMenuConfiguration.installCommandLineToolCommandTitle, "Install Command Line Tool…")
}
```

- [ ] **Step 5: Add the installer file to the app target in pbxproj (suffix 222); build + run the assertion**

`xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -5` → BUILD SUCCEEDED.
`xcodebuild test ... -only-testing:LineformTests/AppCommandNotificationTests 2>&1 | tail -8` → PASS.

- [ ] **Step 6: Commit**

```bash
git add Lineform/App/CommandLineToolInstaller.swift Lineform/App/AppCommands.swift LineformTests/AppCommandNotificationTests.swift Lineform.xcodeproj/project.pbxproj
git commit -m "Add Install Command Line Tool… menu item and installer"
```

---

### Task 5: Piped-folder housekeeping on launch

**Files:** Modify `Lineform/App/FirstLaunchIntroOverlay.swift` (`LineformAppDelegate`).

- [ ] **Step 1: Read** `LineformAppDelegate.applicationDidFinishLaunching` (`:79`).

- [ ] **Step 2: Add housekeeping** invoked from `applicationDidFinishLaunching` (after the existing body):

```swift
private func cleanUpStalePipedFiles() {
    let fm = FileManager.default
    let pipedDir = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
        .appendingPathComponent(LineformCLIPaths.pipedRelativePath, isDirectory: true)
    guard let contents = try? fm.contentsOfDirectory(
        at: pipedDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
    ) else { return }
    let entries: [(url: URL, modified: Date)] = contents.compactMap { url in
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        return (url, date)
    }
    let open = Set(NSDocumentController.shared.documents.compactMap { $0.fileURL?.standardizedFileURL })
    let stale = LineformPipedHousekeeping.stale(
        entries: entries.map { ($0.url.standardizedFileURL, $0.modified) },
        now: Date(),
        olderThan: 7 * 24 * 60 * 60,
        openDocumentURLs: open
    )
    for url in stale { try? fm.removeItem(at: url) }
}
```

Call `cleanUpStalePipedFiles()` at the end of `applicationDidFinishLaunching`.

- [ ] **Step 3: Build**

`xcodebuild build -project Lineform.xcodeproj -scheme Lineform -destination 'platform=macOS' 2>&1 | tail -5` → BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Lineform/App/FirstLaunchIntroOverlay.swift
git commit -m "Housekeep stale Piped files on launch"
```

---

### Task 6: Verify, docs, index

- [ ] **Step 1: Full serial suite** (machine quiet). Report exact counts. Expected: all pass (prior 252 + new CommandLineToolTests + the new AppCommand assertion).

- [ ] **Step 2: Helper smoke** (scratchpad, not ~/Documents) — re-run the Task 2 Step 2 smoke to confirm the shipped compile path still works end to end (help/version/stdin/missing-file/dir). Report which were exercised.

- [ ] **Step 3: Privacy docs** — add a line to `Lineform/Resources/Privacy.md` (and mirror in the website privacy copy later, unit 6) noting piped input is stored locally in `~/Library/Application Support/Lineform/Piped/` and auto-deleted after 7 days. Add a "Command line tool" line to `CLAUDE.md` Main Features and `README.md`.

- [ ] **Step 4: Index** — check off `- [x] 3 — CLI + stdin` in the decomposition index.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Docs: CLI helper (privacy/readme/claude); mark unit 3 complete"
```

---

## Notes for the implementer

- **No new Xcode target** — the helper is built by the packaging script; only 3 files join existing targets via safe additive pbxproj entries. Highest existing suffix ~214; use 220+.
- **`HelperTool/main.swift` must NOT be added to any Xcode target** (it has a top-level entry point that would collide with the app's `@main`). It is only compiled by `swiftc` in the packaging script + the smoke test.
- **Pure logic is Foundation-only** — no AppKit — so `swiftc` compiles it for the helper without the app.
- **Housekeeping must never crash launch** — every filesystem call is `try?`.
- **The helper is absent from plain Debug builds** — the installer menu item shows the manual `ln -s` fallback there; that's expected.
