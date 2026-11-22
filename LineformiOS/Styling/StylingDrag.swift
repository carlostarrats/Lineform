import Foundation
import LineformCore

/// A Styling sheet slider drag, measured on a 1 MB document (`StylingPerformanceTests`):
///
/// - Write: re-applying the base attributes costs about 4 ms and the token pass under 1 ms, but the
///   reading assists then lay out the whole prefix up to the caret (TextKit 1's non-contiguous
///   layout was invalidated by the restyle): about 640 ms with the caret near the end.
/// - Read: each profile change re-renders the whole document (about 450 ms), re-places the pills
///   (about 390 ms) and lays it out again (about 430 ms).
///
/// So while a slider is held, the editor restyles live but leaves the Reading Ruler hidden and the
/// caret where it is, and the Read view keeps the newest profile without rendering it. When the
/// drag ends, `didEndNotification` runs the assists and the render once, on the final value.
@MainActor
enum StylingDrag {
    /// True while a Styling sheet slider is held.
    private(set) static var isActive = false

    /// Posted when a drag ends, after the final value is in the store.
    static let didEndNotification = Notification.Name("LineformStylingDragDidEnd")

    static func begin() {
        isActive = true
    }

    static func end() {
        guard isActive else { return }
        isActive = false
        NotificationCenter.default.post(name: didEndNotification, object: nil)
    }
}

/// Writes slider values to the store at most once per run-loop turn while a drag is active,
/// always the newest value, and applies at once otherwise (a VoiceOver adjustment, a test).
@MainActor
final class ProfileUpdateCoalescer {
    private var pending: [(inout ReadingProfile) -> Void] = []
    private weak var store: ReadingProfileStore?
    private var isScheduled = false
    /// How many times the coalescer wrote the store (tests).
    private(set) var appliedCount = 0

    func submit(to store: ReadingProfileStore, _ mutate: @escaping (inout ReadingProfile) -> Void) {
        guard StylingDrag.isActive else {
            store.update(mutate)
            appliedCount += 1
            return
        }
        self.store = store
        pending.append(mutate)
        guard !isScheduled else { return }
        isScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Applies what is pending now, in one store update.
    func flush() {
        isScheduled = false
        guard let store, !pending.isEmpty else { return }
        let mutations = pending
        pending.removeAll()
        store.update { profile in
            for mutate in mutations { mutate(&profile) }
        }
        appliedCount += 1
    }

    func beginDrag() {
        StylingDrag.begin()
    }

    /// Lands the final value, then lets the editor and the Read view catch up once.
    func endDrag() {
        flush()
        StylingDrag.end()
    }
}
