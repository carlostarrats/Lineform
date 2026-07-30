import Foundation

/// One announcement from the remote feed, after validation.
///
/// `title` and `body` are rendered as PLAIN `Text`, never Markdown and never HTML —
/// the feed is remote content, so giving it a rendering surface would hand a
/// compromised or mistyped file a way to draw arbitrary UI inside the editor.
/// Everything here is length-bounded and control-character-free by construction:
/// `AnnouncementFeed.decode` is the only way to build one from bytes.
struct Announcement: Equatable, Identifiable {
    /// Dismissal key. Stable forever; never reuse an id for different content, or
    /// anyone who dismissed the old one silently never sees the new one.
    let id: String
    let title: String
    let body: String
    /// Present only when `actionURL` is too — the pair is validated together, so a
    /// button can never render without a destination (or a destination go unclickable).
    let actionLabel: String?
    let actionURL: URL?
    /// Lowest app version this is meant for. Nil means "any version".
    let minAppVersion: String?

    /// Whether this announcement should be shown to a build reporting `appVersion`.
    /// Stops "update to 1.6" reaching someone already on 1.7.
    func appliesTo(appVersion: String) -> Bool {
        guard let minAppVersion else { return true }
        return AnnouncementFeed.compareVersions(appVersion, minAppVersion) != .orderedAscending
    }
}

/// Decoding + validation for `announcements.json`.
///
/// Every limit here exists to bound what a remote file can do to the app: a feed that
/// is too large, malformed, or hostile must produce NOTHING rather than a partial or
/// oversized UI. Validation is per-entry and lenient at the feed level — one bad
/// entry is skipped, it does not discard the entries around it, because the alternative
/// is that a single typo silently kills the whole channel.
enum AnnouncementFeed {
    /// Hard ceiling on the response body. The real file is a few hundred bytes; this is
    /// generous enough to never bite and small enough that a redirect to something huge
    /// can't be buffered into memory.
    static let maximumPayloadBytes = 64 * 1024

    /// Only entries beyond this count are dropped, so a runaway file can't produce an
    /// unbounded decode. Far above any real feed.
    static let maximumEntryCount = 20

    static let maximumIDLength = 64
    static let maximumTitleLength = 120
    static let maximumBodyLength = 300
    static let maximumActionLabelLength = 40
    /// The destination is remote input like everything else, and was the ONE string with
    /// no ceiling. Unbounded, a pathological URL could push the re-encoded cache past
    /// `maximumPayloadBytes`, at which point the cached feed silently stops decoding and
    /// every relaunch loses the card. Generous next to any real link.
    static let maximumActionURLLength = 512

    /// The only scheme an announcement may link to. Deliberately a single-scheme
    /// allowlist, not a denylist of dangerous schemes: this is remote input, so the
    /// safe default is "nothing unless explicitly permitted". (Contrast the HTML
    /// exporter, which strips a closed set from the USER'S OWN document — different
    /// trust level, different rule.)
    static let allowedURLScheme = "https"

    private struct Payload: Decodable {
        let version: Int
        let announcements: [Entry]

        struct Entry: Decodable {
            let id: String
            let title: String
            let body: String
            let actionLabel: String?
            let actionURL: String?
            let minAppVersion: String?
        }
    }

    /// The feed format this build understands. A future feed can bump `version` to
    /// lock out older builds that would misread it; anything not equal to this is
    /// ignored entirely.
    static let supportedVersion = 1

    /// Decode and validate raw response bytes.
    ///
    /// Returns **nil** when the payload is unusable — too large, not JSON, or a feed
    /// version this build doesn't understand — and an **array** (possibly empty) when
    /// the feed is well-formed. The distinction matters: nil means "we learned nothing",
    /// which must leave a previously-shown announcement alone, while [] means the
    /// publisher deliberately retracted everything. Collapsing the two would let one
    /// malformed deploy silently pull a live announcement off every user's screen.
    ///
    /// Never throws: a broken feed is not an error the user should ever learn about.
    static func decode(_ data: Data) -> [Announcement]? {
        guard data.count <= maximumPayloadBytes else { return nil }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        guard payload.version == supportedVersion else { return nil }

        return payload.announcements
            .prefix(maximumEntryCount)
            .compactMap(validated(_:))
    }

