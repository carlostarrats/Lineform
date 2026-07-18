import AVFoundation
import Foundation

enum SpeechState: Equatable { case idle, speaking, paused }

/// A small seam over `AVSpeechSynthesizer` so `SpeechController`'s state machine is unit-testable
/// with a fake and no real audio.
protocol SpeechSynthesizing: AnyObject {
    /// Invoked (on the main thread) when the current utterance finishes on its own. NOT invoked
    /// for a user-initiated `stop()`.
    var onFinish: (() -> Void)? { get set }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    func speak(_ text: String)
    func pause()
    func continueSpeaking()
    func stop()
}

/// Owns one synthesizer and a three-state transport machine (idle / speaking / paused). The menu
/// enable/disable and the Pause·Resume label read `state`. `stop()` is called on document close /
/// app quit by the owner (`EditorContainerView`).
@MainActor
final class SpeechController: ObservableObject {
    @Published private(set) var state: SpeechState = .idle
    private let synthesizer: SpeechSynthesizing

    init(synthesizer: SpeechSynthesizing = SystemSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        self.synthesizer.onFinish = { [weak self] in
            guard let self, self.state != .idle else { return }
            self.state = .idle
        }
    }

    func startSpeaking(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if state != .idle { synthesizer.stop() }
        state = .speaking
        synthesizer.speak(text)
    }

    func pauseOrResume() {
        switch state {
        case .speaking:
            synthesizer.pause()
            state = .paused
        case .paused:
            synthesizer.continueSpeaking()
            state = .speaking
        case .idle:
            break
        }
    }

    func stop() {
        guard state != .idle else { return }
        synthesizer.stop()
        state = .idle
    }
}

/// Production adapter over `AVSpeechSynthesizer` (system default voice + rate in v1). Offline,
/// no network, no entitlement. Not unit-tested — it is the real audio path; the state machine it
/// drives is tested via `SpeechSynthesizing`.
final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }
    var isPaused: Bool { synthesizer.isPaused }

    func speak(_ text: String) {
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    func pause() { synthesizer.pauseSpeaking(at: .word) }
    func continueSpeaking() { synthesizer.continueSpeaking() }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }

    // A user `stop()` fires didCancel, NOT didFinish. The controller has already set `.idle`, so
    // we deliberately do nothing here (do not forward as a finish).
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}
}
