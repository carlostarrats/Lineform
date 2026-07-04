import SwiftUI

enum EditorReadingLayout {
    static func textColumnMaxWidth(for profile: ReadingProfile) -> CGFloat {
        CGFloat(profile.columnWidth)
    }

    static func horizontalInset(forContainerWidth containerWidth: CGFloat, profile: ReadingProfile) -> CGFloat {
        max(CGFloat(profile.marginWidth), (containerWidth - textColumnMaxWidth(for: profile)) / 2)
    }

    static func textContainerWidth(forContainerWidth containerWidth: CGFloat, profile: ReadingProfile) -> CGFloat {
        max(0, containerWidth - (horizontalInset(forContainerWidth: containerWidth, profile: profile) * 2))
    }
}

enum EditorLayout {
    static let minimumContentWidth: CGFloat = 300
    static let minimumContentHeight: CGFloat = 480
}

enum EditorInspectorTextResponse {
    static let smoothsHorizontalInsetChanges = false
    static let usesPresentationLayerHorizontalSmoothing = false
    static let preservesVerticalAnchorDuringPresentationSmoothing = false
    static let usesExplicitPresentationOffsetAnimation = false
    static let allowsImplicitContentAnimationDuringPresentationSmoothing = false
    static let transitionDuration: TimeInterval = 0.18
    static let horizontalInsetAnimationDuration: TimeInterval = transitionDuration
    static let presentationOffsetAnimationDuration = transitionDuration
    static let presentationOffsetDistance: CGFloat = 0
    static let verticalBoundsOriginLockDuration: TimeInterval = 0.45

    static func presentationOffset(opening: Bool, reduceMotion: Bool) -> CGFloat {
        guard usesPresentationLayerHorizontalSmoothing, !reduceMotion else {
            return 0
        }

        return opening ? presentationOffsetDistance : -presentationOffsetDistance
    }
}

enum EditorToolbarVisibility {
    static func showsMarkdownBasics(in mode: EditorDisplayMode) -> Bool {
        mode != .read
    }
}

enum EditorToolbarTogglePresentation {
    static let usesNativeToolbarButtonShell = true
    static let outerButtonWidth: CGFloat? = nil
    static let lightChromeIconWhiteComponent: CGFloat = 0.18
    static let darkChromeIconWhiteComponent: CGFloat = 0.92
    static let iconOpacity: CGFloat = 0.72

    static func offIconColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome ? darkChromeIconWhiteComponent : lightChromeIconWhiteComponent,
            alpha: 1
        ))
    }
}

// The info and reading buttons no longer morph into a filled close (✕) when their
// panel is open: the reading inspector now carries its own close in its header, and
// the info modal already had one, so the toolbar buttons stay their own quiet glyph
// whether open or closed. `isActive` survives only to expose the open state to
// accessibility (a `.isSelected` trait on the button).
enum EditorToolbarPressedState {
    static func isActive(
        _ action: EditorToolbarAction,
        isShowingMarkdownBasics: Bool,
        isShowingReadingInspector: Bool
    ) -> Bool {
        switch action {
        case .markdownBasics:
            return isShowingMarkdownBasics
        case .readingExperience:
            return isShowingReadingInspector
        }
    }

    static func activeActions(
        isShowingMarkdownBasics: Bool,
        isShowingReadingInspector: Bool
    ) -> [EditorToolbarAction] {
        EditorToolbarAction.allCases.filter {
            isActive(
                $0,
                isShowingMarkdownBasics: isShowingMarkdownBasics,
                isShowingReadingInspector: isShowingReadingInspector
            )
        }
    }
}

struct EditorToolbarIcon: View {
    let systemImage: String
    let usesDarkChrome: Bool

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(
                EditorToolbarTogglePresentation.offIconColor(usesDarkChrome: usesDarkChrome)
                    .opacity(EditorToolbarTogglePresentation.iconOpacity)
            )
    }
}

enum EditorToolbarAction: CaseIterable, Equatable, Identifiable {
    case markdownBasics
    case readingExperience

    var id: Self { self }

    var title: String {
        switch self {
        case .markdownBasics:
            return "Markdown Basics"
        case .readingExperience:
            return "Reading Experience"
        }
    }

    var systemImage: String {
        switch self {
        case .markdownBasics:
            return "info.circle"
        case .readingExperience:
            return "textformat.size"
        }
    }

    static func primaryActions(in mode: EditorDisplayMode) -> [EditorToolbarAction] {
        if EditorToolbarVisibility.showsMarkdownBasics(in: mode) {
            return [.markdownBasics, .readingExperience]
        }

        return [.readingExperience]
    }
}

enum EditorMotionPolicy {
    static let supportsReduceMotion = true

    static func effectiveDuration(_ duration: TimeInterval, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : duration
    }

    static func usesAnimatedTransitions(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static func fadeAndMoveTransition(y: CGFloat, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .offset(y: y).combined(with: .opacity)
    }

    static func scaleAndFadeTransition(scale: CGFloat, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: scale).combined(with: .opacity)
    }
}
