# Release Readiness

## Performance

- Keep documents local and avoid startup network work.
- Debounce expensive editor refresh paths where they can affect typing.
- Verify large Markdown files before release builds.
- Run `LineformTests/LargeDocumentPerformanceTests` to record clock metrics for large-document statistics, outline parsing, preview rendering, syntax highlighting, and repeated read-view updates.

## Memory

- Avoid document indexing services.
- Avoid bundled models and heavyweight dependencies.
- Prefer native AppKit and SwiftUI controls.

## Release Checks

- Run unit tests.
- Run a standalone build.
- Launch the built app.
- With no restored document, confirm the first visible launch window is a normal untitled editor: the generic Open browser must not flash first. Close the last window and click the Dock icon repeatedly; each reopen must produce one untitled editor without an edge, shadow, background-color, or toolbar pulse.
- Confirm File ▸ Open replaces a pristine untitled tab without a transient window, adds a tab beside edited or file-backed work, and that closing an unsaved final tab completes on the first Save, Cancel, or Don't Save choice.
- After a real Markdown open or save, relaunch and confirm the default-app invitation appears once; verify Not Now persists and Settings retains the Make Default action.
- Do not expect the App Store rating sheet in TestFlight; StoreKit suppresses review prompts there. In a local Debug build, use `LINEFORM_FORCE_REVIEW_PROMPT=1` to verify that an unobstructed editor reaches the StoreKit request after its four-second quiet period. Confirm the same app version is claimed only once, and confirm the forcing variable and QA trace strings are absent from the Release binary. Never substitute a custom pre-prompt.
- Run product-rule scans.
- Confirm the About panel displays the intended release version. `AppMenuConfiguration.aboutVersionDisplay` is a hand-maintained literal that does NOT track `MARKETING_VERSION` — bump it and its assertion in `AppCommandNotificationTests` in the same change as the version bump. It shipped wrong once (`V1.2.0` on a 1.3.0 build).
- Confirm the Dock, Cmd-Tab, Finder, and About panel use the bundled app icon at normal macOS visual size.
- Confirm the app does not override `NSApplication.shared.applicationIconImage` at runtime; the asset catalog and bundle metadata should be the single icon source.
- Confirm `README.md`, `AGENTS.md`, `Claude.md`, app metadata, help, and font credits match the
  shipped version.
- Confirm the website points at the App Store listing. (The README carries no download links by design — see `Claude.md` ▸ Documentation Expectations.)
- Confirm the build ships no updater and no unsandboxed nested binary. `ReleaseResourceTests`
  guards updater metadata; Organizer's Validate App is what catches a nested binary before upload.
- Submission steps, signing, and TestFlight: `docs/release/app-store-release.md`.
- Confirm bundled font license files are present in `Resources/Fonts`.
- Run Instruments smoke profiling for launch or time profiling when available.
