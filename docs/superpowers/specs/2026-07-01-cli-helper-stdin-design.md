# Spec 3 — CLI Helper (`lineform`) + stdin Piping

Date: 2026-07-01
Part of: [Agent-Reader decomposition](./2026-07-01-agent-reader-decomposition.md) (unit 3)
Source features: F1 (CLI tool) + F2 (stdin), paired.

## Goal

A small `lineform` command-line helper bundled inside `Lineform.app`, so an agent (or the
user) can open agent-written Markdown straight from the terminal — `lineform report.md`,
or `some-agent | lineform -`. This is the terminal on-ramp for the Agent-Reader release.

## Behavior (from F1 + F2)

- `lineform file.md [more.md …]` — opens each file in Lineform (activates the app). Relative
  paths resolve against the caller's CWD before hand-off.
- `lineform -` — reads stdin to EOF, writes it to
  `~/Library/Application Support/Lineform/Piped/piped-<timestamp>.md`, then opens that file
  exactly like a normal file. It opens as a real saved document (the temp file *is* the
  model); the user can Save As to keep it. No special buffer mode.
- `lineform --version` prints the app version; `lineform --help` prints usage.
- Errors (all to stderr, exit 1, app not launched):
  - missing path → `lineform: no such file: <path>`
  - directory → `lineform: <path> is a directory (not supported yet)`
  - empty stdin → `lineform: empty input`
  - stdin > 10 MB → a clear too-large message
  - stdin containing NUL bytes → `lineform: input is not text`
- Hand-off uses `open` against the **containing app bundle**, so the sandboxed app receives
  the file through the standard user-intent path (LaunchServices) and gains access without
  extra entitlements. The helper resolves its own real path (following the install symlink) up
  to the enclosing `.app`; if it cannot locate a valid enclosing app, it prints a reinstall
  hint.
- Installation: app menu **Lineform → Install Command Line Tool…** presents an `NSSavePanel`
  defaulting to `/usr/local/bin/lineform` and writes a **symlink** to the bundled helper at the
  chosen location (the save panel grants the sandbox write access to that one path). On
  failure, show the manual one-liner in a copyable field:
  `ln -s "/Applications/Lineform.app/Contents/Helpers/lineform" /usr/local/bin/lineform`.
- Housekeeping: after launch/state restoration, delete files in `Piped/` older than 7 days
  that have no open document. Disclosed in privacy docs (local-only piped content).

## Architecture decision (important — build integration)

The map shows the Xcode project uses a **classic, hand-authored `project.pbxproj`** (no
synchronized groups; every entry has a manually-assigned `1F00000…` UUID). Adding a full new
`product-type.tool` target means hand-authoring a new native target, its own
`XCConfigurationList` (Debug+Release), a product file ref, a Sources phase, a Copy Files
phase, and a target dependency — a large, error-prone edit. Corrupting `project.pbxproj`
during an unattended run would block every remaining unit.

**Decision:** do **not** add a new Xcode target. Instead:

1. Put the helper's **pure logic in the app module** (`Lineform/CommandLineTool/…`), so the
   deterministic tests reach it via `@testable import Lineform` (a tool target's sources are
   not testable from the app-hosted test bundle). These are Foundation-only, side-effect-free
   types.
2. Put the helper's **entry point** in a standalone `HelperTool/main.swift` that is **not a
   member of any Xcode target** — a thin wrapper that calls the pure logic and performs IO.
3. **Build + sign the helper in the release packaging script** (`packaging/build-release.sh`):
   after `xcodebuild` produces `Lineform.app`, compile `Lineform/CommandLineTool/*.swift` +
   `HelperTool/main.swift` with `swiftc` for both arches, `lipo` into a universal binary at
   `Lineform.app/Contents/Helpers/lineform`, then sign it (hardened runtime, **no** sandbox
   entitlement) as part of the existing inside-out re-sign list, so notarization covers it.

This yields a real bundled, signed, notarized helper and fully testable logic with **zero new
Xcode target** and only safe, additive `project.pbxproj` file entries (the pure-logic files +
the installer file joining the existing app target — the same kind of edit units 1–2 made).

Consequence: the helper is present only in **packaged release builds**, not plain Debug
`xcodebuild` builds. The "Install Command Line Tool…" menu item handles a missing bundled
helper gracefully (shows the manual instructions). This is acceptable — the CLI is a
release-distributed feature, and its logic is unit-tested independently of the packaged binary.

## Design

### Pure logic (app module, `Lineform/CommandLineTool/`) — tested

- `LineformCLICommand` — `enum Command { case open([String]); case readStdin; case version; case help; case invalid(String) }` and `static func parse(_ args: [String]) -> Command` (args excluding argv[0]). Empty args → `.help` (or a usage error — choose `.help`).
- `LineformPipedInput` — `enum PipeValidation { case ok; case empty; case tooLarge; case notText }` and `static func validate(_ data: Data, maxBytes: Int = 10_000_000) -> PipeValidation` (empty → `.empty`; contains `0x00` → `.notText`; `> maxBytes` → `.tooLarge`; else `.ok`). Also `static func pipedFileName(timestamp: String) -> String` = `"piped-\(timestamp).md"`.
- `PipedFileHousekeeping` — pure `static func stale(entries: [(url: URL, modified: Date)], now: Date, olderThan: TimeInterval = 7 * 24 * 60 * 60, openDocumentURLs: Set<URL>) -> [URL]` returning the URLs to delete (older than cutoff AND not currently open).
- `CLIPathResolver` — pure `static func resolve(_ path: String, relativeTo base: URL) -> URL` (absolute passes through; relative resolves against `base`).
- Shared constants: the Application Support subpath (`"Lineform/Piped"`), error message strings (so tests can assert exact wording), and exit codes.

