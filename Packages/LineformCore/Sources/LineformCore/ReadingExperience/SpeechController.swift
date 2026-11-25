import AVFoundation
import Foundation

public enum SpeechState: Equatable { case idle, speaking, paused }

/// A small seam over `AVSpeechSynthesizer` so `SpeechController`'s state machine is unit-testable
/// with a fake and no real audio.
public protocol SpeechSynthesizing: AnyObject {
    /// Invoked (on the main thread) when the CURRENT utterance finishes on its own.
    ///
    /// Not invoked for an utterance the app stopped. Note this is enforced by tracking which
    /// utterance is current, NOT by trusting the framework to report a stop as `didCancel`:
    /// `AVSpeechSynthesizer.stopSpeaking(at: .immediate)` in fact delivers `didFinish`, ~30 ms
    /// later — after `startSpeaking` has already set `.speaking` for the NEXT utterance — so a
    /// naive forward clobbered the transport to `.idle` while new audio was playing.
    var onFinish: (() -> Void)? { get set }
    /// Invoked when a pause actually takes effect. `pauseSpeaking(at: .word)` is asynchronous, so
    /// the transport cannot assume its request landed.
    var onPause: (() -> Void)? { get set }
    /// Invoked when speech actually resumes.
    var onContinue: (() -> Void)? { get set }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    /// `languageCode` is the DOCUMENT's language (BCP-47), or nil to keep the synthesizer's
    /// default. It is not the UI language — that is the bug this parameter exists to fix.
    func speak(_ text: String, languageCode: String?)
    func pause()
    func continueSpeaking()
    func stop()
}

/// Owns one synthesizer and a three-state transport machine (idle / speaking / paused). The menu
/// enable/disable and the Pause·Resume label read `state`. `stop()` is called on document close /
/// app quit by the owner (`EditorContainerView`).
@MainActor
public final class SpeechController: ObservableObject {
    @Published public private(set) var state: SpeechState = .idle
    private let synthesizer: SpeechSynthesizing

    public init(synthesizer: SpeechSynthesizing = SystemSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        self.synthesizer.onFinish = { [weak self] in
            guard let self, self.state != .idle else { return }
            self.state = .idle
        }
        // `state` is the user's INTENT, set optimistically so the menu responds to the click. The
        // synthesizer's pause is deferred to a word boundary, so a request can land after the user
        // has already asked for the opposite. When that happens, re-issue — otherwise a Pause that
        // lands just after a Resume leaves audio permanently silent while the transport (and the
        // menu) still say "speaking".
        self.synthesizer.onPause = { [weak self] in
            guard let self, self.state == .speaking else { return }
            self.synthesizer.continueSpeaking()
        }
        self.synthesizer.onContinue = { [weak self] in
            guard let self, self.state == .paused else { return }
            self.synthesizer.pause()
        }
    }

    public func startSpeaking(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if state != .idle { synthesizer.stop() }
        state = .speaking
        synthesizer.speak(text, languageCode: SpeechLanguageDetector.language(for: text))
    }

    public func pauseOrResume() {
        switch state {
        case .speaking:
            state = .paused
            synthesizer.pause()
        case .paused:
            state = .speaking
            synthesizer.continueSpeaking()
        case .idle:
            break
        }
    }

    public func stop() {
        guard state != .idle else { return }
        synthesizer.stop()
        state = .idle
    }
}

