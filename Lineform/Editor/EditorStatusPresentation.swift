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

    static let updatedIndicatorText = String(localized: "Updated")
    static let unsavedChangesText = String(localized: "Unsaved changes")
    static let savedIndicatorText = String(localized: "Saved")
    static let autosavedIndicatorText = String(localized: "Autosaved")

    struct MetadataSegments: Equatable {
        /// The unsaved-state label ("Not saved yet") when the document has never been
        /// saved; nil for established documents. This is the only colored part of the
        /// metadata line — everything in `neutralText` stays grey.
        var unsavedLabel: String?
        var neutralText: String
    }

    static func statisticsText(for statistics: DocumentStatistics) -> String {
        if statistics.isPredominantlyCJK {
            return String(localized: "\(statistics.characterCount) characters")
        }
        return String(localized: "\(statistics.wordCount) words — \(statistics.characterCount) characters")
    }

    static func statusAccessibilityText(for statistics: DocumentStatistics) -> String {
        if statistics.isPredominantlyCJK {
            return String(localized: "Document contains \(statistics.characterCount) characters")
        }
        return String(localized: "Document contains \(statistics.wordCount) words and \(statistics.characterCount) characters")
    }

    static func metadataSegments(lastSavedDisplay: LastSavedDisplay, statisticsText: String) -> MetadataSegments {
        if let detail = lastSavedDisplay.detail {
            return MetadataSegments(
                unsavedLabel: nil,
                neutralText: "\(lastSavedDisplay.label): \(detail)  |  \(statisticsText)"
            )
        }

        return MetadataSegments(
            unsavedLabel: lastSavedDisplay.label,
            neutralText: "  |  \(statisticsText)"
        )
    }

    static func metadataText(lastSavedDisplay: LastSavedDisplay, statisticsText: String) -> String {
        let segments = metadataSegments(lastSavedDisplay: lastSavedDisplay, statisticsText: statisticsText)
        if let label = segments.unsavedLabel {
            return label + segments.neutralText
        }

        return segments.neutralText
    }

    /// Resolves the left-slot indicator from the document's save signals. Untitled
    /// documents show red "Not saved yet" in the main metadata text instead of a
    /// left indicator, so they always resolve to `.none` here. A live edit always
    /// outranks a lingering green flash.
    static func indicator(savedAt: Date?, isDirty: Bool, flash: EditorStatusFlash?) -> EditorStatusIndicator {
        guard savedAt != nil else { return .none }
        if isDirty { return .unsavedChanges }
        switch flash {
        case .saved: return .saved
        case .autosaved: return .autosaved
        case .updated: return .updated
        case nil: return .none
        }
    }

    static func lastSavedText(for date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        lastSavedDisplay(for: date, now: now, calendar: calendar, locale: locale).accessibilityText
    }

    static func lastSavedDisplay(for date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> LastSavedDisplay {
        guard let date else {
            return LastSavedDisplay(label: String(localized: "Not saved yet"), detail: nil)
        }

        // Locale-aware system styles, never a hand-built pattern: a pattern string
        // localizes the words but not the order, joiner, or clock convention.
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        style = calendar.isDate(date, inSameDayAs: now)
            ? style.hour().minute()
            : style.year().month(.abbreviated).day().hour().minute()
        return LastSavedDisplay(label: String(localized: "Last save"), detail: date.formatted(style))
    }
}

enum EditorStatusFlash: Equatable {
    case saved
    case autosaved
    case updated
}

