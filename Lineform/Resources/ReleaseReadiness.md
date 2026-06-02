# Release Readiness

## Performance

- Keep intelligence lazy-loaded until an action is invoked.
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
- Confirm the About panel displays the intended release version.
- Confirm `README.md`, `AGENTS.md`, app metadata, help, and font credits match the shipped version.
- Confirm the website and README download links point at the current GitHub release DMG.
- Confirm Sparkle update checks are either fully configured with a real EdDSA key/appcast or intentionally documented as unavailable for the build.
- Confirm bundled font license files are present in `Resources/Fonts`.
- Run Instruments smoke profiling for launch or time profiling when available.