/// Production adapter over `AVSpeechSynthesizer` (system default rate; the user's own Spoken
/// Content voice unless the document is positively in another language, per `SpeechVoiceResolver`).
/// Offline, no network, no entitlement. Not unit-tested — it is the real audio path; the state
/// machine it drives is tested via `SpeechSynthesizing`, and the voice choice via the resolver.
public final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    // Set exactly once by `SpeechController.init` before any speech starts, then only read from the
    // didFinish callback (which hops to main before invoking). No concurrent mutation, so the
    // Sendable-mutable-state check is safe to opt out of here.
    public nonisolated(unsafe) var onFinish: (() -> Void)?
    public nonisolated(unsafe) var onPause: (() -> Void)?
    public nonisolated(unsafe) var onContinue: (() -> Void)?
    /// The utterance the app most recently asked for, or nil after a stop. `didFinish` is forwarded
    /// only for this one — see the `onFinish` contract on `SpeechSynthesizing`.
    private nonisolated(unsafe) var currentUtterance: AVSpeechUtterance?
    // Control methods are driven from the @MainActor `SpeechController`; AVSpeechSynthesizer is not
    // Sendable but is only ever touched through those main-actor-serialized calls.
    private nonisolated(unsafe) let synthesizer = AVSpeechSynthesizer()
    /// Read with the best-sounding installed voice for the language
    /// (`SpeechVoiceResolver.bestQualityVoice`) instead of leaving the system's default. iPhone
    /// sets it: there a nil voice is the compact default, not the writer's Spoken Content voice.
    private let prefersBestQualityVoice: Bool

    public init(prefersBestQualityVoice: Bool = false) {
        self.prefersBestQualityVoice = prefersBestQualityVoice
        super.init()
        synthesizer.delegate = self
    }

    private static func candidate(_ voice: AVSpeechSynthesisVoice) -> SpeechVoiceCandidate {
        let quality: SpeechVoiceCandidate.Quality = switch voice.quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .standard
        }
        return SpeechVoiceCandidate(
            identifier: voice.identifier,
            language: voice.language,
            quality: quality,
            isNovelty: voice.voiceTraits.contains(.isNoveltyVoice)
        )
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }
    public var isPaused: Bool { synthesizer.isPaused }

    public func speak(_ text: String, languageCode: String?) {
        let utterance = AVSpeechUtterance(string: text)
        if prefersBestQualityVoice {
            let language = languageCode ?? AVSpeechSynthesisVoice.currentLanguageCode()
            if let best = SpeechVoiceResolver.bestQualityVoice(
                for: language,
                systemDefaultIdentifier: AVSpeechSynthesisVoice(language: language)?.identifier,
                preferredRegion: Locale.current.region?.identifier,
                among: AVSpeechSynthesisVoice.speechVoices().map { voice in Self.candidate(voice) }
            ), let voice = AVSpeechSynthesisVoice(identifier: best.identifier) {
                utterance.voice = voice
                currentUtterance = utterance
                synthesizer.speak(utterance)
                return
            }
        }
        // The user's own Spoken Content voice wins unless the document is positively in another
        // language — `SpeechVoiceResolver` owns that judgement (and the region preference behind
        // it); see its doc comment for why an unconditional override was a regression.
        switch SpeechVoiceResolver.decision(
            detectedLanguage: languageCode,
            systemDefaultLanguage: AVSpeechSynthesisVoice.currentLanguageCode(),
            preferredRegion: Locale.current.region?.identifier,
            availableVoices: AVSpeechSynthesisVoice.speechVoices().map {
                SpeechVoiceCandidate(identifier: $0.identifier, language: $0.language)
            }
        ) {
        case .keepSystemDefault:
            break                       // leaving `voice` nil IS the user's own selection
        case .voice(let identifier):
            // Nil for a voice that vanished between the enumeration and here; assigning nil is the
            // same as never setting it, so the default still applies.
            utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
        case .language(let tag):
            // Nothing installed matched; let AVFoundation resolve the bare tag (nil if uninstalled).
            utterance.voice = AVSpeechSynthesisVoice(language: tag)
        }
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    public func pause() { synthesizer.pauseSpeaking(at: .word) }
    public func continueSpeaking() { synthesizer.continueSpeaking() }

    public func stop() {
        // Cleared BEFORE the call: the stopped utterance's `didFinish` must not be forwarded, and
        // it can arrive before this method returns.
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    // `SpeechController` is `@MainActor`; `AVSpeechSynthesizerDelegate` callbacks are not
    // documented as guaranteed main-thread, so hop explicitly before touching controller state.
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Identity check, not a didCancel/didFinish distinction. A stopped utterance reports
        // `didFinish` on macOS 26, so forwarding unconditionally set the transport to `.idle`
        // while the utterance that REPLACED it was still being read: Pause and Stop greyed out
        // with audio playing, and the next Start Speaking queued behind it instead of restarting.
        guard utterance === currentUtterance else { return }
        currentUtterance = nil
        if Thread.isMainThread {
            onFinish?()
        } else {
            DispatchQueue.main.async { [onFinish] in
                onFinish?()
            }
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        if Thread.isMainThread { onPause?() } else { DispatchQueue.main.async { [onPause] in onPause?() } }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        if Thread.isMainThread { onContinue?() } else { DispatchQueue.main.async { [onContinue] in onContinue?() } }
    }
}
