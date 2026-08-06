import Foundation

/// One installed voice, reduced to what the choice actually turns on. Mirrors the fields of
/// `AVSpeechSynthesisVoice` the resolver reads, so the decision can be tested without depending on
/// which voices happen to be installed on the machine running the suite.
struct SpeechVoiceCandidate: Equatable {
    /// `AVSpeechSynthesisVoice.identifier`.
    let identifier: String
    /// `AVSpeechSynthesisVoice.language` — a BCP-47 tag such as `"fr-CA"` or `"zh-TW"`.
    let language: String

    init(identifier: String, language: String) {
        self.identifier = identifier
        self.language = language
    }
}

/// What to do with `AVSpeechUtterance.voice` for one utterance.
enum SpeechVoiceDecision: Equatable {
    /// Leave `voice` nil. The synthesizer then reads with the voice the user chose in
    /// System Settings ▸ Accessibility ▸ Spoken Content — which is the right answer whenever the
    /// document is in the language that voice already speaks.
    case keepSystemDefault
    /// Force this installed voice, chosen by identifier so the region survives.
    case voice(identifier: String)
    /// The document is in another language but nothing installed matches; let AVFoundation resolve
    /// the tag itself (it may return nil, which is the same as keeping the default).
    case language(String)
}

/// Decides whether a detected document language justifies overriding the user's own voice, and if
/// so which installed voice to use.
///
/// The governing rule: **the user's voice selection wins unless there is positive evidence the
/// document is in a different language than that voice speaks.** The first version of this feature
/// overrode unconditionally whenever detection succeeded, which forced every en-GB / en-AU user
/// onto en-US Samantha for ordinary English prose — the common case made worse to fix an edge case.
///
/// The second rule is that an override must not throw away the region. `AVSpeechSynthesisVoice(language:)`
/// picks an arbitrary region for a bare tag (`fr` → fr-CA even with fr-FR installed, `zh-Hant` →
/// zh-CN Tingting even with zh-TW Meijia installed), so an installed region-matched voice is
/// preferred before that fallback is used.
enum SpeechVoiceResolver {

    /// - Parameters:
    ///   - detectedLanguage: `SpeechLanguageDetector.language(for:)`'s answer; nil means detection
    ///     declined and nothing may be overridden.
    ///   - systemDefaultLanguage: `AVSpeechSynthesisVoice.currentLanguageCode()` — the tag of the
    ///     voice the user picked in Spoken Content.
    ///   - preferredRegion: the user's own region (`Locale.current.region?.identifier`), used to
    ///     break ties when a language has installed voices in several regions.
    ///   - availableVoices: `AVSpeechSynthesisVoice.speechVoices()`, in the order the system gives
    ///     them; list order is the last tiebreaker, so the result is deterministic.
    static func decision(
        detectedLanguage: String?,
        systemDefaultLanguage: String?,
        preferredRegion: String?,
        availableVoices: [SpeechVoiceCandidate]
    ) -> SpeechVoiceDecision {
        guard let detectedLanguage, let detected = LanguageTag(detectedLanguage) else {
            return .keepSystemDefault
        }

        // The whole point: agreement is NOT an override. A `fr` document on a machine whose Spoken
        // Content voice is fr-FR Thomas must keep Thomas, not be re-resolved to fr-CA Amélie.
        if let systemDefaultLanguage,
           let systemTag = LanguageTag(systemDefaultLanguage),
           detected.isCompatible(with: systemTag) {
            return .keepSystemDefault
        }

        if let match = bestVoice(for: detected, preferredRegion: preferredRegion, among: availableVoices) {
            return .voice(identifier: match.identifier)
        }

        return .language(detectedLanguage)
    }

    private static func bestVoice(
        for detected: LanguageTag,
        preferredRegion: String?,
        among voices: [SpeechVoiceCandidate]
    ) -> SpeechVoiceCandidate? {
        let normalizedPreferredRegion = preferredRegion?.uppercased()
        var best: (rank: Int, voice: SpeechVoiceCandidate)?

        for voice in voices {
            guard let tag = LanguageTag(voice.language), detected.isCompatible(with: tag) else { continue }

            // Lower is better. List order breaks ties because the first hit at a rank is kept.
            let rank: Int
            if let detectedRegion = detected.region, tag.region == detectedRegion {
                rank = 0                                    // the document's own region was explicit
            } else if let normalizedPreferredRegion, tag.region == normalizedPreferredRegion {
                rank = 1                                    // the user's region
            } else if tag.region != nil {
                rank = 2                                    // some other region
            } else {
                rank = 3                                    // a region-less tag
            }

            if best == nil || rank < best!.rank {
                best = (rank, voice)
            }
        }

        return best?.voice
    }
}

/// The slice of BCP-47 this decision needs: language, script, region — with the script INFERRED for
/// Chinese, where the region is what actually carries Simplified vs Traditional. Without that,
/// `zh-Hant` "agrees with" a zh-CN system voice and a Traditional document is read in Simplified.
private struct LanguageTag {
    let language: String
    let script: String?
    let region: String?

    init?(_ raw: String) {
        let parts = raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let first = parts.first, !first.isEmpty else { return nil }
        language = first.lowercased()

        var script: String?
        var region: String?
        for part in parts.dropFirst() {
            if part.count == 4, part.allSatisfy({ $0.isLetter }) {
                script = script ?? part.capitalized
            } else if (part.count == 2 && part.allSatisfy { $0.isLetter })
                        || (part.count == 3 && part.allSatisfy { $0.isNumber }) {
                region = region ?? part.uppercased()
            }
        }
        self.script = script
        self.region = region
    }

    /// The script this tag is written in, explicit or inferred from the region.
    var effectiveScript: String? {
        if let script { return script }
        guard language == "zh", let region else { return nil }
        switch region {
        case "CN", "SG", "MY": return "Hans"
        case "TW", "HK", "MO": return "Hant"
        default: return nil
        }
    }

    /// Two tags describe the same spoken language when the language subtags match and neither
    /// commits to a different script. A tag with no known script is compatible with either — a bare
    /// `zh` voice is a usable, if unspecific, answer for a `zh-Hant` document.
    func isCompatible(with other: LanguageTag) -> Bool {
        guard language == other.language else { return false }
        guard let mine = effectiveScript, let theirs = other.effectiveScript else { return true }
        return mine == theirs
    }
}