    /// Re-emit validated announcements in the feed's own wire format, so the cached copy
    /// in `UserDefaults` can be read back through `decode` and re-validated by exactly
    /// the same rules. Encoding to a different shape would mean a second validator, and
    /// two validators of one format always drift.
    static func encode(_ announcements: [Announcement]) -> Data? {
        let entries: [[String: Any]] = announcements.map { announcement in
            var entry: [String: Any] = [
                "id": announcement.id,
                "title": announcement.title,
                "body": announcement.body,
            ]
            if let label = announcement.actionLabel { entry["actionLabel"] = label }
            if let url = announcement.actionURL { entry["actionURL"] = url.absoluteString }
            if let version = announcement.minAppVersion { entry["minAppVersion"] = version }
            return entry
        }
        let payload: [String: Any] = ["version": supportedVersion, "announcements": entries]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    /// Turn one decoded entry into an `Announcement`, or nil if it breaks any rule.
    private static func validated(_ entry: Payload.Entry) -> Announcement? {
        guard
            let id = sanitized(entry.id, maximumLength: maximumIDLength),
            let title = sanitized(entry.title, maximumLength: maximumTitleLength),
            let body = sanitized(entry.body, maximumLength: maximumBodyLength)
        else { return nil }

        // The label and the destination stand or fall together: a button with no
        // destination is dead UI, and a destination with no label is unreachable.
        var actionLabel: String?
        var actionURL: URL?
        if let rawLabel = entry.actionLabel, let rawURL = entry.actionURL {
            guard
                let label = sanitized(rawLabel, maximumLength: maximumActionLabelLength),
                let url = validatedURL(rawURL)
            else { return nil }
            actionLabel = label
            actionURL = url
        } else if entry.actionLabel != nil || entry.actionURL != nil {
            // Exactly one of the pair was supplied — that's an authoring mistake in the
            // feed, and guessing which half to honour is worse than skipping the entry.
            return nil
        }

        let minAppVersion = entry.minAppVersion.flatMap(validatedVersion(_:))
        if entry.minAppVersion != nil && minAppVersion == nil { return nil }

        return Announcement(
            id: id,
            title: title,
            body: body,
            actionLabel: actionLabel,
            actionURL: actionURL,
            minAppVersion: minAppVersion
        )
    }

    /// Trim, reject empty, reject over-length, and reject any control character.
    /// Control characters are rejected rather than stripped: a string that needs
    /// stripping is not a string the feed author meant to write, and silently
    /// altering remote text is how you end up rendering something nobody reviewed.
    /// Newlines count as control characters — announcements are one-liners.
    static func sanitized(_ raw: String, maximumLength: Int) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength else { return nil }
        // `controlCharacters` is Cc + Cf; it does NOT include U+2028 (LINE SEPARATOR)
        // or U+2029 (PARAGRAPH SEPARATOR), which SwiftUI `Text` still breaks a line on.
        // Union with `newlines` so an interior line separator is rejected like any other
        // newline — an announcement is a one-liner, and a hostile feed cannot smuggle a
        // multi-line card past the "reject, don't strip" rule.
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard trimmed.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        return trimmed
    }

    /// Accept only absolute `https` URLs with a host. Anything else — `javascript:`,
    /// `data:`, `file:`, a scheme-relative path, a bare string — is refused, so the
    /// card's button can only ever hand the system a web address.
    static func validatedURL(_ raw: String) -> URL? {
        guard raw.count <= maximumActionURLLength else { return nil }
        guard let url = URL(string: raw) else { return nil }
        guard url.scheme?.lowercased() == allowedURLScheme else { return nil }
        guard let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Accept a dotted numeric version ("1", "1.5", "1.5.0"). Anything with a
    /// non-numeric component is refused rather than coerced, so a typo can't
    /// accidentally compare as 0 and show an announcement to every build.
    static func validatedVersion(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 4 else { return nil }
        guard components.allSatisfy({ component in
            !component.isEmpty
                && component.count <= 9   // bounded before any Int conversion
                && component.allSatisfy(\.isASCII)
                && component.allSatisfy(\.isNumber)
        }) else { return nil }
        return trimmed
    }

    /// Numeric, component-wise version comparison. Compares as INTEGERS per component
    /// so 1.10 correctly sorts above 1.9 (a lexicographic compare gets this backwards).
    /// Missing trailing components read as 0, so "1.5" == "1.5.0".
    /// Both inputs are assumed to have passed `validatedVersion`; a non-numeric
    /// component defensively reads as 0 rather than trapping.
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }
}
