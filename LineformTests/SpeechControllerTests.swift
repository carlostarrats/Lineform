import XCTest
@testable import Lineform

@MainActor
final class SpeechControllerTests: XCTestCase {
    final class FakeSynthesizer: SpeechSynthesizing {
        var onFinish: (() -> Void)?
        private(set) var isSpeaking = false
        private(set) var isPaused = false
        private(set) var spokenTexts: [String] = []
        private(set) var stopCount = 0

        func speak(_ text: String) { spokenTexts.append(text); isSpeaking = true; isPaused = false }
        func pause() { isPaused = true }
        func continueSpeaking() { isPaused = false }
        func stop() { stopCount += 1; isSpeaking = false; isPaused = false }

        /// Simulate the synthesizer reaching the end of the utterance.
        func finish() { isSpeaking = false; onFinish?() }
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
}