enum EditorStatusColors {
    // Red — "Not saved yet" (untitled). Deep red on light, salmon on dark
    // (dark value brightened to clear AA against the lightest dark theme, "Quiet").
    static func notSaved(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 1.00, green: 0.60, blue: 0.60, alpha: 1)
            : NSColor(srgbRed: 0.70, green: 0.10, blue: 0.10, alpha: 1)
    }

    // Amber — "Unsaved changes" (dirty established). Softer than red.
    static func unsavedChanges(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 1.00, green: 0.72, blue: 0.28, alpha: 1)
            : NSColor(srgbRed: 0.60, green: 0.34, blue: 0.02, alpha: 1)
    }

    // Green — save confirmation / "Updated". Matches the prior updated-flash green:
    // a dark forest green on light backgrounds and a brighter mint on dark, so it
    // clears WCAG AA against the status bar in both appearances.
    static func saved(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 0.40, green: 0.82, blue: 0.55, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.47, blue: 0.24, alpha: 1)
    }

    static func notSavedColor(dark: Bool) -> Color { Color(nsColor: notSaved(dark: dark)) }
    static func unsavedChangesColor(dark: Bool) -> Color { Color(nsColor: unsavedChanges(dark: dark)) }
    static func savedColor(dark: Bool) -> Color { Color(nsColor: saved(dark: dark)) }
}

enum EditorStatusIndicator: Equatable {
    case none
    case unsavedChanges
    case saved
    case autosaved
    case updated

    var text: String? {
        switch self {
        case .none: return nil
        case .unsavedChanges: return EditorStatusFormatter.unsavedChangesText
        case .saved: return EditorStatusFormatter.savedIndicatorText
        case .autosaved: return EditorStatusFormatter.autosavedIndicatorText
        case .updated: return EditorStatusFormatter.updatedIndicatorText
        }
    }

    var showsReloadIcon: Bool { self == .updated }

    var accessibilityLabel: String? {
        switch self {
        case .none: return nil
        case .unsavedChanges: return String(localized: "Unsaved changes")
        case .saved: return String(localized: "Saved")
        case .autosaved: return String(localized: "Autosaved")
        case .updated: return String(localized: "Document updated from disk")
        }
    }
}

struct EditorStatusBar: View {
    static let showsTopSeparator = false
    static let lastSavedDetailUsesPrimaryForeground = false
    static let horizontalInset: CGFloat = 28

    static func isVisible(in mode: EditorDisplayMode) -> Bool {
        mode != .read
    }

    var lastSavedDisplay: EditorStatusFormatter.LastSavedDisplay
    var statisticsText: String
    var statusAccessibilityLabel: String
    var indicator: EditorStatusIndicator = .none

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    private func indicatorColor(_ indicator: EditorStatusIndicator) -> Color {
        switch indicator {
        case .unsavedChanges: return EditorStatusColors.unsavedChangesColor(dark: isDark)
        case .saved, .autosaved, .updated: return EditorStatusColors.savedColor(dark: isDark)
        case .none: return .secondary
        }
    }

    var body: some View {
        let segments = EditorStatusFormatter.metadataSegments(
            lastSavedDisplay: lastSavedDisplay,
            statisticsText: statisticsText
        )
        return HStack(spacing: 16) {
            Spacer(minLength: 16)

            if let text = indicator.text {
                HStack(spacing: 4) {
                    if indicator.showsReloadIcon {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(text)
                }
                .font(.caption)
                .foregroundStyle(indicatorColor(indicator))
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(indicator.accessibilityLabel ?? text)
            }

            metadataText(segments)
                .font(.caption)
                .lineLimit(1)
                .accessibilityLabel(Text(verbatim: "\(lastSavedDisplay.accessibilityText), \(statusAccessibilityLabel)"))
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.vertical, 6)
    }

    // The metadata line is always grey, except an untitled document's "Not saved yet"
    // label, which is the one colored (red) part — the counts/time stay `.secondary`.
    @ViewBuilder
    private func metadataText(_ segments: EditorStatusFormatter.MetadataSegments) -> some View {
        if let label = segments.unsavedLabel {
            Text(attributedMetadata(label: label, neutral: segments.neutralText))
        } else {
            Text(segments.neutralText).foregroundStyle(.secondary)
        }
    }

    private func attributedMetadata(label: String, neutral: String) -> AttributedString {
        var labelPart = AttributedString(label)
        labelPart.foregroundColor = EditorStatusColors.notSavedColor(dark: isDark)
        var neutralPart = AttributedString(neutral)
        neutralPart.foregroundColor = .secondary
        return labelPart + neutralPart
    }
}
