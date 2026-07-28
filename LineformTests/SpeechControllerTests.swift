import XCTest
@testable import Lineform

@MainActor
final class SpeechControllerTests: XCTestCase {
    /// Models the SHIPPING `AVSpeechSynthesizer`, not the convenient version. Two behaviours here
    /// were previously inverted, and both inversions hid a real bug:
    ///
    /// - `stop()` did not invoke `onFinish`. The real synthesizer delivers `didFinish` for a
    ///   stopped utterance, so `testStartingWhileSpeakingStopsThePrevious` passed over a defect
    ///   that greyed out Pause and Stop while audio was playing.
    /// - `pause()` was instantaneous. The real one defers to a word boundary, which is what let a
    ///   Pause land after a Resume and silence playback permanently.
    ///
    /// `SystemSpeechSynthesizer` filters a stopped utterance's finish by identity, so a controller
    /// driven by this fake behaves the same as one driven by the real thing.
    final class FakeSynthesizer: SpeechSynthesizing {
        var onFinish: (() -> Void)?
        var onPause: (() -> Void)?
        var onContinue: (() -> Void)?
        private(set) var isSpeaking = false
        private(set) var isPaused = false
        private(set) var spokenTexts: [String] = []
        private(set) var stopCount = 0
        /// Set while a `pause()` has been requested but has not yet reached a word boundary.
        private(set) var hasPendingPause = false
        /// Mirrors `SystemSpeechSynthesizer.currentUtterance`: a stopped utterance's finish is
        /// not forwarded.
        private var utteranceIsCurrent = false

        func speak(_ text: String) {
            spokenTexts.append(text)
            isSpeaking = true
            isPaused = false
            utteranceIsCurrent = true
        }

        func pause() { hasPendingPause = true }
        func continueSpeaking() { hasPendingPause = false; isPaused = false; onContinue?() }

        func stop() {
            stopCount += 1
            isSpeaking = false
            isPaused = false
            hasPendingPause = false
            // The real synthesizer reports the stopped utterance as didFinish. The adapter drops
            // it because it is no longer current; the fake mirrors that filter.
            let wasCurrent = utteranceIsCurrent
            utteranceIsCurrent = false
            if wasCurrent { deliverFinishIfCurrent() }
        }

        /// Deliver a pending pause at the next word boundary.
        func deliverPendingPause() {
            guard hasPendingPause else { return }
            hasPendingPause = false
            isPaused = true
            onPause?()
        }

        /// Simulate the synthesizer reaching the end of the utterance.
        func finish() {
            isSpeaking = false
            guard utteranceIsCurrent else { return }
            utteranceIsCurrent = false
            onFinish?()
        }

        private func deliverFinishIfCurrent() { /* filtered out by the adapter — intentionally silent */ }
    }

    func testStartsIdle() {
        let controller = SpeechController(synthesizer: FakeSynthesizer())
        XCTAssertEqual(controller.state, .idle)
    }

    func testStartSpeakingMovesToSpeakingAndForwardsText() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)
        controller.startSpeaking("hello there")
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(fake.spokenTexts, ["hello there"])
    }

    func testStartSpeakingEmptyTextIsNoOp() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)
        controller.startSpeaking("   \n ")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(fake.spokenTexts.isEmpty)
    }

    func testPauseResumeCycle() {
        let controller = SpeechController(synthesizer: FakeSynthesizer())
        controller.startSpeaking("text")
        controller.pauseOrResume()
        XCTAssertEqual(controller.state, .paused)
        controller.pauseOrResume()
        XCTAssertEqual(controller.state, .speaking)
    }

    func testPauseOrResumeWhileIdleIsNoOp() {
        let controller = SpeechController(synthesizer: FakeSynthesizer())
        controller.pauseOrResume()
        XCTAssertEqual(controller.state, .idle)
    }

    func testStopResetsToIdle() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)
        controller.startSpeaking("text")
        controller.stop()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(fake.stopCount, 1)
    }

    func testStartingWhileSpeakingStopsThePrevious() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)
        controller.startSpeaking("first")
        controller.startSpeaking("second")
        XCTAssertEqual(controller.state, .speaking)
        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(fake.spokenTexts, ["first", "second"])
    }

    func testFinishCallbackReturnsToIdle() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)
        controller.startSpeaking("text")
        fake.finish()
        XCTAssertEqual(controller.state, .idle)
    }

    func testFinishWhileAlreadyIdleStaysIdle() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)
        fake.finish()
        XCTAssertEqual(controller.state, .idle)
    }
    /// The shipping synthesizer reports a STOPPED utterance as `didFinish`. Forwarding it set the
    /// transport to `.idle` while the utterance that replaced it was still audible: Pause and Stop
    /// greyed out with audio playing, and the next Start Speaking queued instead of restarting.
    func testRestartingWhileSpeakingStaysSpeakingWhenTheStoppedUtteranceReportsFinish() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)

        controller.startSpeaking("first passage")
        controller.startSpeaking("second passage")

        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(fake.spokenTexts, ["first passage", "second passage"])
        XCTAssertEqual(controller.state, .speaking, "the replacement utterance is still being read")
    }

    /// `pauseSpeaking(at: .word)` is deferred, so a Resume issued before the pause lands used to be
    /// overtaken by it — audio silent forever while the transport still said `.speaking`.
    func testPauseLandingAfterResumeReIssuesTheResume() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)

        controller.startSpeaking("a passage")
        controller.pauseOrResume()          // Pause — request made, not yet landed
        XCTAssertEqual(controller.state, .paused)
        controller.pauseOrResume()          // Resume, before the word boundary
        XCTAssertEqual(controller.state, .speaking)

        fake.deliverPendingPause()          // the deferred pause arrives now

        XCTAssertFalse(fake.isPaused, "a pause landing after resume must be undone, not left latched")
        XCTAssertEqual(controller.state, .speaking)
    }

    func testOrdinaryPauseAndResumeStillWork() {
        let fake = FakeSynthesizer()
        let controller = SpeechController(synthesizer: fake)

        controller.startSpeaking("a passage")
        controller.pauseOrResume()
        fake.deliverPendingPause()
        XCTAssertTrue(fake.isPaused)
        XCTAssertEqual(controller.state, .paused)

        controller.pauseOrResume()
        XCTAssertFalse(fake.isPaused)
        XCTAssertEqual(controller.state, .speaking)
    }

}