### Helper entry (`HelperTool/main.swift`, not in any target)

Thin: read `CommandLine.arguments`, `Command.parse`, then:
- `.version` → print the enclosing app's `CFBundleShortVersionString`; `.help` → usage text.
- `.open(paths)` → for each: resolve vs CWD (`FileManager.default.currentDirectoryPath`);
  if missing → error+exit1; if directory → error+exit1; collect valid URLs; hand off via
  `open` to the enclosing app.
- `.readStdin` → read `FileHandle.standardInput.readDataToEndOfFile()`; `validate`; on failure
  print the mapped message + exit1; else write to
  `~/Library/Application Support/Lineform/Piped/piped-<timestamp>.md` (create dir), then hand
  off that file.
- **Hand-off:** resolve the helper's own real path (`realpath` of argv[0]) → walk up to the
  `.app` → run `/usr/bin/open -a <appPath> <files…>` via `Process`. If the enclosing app can't
  be resolved, print the reinstall hint + exit1.
- Foundation-only (no AppKit) so `swiftc` compilation in the packaging script stays simple.

### App-side (app module, `Lineform/App/`)

- `CommandLineToolInstaller` — presents the `NSSavePanel` (default `/usr/local/bin/lineform`),
  resolves the bundled helper at `Bundle.main.bundleURL/Contents/Helpers/lineform`, and creates
  a symlink at the chosen URL (removing an existing one). On any failure (missing bundled
  helper in Debug, or write denied), show an alert with the copyable manual `ln -s` command.
- Menu item: add **Install Command Line Tool…** to `AppCommands` following the Check-for-Updates
  pattern (`AppCommands.swift:124-134`); add its title to `AppMenuConfiguration` with a matching
  assertion in `AppCommandNotificationTests`.
- Housekeeping: in `LineformAppDelegate.applicationDidFinishLaunching`
  (`FirstLaunchIntroOverlay.swift:79`), after restoration, enumerate `Piped/`, build entries,
  gather open-document URLs from `NSDocumentController.shared.documents`, call
  `PipedFileHousekeeping.stale(...)`, and delete the returned URLs. Wrap IO so failures are
  swallowed (housekeeping must never crash launch).

### Packaging (`packaging/build-release.sh`, `docs/release/github-sparkle-release.md`)

- After the app builds, compile the universal helper and place it at
  `…/Lineform.app/Contents/Helpers/lineform`.
- Add the helper to the inside-out re-sign list (signed before the outer app; hardened runtime;
  no sandbox entitlement).
- Add a `lipo -info` universal check for the helper alongside the existing app check.
- Document the helper build/sign step in the release doc.

## Non-goals

- No new Xcode target (see decision above).
- No opening directories from the CLI; no folder watching; no MCP.
- No special document "buffer mode" — the piped temp file is a real file.
- The helper does not render anything or embed the editor.
- No change to the app's sandbox entitlements; the helper is unsandboxed (separate binary).

## Verification

1. **Deterministic tests** (serial, per CLAUDE.md): a new `LineformTests/CommandLineToolTests.swift`
   covering: argument parsing (open/stdin/version/help/invalid, multi-file, empty); stdin
   validation (empty, NUL, >10MB boundary, ok); `pipedFileName`; `PipedFileHousekeeping.stale`
   (older-than cutoff, open-doc exclusion, injected `now`); `CLIPathResolver` (absolute vs
   relative). All pure, no filesystem, no real stdin, no app launch → hermetic (no Documents
   prompt).
2. **Build** stays green (Debug + the packaging build). `xcodebuild build` compiles the app with
   the new pure-logic + installer files.
3. **Helper build smoke** (local, in the scratchpad — NOT `~/Documents`): run the `swiftc`
   compile step from the packaging script to confirm `HelperTool/main.swift` +
   `CommandLineTool/*.swift` compile to a working binary; exercise `lineform --version`,
   `lineform --help`, `echo "# hi" | lineform -` (writes to a redirected Application Support
   path), a missing-file error, and a directory error. Report which were exercised.
4. **Manual (release only, deferred):** installing via the menu item and opening a real file /
   piping into the running app requires a packaged release build; note it as deferred if not
   exercised.

## Risk / notes

- **pbxproj safety:** only additive file-reference entries for the app target (pure-logic +
  installer files) — no new target, no config list. This is the same low-risk edit units 1–2
  used.
- **Helper reuse of pure logic:** the packaging `swiftc` step compiles the same
  `Lineform/CommandLineTool/*.swift` sources that the app target compiles for tests — one
  source of truth, compiled into two places (app for tests, standalone for the binary).
- **Application Support is greenfield** — the app uses none today; the `Piped/` folder and its
  housekeeping are entirely new. Keep all IO failure-tolerant.
- **Hand-off path resolution** must follow the install symlink (`realpath`) to find the
  enclosing `.app`; guard the "app moved / not found" case with the reinstall hint.
