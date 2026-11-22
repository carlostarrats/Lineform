import LineformCore
import SwiftUI
import UIKit

/// The page for every mode: the editor and the Read view placed for Write, Read or Preview.
///
/// - **Write**: the editor fills the page; there is no Read view, so typing renders nothing.
/// - **Read**: the Read view fills the page, over the editor, which stays in the hierarchy (so
///   Write keeps its undo history across a switch) but is out of reach of touch and VoiceOver.
/// - **Preview**: the editor on top and the Read view below, each half of the height above the
///   keyboard (the page is not extended under it), with a hairline between them in the theme ink
///   at alpha 0.15 through `readableInk`, as Read's table grid draws its lines.
struct PreviewSplit<Editor: View, Reader: View>: View {
    /// The divider's ink: the theme ink at this alpha, through `readableInk` at `dividerMinimumRatio`.
    static var dividerAlpha: CGFloat { LineformReadView.tableGridAlpha }
    static var dividerMinimumRatio: CGFloat { LineformReadView.tableGridMinimumRatio }

    var mode: EditorDisplayMode
    var profile: ReadingProfile
    @ViewBuilder var editor: Editor
    @ViewBuilder var reader: Reader

    @Environment(\.displayScale) private var displayScale

    /// The editor pane's height on a page of `height`: all of it, or half in Preview.
    static func editorHeight(forPageHeight height: CGFloat, mode: EditorDisplayMode) -> CGFloat {
        mode == .split ? (height / 2).rounded() : height
    }

    static func dividerColor(for theme: Theme) -> UIColor {
        theme.readableInk(theme.textColor.withAlphaComponent(dividerAlpha), minimumRatio: dividerMinimumRatio)
    }

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let editorHeight = Self.editorHeight(forPageHeight: height, mode: mode)
            ZStack(alignment: .top) {
                editor
                    .frame(height: editorHeight)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(mode != .read)
                    .accessibilityHidden(mode == .read)
                if mode != .write {
                    reader
                        .overlay(alignment: .top) {
                            if mode == .split {
                                Rectangle()
                                    .fill(Color(uiColor: Self.dividerColor(for: Theme.theme(for: profile))))
                                    .frame(height: 1 / max(1, displayScale))
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(height: mode == .split ? height - editorHeight : height)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }
}

/// Preview's link button, the Mac's `splitScrollLinkButton` in the iPhone's floating chrome: a
/// 38 pt circle with the `link` symbol, system blue on a blue wash while linked, struck through in
/// the page ink while unlinked. It sits at the bottom right of the Read pane, left of the Menu
/// button, and shares the Menu button's `LineformDesign` floating chrome (fill, hairline, shadow).
/// A phone has no hover: the Mac's hover values are the pressed state.
struct PreviewLinkButton: View {
    static let diameter: CGFloat = 38
    static let symbolSize: CGFloat = 15
    static let strikeSize = CGSize(width: 1.7, height: 20)

    var isLinked: Bool
    var profile: ReadingProfile
    var action: () -> Void

    /// "Unlink split scrolling" while linked, "Link split scrolling" while not: the Mac's strings.
    static func accessibilityTitle(isLinked: Bool) -> String {
        isLinked ? String(localized: "Unlink split scrolling") : String(localized: "Link split scrolling")
    }

    var body: some View {
        Button(action: action) {
            EmptyView()
        }
        .buttonStyle(LinkButtonStyle(isLinked: isLinked, profile: profile))
        .accessibilityLabel(Self.accessibilityTitle(isLinked: isLinked))
    }
}

private struct LinkButtonStyle: ButtonStyle {
    var isLinked: Bool
    var profile: ReadingProfile

    func makeBody(configuration: Configuration) -> some View {
        let theme = Theme.theme(for: profile)
        let isDark = theme.usesDarkChrome
        let pressed = configuration.isPressed
        let blue = Color(uiColor: .systemBlue)
        let ink = isLinked || pressed ? blue : Color(uiColor: theme.textColor).opacity(0.62)
        ZStack {
            Image(systemName: "link")
            if !isLinked {
                Capsule()
                    .fill(ink)
                    .frame(width: PreviewLinkButton.strikeSize.width, height: PreviewLinkButton.strikeSize.height)
                    .rotationEffect(.degrees(-45))
            }
        }
        .font(.system(size: PreviewLinkButton.symbolSize, weight: .semibold))
        .foregroundStyle(ink)
        .frame(width: PreviewLinkButton.diameter, height: PreviewLinkButton.diameter)
        .background {
            ZStack {
                Circle().fill(Color(uiColor: theme.backgroundColor))
                if isLinked {
                    Circle().fill(blue.opacity(isDark ? (pressed ? 0.28 : 0.20) : (pressed ? 0.17 : 0.11)))
                } else if pressed {
                    Circle().fill(blue.opacity(isDark ? 0.16 : 0.08))
                }
            }
        }
        .overlay {
            if isLinked || pressed {
                Circle().strokeBorder(blue.opacity(isLinked ? (pressed ? 0.95 : 0.72) : 0.55), lineWidth: 1.25)
            } else {
                Circle().strokeBorder(
                    isDark
                        ? Color.white.opacity(LineformDesign.FloatingCard.hairlineOpacityDark)
                        : Color.black.opacity(LineformDesign.FloatingCard.hairlineOpacityLight),
                    lineWidth: LineformDesign.FloatingCard.hairlineWidth
                )
            }
        }
        .shadow(
            color: .black.opacity(isDark ? LineformDesign.FloatingCard.shadowOpacityDark : LineformDesign.FloatingCard.shadowOpacityLight),
            radius: LineformDesign.FloatingCard.shadowRadius,
            x: LineformDesign.FloatingCard.shadowOffset.width,
            y: LineformDesign.FloatingCard.shadowOffset.height
        )
        .contentShape(Circle())
    }
}
