import Foundation
import Observation

/// First run's state: the stage on screen, whether the wordmark has finished writing (so Get
/// Started can show), and the one-time finish. The overlay only draws it and feeds it the page's
/// signal and the writer's taps.
///
/// Nothing advances by itself. Each button advances only from its own stage (`advance(from:)`),
/// so a second tap on Get Started, or a tap that lands as the points arrive, never skips them.
/// Finishing happens once: the advance past `.points` writes the completed flag and calls
/// `onFinish`; every later advance does nothing.
@MainActor
@Observable
final class FirstRunFlow {
    private(set) var stage: FirstRunStage = .welcome
    /// The wordmark has written itself (or the page never said so in time): Get Started shows.
    private(set) var isWordmarkWritten = false
    private(set) var hasFinished = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let onFinish: () -> Void

    init(defaults: UserDefaults = .standard, onFinish: @escaping () -> Void) {
        self.defaults = defaults
        self.onFinish = onFinish
    }

    /// The page finished writing the wordmark, or the cap ran out. Only counts on the welcome.
    func wordmarkDidFinishWriting() {
        guard stage == .welcome else { return }
        isWordmarkWritten = true
    }

    /// The writer tapped the button of `expected` (Get Started on `.welcome`, Start Writing on
    /// `.points`). Does nothing from any other stage.
    @discardableResult
    func advance(from expected: FirstRunStage) -> Bool {
        guard !hasFinished, stage == expected, expected != .done else { return false }
        stage = expected.next
        if stage == .done {
            hasFinished = true
            FirstRunGate.markCompleted(defaults: defaults)
            onFinish()
        }
        return true
    }
}
