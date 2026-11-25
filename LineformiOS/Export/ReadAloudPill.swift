import LineformCore
import SwiftUI

/// Read aloud's pill on the page: on the ⋯ button's line, from the left margin up to it. "Reading
/// aloud" (or "Paused"), then pause/play and ✕ (which ends reading and closes the pill), each on a
/// round background (the page colour; a lighter circle on a dark page, `PhoneInk.readAloudButton`).
/// All glyphs are SF Symbols at one weight. Shown while `ExportCommands.readAloudPill` is not
/// hidden: after the end it stays, "Finished reading" with a read-again button, until its ✕ or a
/// document swap. Nothing about it times out.
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
    static var finishedText: String { String(localized: "Finished reading") }
    static var readAgainTitle: String { String(localized: "Read again") }

    static func statusText(for state: ReadAloudPillState) -> String {
        switch state {
        case .paused: pausedText
        case .finished: finishedText
        case .reading, .hidden: readingText
        }
    }

    /// The middle button's glyph and spoken name.
    static func playButton(for state: ReadAloudPillState) -> (systemImage: String, label: String) {
        switch state {
        case .paused: ("play", resumeTitle)
        case .finished: ("arrow.counterclockwise", readAgainTitle)
        case .reading, .hidden: ("pause", pauseTitle)
        }
    }

    var body: some View {
        let theme = Theme.theme(for: profile)
        let ink = PhoneInk(theme: theme, colorScheme: theme.usesDarkChrome ? .dark : .light)
        let state = commands.readAloudPill
        let play = Self.playButton(for: state)
        HStack(spacing: 4) {
            Text(Self.statusText(for: state))
                .font(.subheadline)
                .foregroundStyle(Color(uiColor: ink.theme.textColor))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.updatesFrequently)
            roundButton(systemImage: play.systemImage, label: play.label, ink: ink) {
                commands.pauseOrResumeReading()
            }
            .accessibilityIdentifier("readAloud.pause")
            roundButton(systemImage: "xmark", label: Self.endTitle, ink: ink) {
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

    /// A 36 pt circle (`PhoneInk.readAloudButton`) inside a 44 pt target.
    private func roundButton(systemImage: String, label: String, ink: PhoneInk, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ink.color(.onReadAloudButton))
                .frame(width: Self.buttonDiameter, height: Self.buttonDiameter)
                .background(Circle().fill(Color(uiColor: ink.readAloudButton)))
                .frame(width: WordMenuMetrics.minimumTarget, height: WordMenuMetrics.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The buttons never give up their room: a narrow pill (beside the ← and ⋯, or at large
        // text sizes) shrinks the words, never pause/play or ✕.
        .fixedSize()
        .layoutPriority(1)
        .accessibilityLabel(label)
    }
}
