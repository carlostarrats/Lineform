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
- Run Instruments smoke profiling for launch or time profiling when available.
