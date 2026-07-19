# Hosted test plan: why it exists and how to run it

Moved out of `CLAUDE.md` (which keeps the two commands and the hard rules). This is the reasoning,
the failure modes, and the machine-state debugging recipe.

The split exists because a handful of tests host a real `NSWindow` + `NSHostingView` editor inside the unit-test process — powerful but outside what XCTest supports well: load-sensitive assertions and intermittent test-host crashes (over-releases during autorelease-pool drains; the app itself is never affected). Everything else is pure and deterministic.

**Default gate (the everyday command — pure suite, ~370 tests in seconds, crash-free):**

```sh
xcodebuild test \
  -project Lineform.xcodeproj \
  -scheme Lineform \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO
```

This runs the default plan (`Lineform.xctestplan`), which skips the two hosted-window classes. Xcode ⌘U uses the same plan. CI (`.github/workflows/ci.yml`) runs this full default plan on every push/PR (with a 30-minute job timeout). Keep `-parallel-testing-enabled NO`: some AppKit-hosted state can contaminate across parallel runners. No signing/team flags are needed: Debug ships no iCloud entitlement, so the test host signs ad-hoc ("Sign to Run Locally") and launches on unprovisioned machines and CI. Do not add an iCloud entitlement to Debug — it cannot be satisfied under ad-hoc signing and the test host will fail to launch (CI red).

TCC caveat (applies to ANY CLI test run on the user's machine, default plan included): the ad-hoc-re-signed test host can look like a new app to TCC and prompt "'Lineform' would like to access files in your Documents folder." Expected, dev-only, harmless — but it blocks the run until answered, so warn the user beforehand, have them click Allow, and never run the suite unattended and assume it finished.

**Hosted plan (opt-in — the quarantined window-motion tests):**

```sh
xcodebuild test \
  -project Lineform.xcodeproj \
  -scheme Lineform \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -testPlan LineformHosted
```

This runs `EditorDrawerMotionHostedTests` (drawer/inspector motion sampling), `LiveReloadScrollTests` (scroll preservation across external reload — quarantined because it is the other builder of ordered-front hosted `NSWindow`s implicated in the process-exit teardown crash, and its run-loop-pumped scroll assertions are timing-sensitive), and `DocumentExportPDFHostedTests` (PDF-byte generation via `NSPrintOperation` — quarantined not for crashiness but because the OS print subsystem's cold start is nondeterministic: the `kCPLCopyDefaultPrinter` lookup can hang for minutes the first time it is contacted in a fresh sandboxed process, which would occasionally turn the "runs in seconds" default suite into a multi-minute run). Run this plan deliberately — on a quiet machine, Xcode quit — before releases that touch editor motion, drawer/inspector presentation, reload scroll behavior, or PDF export/print. Expectations when running it:

- QUIT XCODE FIRST. These tests measure sub-second animations and are load-sensitive: under contention they fail with spurious deltas (e.g. "13.0 > 1.0" or a flaky `testEditorVisibleTextDoesNotJumpVerticallyWhenReadingInspectorOpens`). "Quiet machine" means more than no concurrent processes: after hours of build churn / multi-day uptime the 13.0 failure reproduces even in single-test isolation at ANY commit (verified 2026-07-04 — it failed identically at a commit that had passed the same run earlier that day). Before treating a hosted failure as a motion regression, re-run the same test at a known-good commit on the same machine; if that fails too, it's machine state — reboot and re-verify. Harness fragility, not a product regression — do not weaken the tests to "fix" it.
- The test host may occasionally crash (per-test via `XCTMemoryChecker`, or at process exit in `_NSWindowTransformAnimation dealloc`) and leave a Lineform `.ips` crash report. This is the known SwiftUI-window-in-XCTest over-release; it never affects the shipped app. Two targeted fixes were tried on 2026-07-03 (`window.close()` in teardown → crash-looped the host; `animationBehavior = .none` → moved the crash to `XCTMemoryChecker`), which is why the durable fix is this quarantine, not more patching.
- `EditorDrawerMotionHostedTests/testZEditorVisibleTextDoesNotJumpVerticallyWhenOutlineDrawerOpens` may log `[WarnOnce] It's not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out` (investigated 2026-05-28; harness-construction artifact, not product code).

Do not weaken, delete, or fold the hosted tests back into the default plan. They protect real UI motion regressions; their placement — not their existence — was the problem. The quarantine lists are class-name strings in the two `.xctestplan` files; `TestPlanGuardTests` (in the default plan) fails loudly if the lists drift apart or reference a renamed class — update both plans in lockstep.
