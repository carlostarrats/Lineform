import Foundation
import Observation

/// First run's state: the stage on screen, when it began, when the line page painted, and the
/// one-time finish. The overlay only draws it and feeds it timer fires and the writer's taps.
///
/// Finishing happens once: the first advance past `.points` writes the completed flag and calls
/// `onFinish`; every later advance does nothing. A tap that lands just after the timer moved
/// the stage on (`tapGrace`) is ignored, so one tap at the boundary cannot skip a whole stage.
@MainActor
@Observable
final class FirstRunFlow {
    /// How long after an automatic advance the writer's taps are ignored.
    static let tapGrace: Duration = .milliseconds(150)

    private(set) var stage: FirstRunStage = .line
    private(set) var stageStartedAt: ContinuousClock.Instant
    /// The line page's first painted frame, if it has signalled one.
    private(set) var lineReadyAt: ContinuousClock.Instant?
    private(set) var hasFinished = false

    @ObservationIgnored private var autoAdvancedAt: ContinuousClock.Instant?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let onFinish: () -> Void

    init(defaults: UserDefaults = .standard, now: ContinuousClock.Instant = .now, onFinish: @escaping () -> Void) {
        self.defaults = defaults
        self.onFinish = onFinish
        stageStartedAt = now
    }

    /// When the current stage advances by itself, or nil when it waits for the writer.
    func autoAdvanceDeadline(reduceMotion: Bool, voiceOverRunning: Bool = false) -> ContinuousClock.Instant? {
        FirstRunTiming.deadline(
            for: stage,
            stageStart: stageStartedAt,
            lineReadyAt: lineReadyAt,
            reduceMotion: reduceMotion,
            voiceOverRunning: voiceOverRunning
        )
    }

    /// The line page painted its first frame. Only the first signal, on the line stage, counts.
    func lineDidBecomeReady(at now: ContinuousClock.Instant = .now) {
        guard stage == .line, lineReadyAt == nil else { return }
        lineReadyAt = now
    }

    /// The stage's timer fired. It advances only from the stage it was set for.
    @discardableResult
    func autoAdvance(from expected: FirstRunStage, at now: ContinuousClock.Instant = .now) -> Bool {
        guard stage == expected else { return false }
        guard step(at: now) else { return false }
        autoAdvancedAt = now
        return true
    }

    /// A tap, swipe, Return or the VoiceOver action.
    @discardableResult
    func userAdvance(at now: ContinuousClock.Instant = .now) -> Bool {
        if let autoAdvancedAt, now < autoAdvancedAt + Self.tapGrace { return false }
        return step(at: now)
    }

    private func step(at now: ContinuousClock.Instant) -> Bool {
        guard !hasFinished else { return false }
        let next = stage.next
        guard next != stage else { return false }
        stage = next
        stageStartedAt = now
        if next == .done {
            hasFinished = true
            FirstRunGate.markCompleted(defaults: defaults)
            onFinish()
        }
        return true
    }
}
