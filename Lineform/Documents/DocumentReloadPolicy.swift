import CoreGraphics
import Foundation

/// The result of deciding whether an externally-changed file should reload the open document.
enum ReloadOutcome: Equatable {
    case reload
    case ignoreDirty
    case ignoreUnchanged
}

/// Pure decision logic for live reload. Gated so a dirty document is never clobbered and the
/// app's own saves (disk == memory) never trigger a pointless reload.
enum DocumentReloadPolicy {
    /// Trailing debounce interval that coalesces burst writes into a single reload.
    static let debounceInterval: TimeInterval = 0.3

    static func decide(isDocumentEdited: Bool, diskText: String, currentText: String) -> ReloadOutcome {
        if isDocumentEdited { return .ignoreDirty }
        if diskText == currentText { return .ignoreUnchanged }
        return .reload
    }
}

/// Proportional (ratio-based) scroll preservation for wholesale text replacement, where
/// character-range anchors are invalid because ranges shift.
enum ProportionalScrollMath {
    /// Fraction (0...1) of the scrollable range currently scrolled.
    static func ratio(originY: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let scrollable = documentHeight - viewportHeight
        guard scrollable > 0 else { return 0 }
        return min(max(originY / scrollable, 0), 1)
    }

    /// The origin Y that restores `ratio` against (possibly new) content metrics.
    static func originY(ratio: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let scrollable = documentHeight - viewportHeight
        guard scrollable > 0 else { return 0 }
        return min(max(ratio, 0), 1) * scrollable
    }
}
