import SwiftUI

enum EditorStatusFormatter {
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

    static func statusText(wordCount: Int, characterCount: Int) -> String {
        statisticsText(wordCount: wordCount, characterCount: characterCount)
    }

    static func metadataText(lastSavedDisplay: LastSavedDisplay, statisticsText: String) -> String {
        if let detail = lastSavedDisplay.detail {
            return "\(lastSavedDisplay.label): \(detail)  |  \(statisticsText)"
        }

        return "\(lastSavedDisplay.label)  |  \(statisticsText)"
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
    var statisticsText: String
    var statusAccessibilityLabel: String

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
}
