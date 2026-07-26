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
- Run product-rule scans.
- Confirm the About panel displays the intended release version. `AppMenuConfiguration.aboutVersionDisplay` is a hand-maintained literal that does NOT track `MARKETING_VERSION` — bump it and its assertion in `AppCommandNotificationTests` in the same change as the version bump. It shipped wrong once (`V1.2.0` on a 1.3.0 build).
- Confirm the Dock, Cmd-Tab, Finder, and About panel use the bundled app icon at normal macOS visual size.
- Confirm the app does not override `NSApplication.shared.applicationIconImage` at runtime; the asset catalog and bundle metadata should be the single icon source.
- Confirm `README.md`, `CLAUDE.md`, app metadata, help, and font credits match the shipped version.
- Confirm the website and README download links point at the current GitHub release DMG.
- Confirm Sparkle update checks are either fully configured with a real EdDSA key/appcast or intentionally documented as unavailable for the build.
- Confirm bundled font license files are present in `Resources/Fonts`.
- Run Instruments smoke profiling for launch or time profiling when available.
