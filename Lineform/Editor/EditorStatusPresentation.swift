import SwiftUI

enum EditorStatusFormatter {
    static let maximumStatusMessageLength = 72

    struct LastSavedDisplay: Equatable {
        var label: String
        var detail: String?

        var accessibilityText: String {
            if let detail {
                return "\(label) \(detail)"
            }

            return label
        }
    }

    static func statisticsText(wordCount: Int, characterCount: Int) -> String {
        "\(wordCount) words — \(characterCount) characters"
    }

    static func statusText(
        wordCount: Int,
        characterCount: Int,
        isPreparingSuggestion: Bool,
        intelligentEditingStatus: String?
    ) -> String {
        let statistics = statisticsText(wordCount: wordCount, characterCount: characterCount)

        if isPreparingSuggestion {
            return statistics
        }

        if let message = statusMessage(
            isPreparingSuggestion: false,
            intelligentEditingStatus: intelligentEditingStatus
        ) {
            return "\(message) — \(statistics)"
        }

        return statistics
    }

    static func statusMessage(
        isPreparingSuggestion: Bool,
        intelligentEditingStatus: String?
    ) -> String? {
        if isPreparingSuggestion {
            return nil
        }

        guard let intelligentEditingStatus else {
            return nil
        }

        let message = userFacingMessage(from: intelligentEditingStatus)
        guard !message.isEmpty else {
            return nil
        }

        return truncatedStatusMessage(message)
    }

    static func statusIndicator(
        isPreparingSuggestion: Bool,
        intelligentEditingStatus: String?,
        intelligenceAvailability: IntelligenceAvailabilityStatus
    ) -> EditorStatusIndicator {
        guard intelligenceAvailability.isAvailable else {
            return EditorStatusIndicator(text: "AI not enabled", tone: .warning)
        }

        if let message = statusMessage(
            isPreparingSuggestion: isPreparingSuggestion,
            intelligentEditingStatus: intelligentEditingStatus
        ) {
            return EditorStatusIndicator(text: message, tone: .warning)
        }

        return EditorStatusIndicator(text: "AI available", tone: .available)
    }

    static func metadataText(lastSavedDisplay: LastSavedDisplay, statisticsText: String) -> String {
        if let detail = lastSavedDisplay.detail {
            return "\(lastSavedDisplay.label): \(detail)  |  \(statisticsText)"
        }

        return "\(lastSavedDisplay.label)  |  \(statisticsText)"
    }

    private static func userFacingMessage(from status: String) -> String {
        let trimmedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if
            trimmedStatus.contains("Apple Intelligence returned an unusable replacement")
                || trimmedStatus.contains("unchangedTransformOutput")
                || trimmedStatus.contains("fallback rejected")
                || trimmedStatus == "Intelligence could not make a useful suggestion."
                || trimmedStatus == "No replacement was suggested."
        {
            return "Suggestion unavailable."
        }

        let visibleMessages = [
            "Suggestion unavailable.",
            "Suggestion took too long.",
            "Apple Intelligence is not available on this Mac.",
            "Apple Intelligence is turned off in System Settings.",
            "Apple Intelligence is not ready yet.",
            "Apple Intelligence is unavailable.",
            "Apple Intelligence editing requires macOS 26 or later.",
            "Apple Intelligence editing requires Foundation Models."
        ]

        if visibleMessages.contains(trimmedStatus) {
            return trimmedStatus
        }

        let visibleAppleAvailabilityPrefixes = [
            "Apple Intelligence is not available on this Mac.",
            "Apple Intelligence is turned off in System Settings.",
            "Apple Intelligence is not ready yet.",
            "Apple Intelligence is unavailable.",
            "Apple Intelligence editing requires macOS 26 or later.",
            "Apple Intelligence editing requires Foundation Models."
        ]

        return visibleAppleAvailabilityPrefixes.contains { trimmedStatus.hasPrefix($0) } ? trimmedStatus : ""
    }

    private static func truncatedStatusMessage(_ message: String) -> String {
        guard message.count > maximumStatusMessageLength else {
            return message
        }

        return "\(message.prefix(maximumStatusMessageLength - 1))…"
    }

    static func lastSavedText(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        lastSavedDisplay(for: date, now: now, calendar: calendar).accessibilityText
    }

    static func lastSavedDisplay(for date: Date?, now: Date = Date(), calendar: Calendar = .current) -> LastSavedDisplay {
        guard let date else {
            return LastSavedDisplay(label: "Not saved yet", detail: nil)
        }

        let timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            return LastSavedDisplay(label: "Last save", detail: formatted(date, format: "h:mm a", timeZone: timeZone))
        }

        return LastSavedDisplay(label: "Last save", detail: formatted(date, format: "MMM d, yyyy 'at' h:mm a", timeZone: timeZone))
    }

    private static func formatted(_ date: Date, format: String, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

struct EditorStatusIndicator: Equatable {
    enum Tone: Equatable {
        case available
        case warning
    }

    var text: String
    var tone: Tone

    var accessibilityText: String {
        switch tone {
        case .available:
            return "Status: \(text)"
        case .warning:
            return "Warning: \(text)"
        }
    }
}

struct EditorStatusBar: View {
    static let showsTopSeparator = false
    static let lastSavedDetailUsesPrimaryForeground = false
    static let horizontalInset: CGFloat = 28
    static let statusMessageMaximumWidth: CGFloat = 520
    static let statusDotDiameter: CGFloat = 7

    static func isVisible(in mode: EditorDisplayMode) -> Bool {
        mode != .read
    }

    var lastSavedDisplay: EditorStatusFormatter.LastSavedDisplay
    var statusIndicator: EditorStatusIndicator
    var statisticsText: String
    var statusAccessibilityLabel: String
    var usesDarkChrome: Bool

    nonisolated static func warningAmberColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor(srgbRed: 0.97, green: 0.73, blue: 0.33, alpha: 1)
            : NSColor(srgbRed: 0.48, green: 0.29, blue: 0.0, alpha: 1)
    }

    nonisolated static func availableGreenColor(usesDarkChrome: Bool) -> NSColor {
        usesDarkChrome
            ? NSColor(srgbRed: 0.47, green: 0.84, blue: 0.50, alpha: 1)
            : NSColor(srgbRed: 0.0, green: 0.39, blue: 0.16, alpha: 1)
    }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color(nsColor: statusIndicatorColor))
                    .frame(width: Self.statusDotDiameter, height: Self.statusDotDiameter)

                Text(statusIndicator.text)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: statusIndicatorColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.statusMessageMaximumWidth, alignment: .leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(statusIndicator.accessibilityText)

            Spacer(minLength: 16)

            Text(EditorStatusFormatter.metadataText(lastSavedDisplay: lastSavedDisplay, statisticsText: statisticsText))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel("\(lastSavedDisplay.accessibilityText), \(statusAccessibilityLabel)")
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.vertical, 6)
    }

    private var statusIndicatorColor: NSColor {
        switch statusIndicator.tone {
        case .available:
            return Self.availableGreenColor(usesDarkChrome: usesDarkChrome)
        case .warning:
            return Self.warningAmberColor(usesDarkChrome: usesDarkChrome)
        }
    }
}
