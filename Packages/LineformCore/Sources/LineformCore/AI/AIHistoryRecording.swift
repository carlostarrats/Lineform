import Foundation

/// History as an AI action sees it: everything `AIActionController` asks of it, and nothing more.
/// The Mac's `DocumentHistoryController` conforms; the iPhone has no History yet (roadmap step 9),
/// so its controller runs with none.
///
/// The order the controller calls these in is part of the contract (`AIHistoryRecordingTests`):
/// `aiActionRange` then `aiActionWillStart` when a request starts; on an accept,
/// `aiAcceptWillApply`, the edits, `aiAcceptDidApply`, one `recordAccepted` per changed
/// paragraph, then `aiAcceptRecordingDidFinish`; and the action's end is exactly one of
/// `aiActionDidEnd` or `aiActionAbandoned`.
@MainActor
public protocol AIHistoryRecording: AnyObject {
    /// False while History mode is on: History and AI never overlap.
    func allowsAIAction(on range: NSRange) -> Bool
    /// `range` grown over any History passage it only partly covers, so an accepted change never
    /// straddles (and drops) a passage boundary.
    func aiActionRange(for range: NSRange) -> NSRange
    /// A request is about to start. History mode, if on, remembers its passage and ends.
    func aiActionWillStart()
    /// The action ended (accepted, rejected, cancelled, a message or an error). `recorded`: the
    /// first passage the accept recorded; `changedRange`: where the accepted change sits in `text`.
    func aiActionDidEnd(recorded: UUID?, changedRange: NSRange?, text: String)
    /// The action ended in a way that must not bring History back (reload, a document swap,
    /// typing, History opening on its own target, Mark's marks).
    func aiActionAbandoned()
    /// Brackets the accepted edits: passages the edits would drop are set aside, not lost.
    func aiAcceptWillApply()
    func aiAcceptDidApply()
    /// One changed paragraph of an accept. `text` is the document after the accept.
    @discardableResult
    func recordAccepted(range: NSRange, original: String, accepted: String, text: String) -> UUID?
    /// The accept's recording is over: set-aside passages nothing could hold are dropped.
    func aiAcceptRecordingDidFinish()
}
