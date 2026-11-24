import LineformCore
import SwiftUI

/// Read aloud's pill on the page: on the ⋯ button's line, from the left margin up to it. "Reading
/// aloud" (or "Paused"), then pause/play and ✕ (which ends reading and closes the pill), each on a
/// round page-colour background. All glyphs are SF Symbols at one weight. Shown while
/// `ExportCommands.speechState` is not idle; nothing about it times out.
struct ReadAloudPill: View {
    @Bindable var commands: ExportCommands
    var profile: ReadingProfile

    @Environment(\.colorScheme) private var colorScheme

    static let height: CGFloat = 48
    static let buttonDiameter: CGFloat = 36

    static var readingText: String { String(localized: "Reading aloud") }
    static var pausedText: String { String(localized: "Paused") }
    static var pauseTitle: String { String(localized: "Pause") }
    static var resumeTitle: String { String(localized: "Resume") }
    static var endTitle: String { String(localized: "End read aloud") }

    static func statusText(for state: SpeechState) -> String {
        state == .paused ? pausedText : readingText
    }

    var body: some View {
        let theme = Theme.theme(for: profile)
        let ink = PhoneInk(theme: theme, colorScheme: theme.usesDarkChrome ? .dark : .light)
        let isPaused = commands.speechState == .paused
        HStack(spacing: 4) {
            Text(Self.statusText(for: commands.speechState))
                .font(.subheadline)
                .foregroundStyle(Color(uiColor: ink.theme.textColor))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.updatesFrequently)
            roundButton(
                systemImage: isPaused ? "play" : "pause",
                label: isPaused ? Self.resumeTitle : Self.pauseTitle,
                theme: ink.theme
            ) {
                commands.pauseOrResumeReading()
            }
            .accessibilityIdentifier("readAloud.pause")
            roundButton(systemImage: "xmark", label: Self.endTitle, theme: ink.theme) {
                commands.stopReading()
            }
            .accessibilityIdentifier("readAloud.end")
        }
        .padding(.leading, 18)
        .padding(.trailing, 2)
        .frame(height: Self.height)
        .background(Capsule().fill(Color(uiColor: ink.searchFieldWash)))
        .background(Capsule().fill(Color(uiColor: ink.page)))
        .overlay(
            Capsule().strokeBorder(
                theme.usesDarkChrome
                    ? Color.white.opacity(LineformDesign.FloatingCard.hairlineOpacityDark)
                    : Color.black.opacity(LineformDesign.FloatingCard.hairlineOpacityLight),
                lineWidth: LineformDesign.FloatingCard.hairlineWidth
            )
        )
        .shadow(
            color: .black.opacity(
                theme.usesDarkChrome ? LineformDesign.FloatingCard.shadowOpacityDark : LineformDesign.FloatingCard.shadowOpacityLight
            ),
            radius: LineformDesign.FloatingCard.shadowRadius,
            x: LineformDesign.FloatingCard.shadowOffset.width,
            y: LineformDesign.FloatingCard.shadowOffset.height
        )
        .accessibilityElement(children: .contain)
    }

    /// A 36 pt page-colour circle inside a 44 pt target.
    private func roundButton(systemImage: String, label: String, theme: Theme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(uiColor: theme.textColor))
                .frame(width: Self.buttonDiameter, height: Self.buttonDiameter)
                .background(Circle().fill(Color(uiColor: theme.backgroundColor)))
                .frame(width: WordMenuMetrics.minimumTarget, height: WordMenuMetrics.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
