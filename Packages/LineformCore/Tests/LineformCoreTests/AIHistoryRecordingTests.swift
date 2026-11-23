import XCTest
@testable import LineformCore
import LineformCoreTestSupport

/// The controller's History calls, through `AIHistoryRecording`, in order. The Mac's
/// `DocumentHistoryController` conforms; its real behaviour behind these calls is covered by the
/// Mac's `AIActionControllerHistoryTests`.
@MainActor
final class AIHistoryRecordingTests: XCTestCase {
    private var suiteName = ""

    override func tearDown() {
        if !suiteName.isEmpty { UserDefaults().removePersistentDomain(forName: suiteName) }
        super.tearDown()
    }

    /// Keep the surface: the controller holds its editor weakly.
    private func make(_ text: String, _ behavior: FakeAIClient.Behavior)
        -> (AIActionController, FakeAIEditorSurface, FakeAIHistoryRecorder) {
        suiteName = "AIHistoryRecordingTests.\(UUID().uuidString)"
        let store = AIConnectionStore(defaults: UserDefaults(suiteName: suiteName)!, keychain: InMemoryAIKeychain())
        XCTAssertNil(store.connect(.claude, key: "test-key-not-real"))
        let fake = FakeAIClient(behavior)
        let controller = AIActionController(connectionStore: store) { _ in fake }
        let surface = FakeAIEditorSurface(text)
        let history = FakeAIHistoryRecorder()
        controller.editor = surface
        controller.history = history
        return (controller, surface, history)
    }

    private func whole(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    private func replace(_ words: [String: String]) -> FakeAIClient.Behavior {
        FakeAIClient.revising { _, segment in
            var result = segment
            for (old, new) in words { result = result.replacingOccurrences(of: old, with: new) }
            return result
        }
    }

    /// An accept: the range is widened first, History hears the action start, the edits are
    /// applied between will/did, each changed paragraph is recorded, and the action ends
    /// with the first recorded passage.
    func testAcceptRecordsOncePerChangedParagraphThenEnds() async throws {
        let text = "One big dog.\n\nTwo big cats."
        let (controller, surface, history) = make(text, replace(["big": "small"]))
        controller.run(.rephrase, range: whole(text), text: text)
        await controller.runTask?.value
        XCTAssertEqual(history.calls, [.actionRange(whole(text)), .actionWillStart], "History records once, at the end")
        controller.handle(.acceptCurrent)
        XCTAssertEqual(surface.string, "One small dog.\n\nTwo small cats.")
        let accepted = surface.string as NSString
        XCTAssertEqual(history.calls, [
            .actionRange(whole(text)), .actionWillStart,
            .acceptWillApply, .acceptDidApply,
            .recordAccepted(range: accepted.range(of: "One small dog."), original: "One big dog.", accepted: "One small dog."),
            .recordAccepted(range: accepted.range(of: "Two small cats."), original: "Two big cats.", accepted: "Two small cats."),
            .acceptRecordingDidFinish,
            .actionDidEnd(recorded: history.recordedIDs.first, changedRange: whole(surface.string), text: surface.string),
        ])
    }

    func testRejectRecordsNothing() async {
        let text = "The big dog."
        let (controller, surface, history) = make(text, replace(["big": "small"]))
        controller.run(.rephrase, range: whole(text), text: text)
        await controller.runTask?.value
        controller.handle(.end)
        XCTAssertEqual(surface.string, text)
        XCTAssertEqual(history.calls, [.actionRange(whole(text)), .actionWillStart,
                                       .actionDidEnd(recorded: nil, changedRange: nil, text: text)])
    }

    func testAbandonAndTypingNeverSettleHistory() async {
        let text = "The big dog."
        let (controller, surface, history) = make(text, replace(["big": "small"]))
        controller.run(.rephrase, range: whole(text), text: text)
        await controller.runTask?.value
        guard case .reviewing = controller.state else { return XCTFail("\(controller.state)") }
        controller.abandon()
        XCTAssertTrue(surface.editCalls.isEmpty)
        XCTAssertEqual(history.calls.last, .actionAbandoned)
        XCTAssertFalse(history.calls.contains { if case .actionDidEnd = $0 { return true } else { return false } })

        let (typing, typingSurface, typingHistory) = make(text, replace(["big": "small"]))
        typing.run(.rephrase, range: whole(text), text: text)
        await typing.runTask?.value
        guard case .reviewing = typing.state else { return XCTFail("\(typing.state)") }
        typing.handle(.typed("x"))
        XCTAssertEqual(typingSurface.typed, ["x"])
        XCTAssertEqual(typingHistory.calls.last, .actionAbandoned)
        XCTAssertFalse(typingHistory.calls.contains { if case .actionDidEnd = $0 { return true } else { return false } })
    }

    /// History mode refuses an action outright: nothing is asked, nothing is sent.
    func testHistoryModeRefusesTheAction() async {
        let text = "The big dog."
        let (controller, _, history) = make(text, replace(["big": "small"]))
        history.allowsAction = false
        XCTAssertFalse(controller.isAvailable(for: whole(text), text: text))
        controller.run(.rephrase, range: whole(text), text: text)
        XCTAssertNil(controller.runTask)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(history.calls, [])
    }

    /// The range History widens to is the range sent and reviewed.
    func testTheWidenedRangeIsWhatIsReviewed() async throws {
        let text = "The big dog ran."
        let (controller, surface, history) = make(text, replace(["big": "small"]))
        history.widen = { _ in NSRange(location: 0, length: (text as NSString).length) }
        controller.run(.rephrase, range: NSRange(location: 4, length: 3), text: text)
        await controller.runTask?.value
        guard case .reviewing(let session) = controller.state else { return XCTFail("\(controller.state)") }
        XCTAssertEqual(session.selectionRange, whole(text))
        XCTAssertEqual(history.calls.first, .actionRange(NSRange(location: 4, length: 3)))
        XCTAssertTrue(surface.editCalls.isEmpty)
    }
}
