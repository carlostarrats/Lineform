import Foundation

/// The result of deciding whether an externally-changed file should reload the open document.
enum ReloadOutcome: Equatable {
    case reload
    case ignoreDirty
    case ignoreUnchanged
}

/// Pure decision logic for live reload.
///
/// The gate is a *baseline snapshot* comparison, not the framework's
/// `NSDocument.isDocumentEdited` flag — that flag is set asynchronously by SwiftUI's
/// `DocumentGroup` after a keystroke, so relying on it opens a window where a freshly-typed
/// (but not-yet-flagged-dirty) document could be clobbered by an external write. Comparing
/// against `lastSyncedText` (the in-memory text as of the last moment memory equalled disk —
/// open, our own save, or a prior reload) closes that window deterministically.
enum DocumentReloadPolicy {
    /// Trailing debounce interval that coalesces burst writes into a single reload.
    static let debounceInterval: TimeInterval = 0.3

    static func decide(diskText: String, currentText: String, lastSyncedText: String) -> ReloadOutcome {
        // Disk already matches memory: nothing to do (covers the app's own save write-back).
        if diskText == currentText { return .ignoreUnchanged }
        // Memory diverged from the last synced baseline: the user has unsaved in-memory edits.
        // Never clobber them — defer to standard document conflict behavior.
        if currentText != lastSyncedText { return .ignoreDirty }
        // Memory still matches the baseline but disk changed: a clean external edit. Reload.
        return .reload
    }
}
