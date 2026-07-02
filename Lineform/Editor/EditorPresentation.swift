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
    static let iconFillDiameter: CGFloat = 20
    static let fillOpacityWhenOn = 1.0
    static let usesWhiteIconWhenOn = true
    static let lightChromeIconWhiteComponent: CGFloat = 0.18
    static let darkChromeIconWhiteComponent: CGFloat = 0.92
    static let iconOpacityWhenOn = 1.0
    static let iconOpacityWhenOff = 0.72

    static func offIconColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome ? darkChromeIconWhiteComponent : lightChromeIconWhiteComponent,
            alpha: 1
        ))
    }
}

enum EditorToolbarPressedState {
    static let usesFilledActiveIcon = true
    static let usesWhiteActiveIcon = true
    static let replacesActiveSymbolWithCloseAction = true
    static let closeSystemImage = "xmark"
    static let closeSymbolScale = 0.67
    static let openSymbolTransition = EditorToolbarSymbolTransitionStyle.replaceOffUp
    static let closeSymbolTransition = EditorToolbarSymbolTransitionStyle.instant

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

    static func displaySystemImage(for action: EditorToolbarAction, isActive: Bool) -> String {
        isActive ? closeSystemImage : action.systemImage
    }

    static func displaySymbolScale(for action: EditorToolbarAction, isActive: Bool) -> CGFloat {
        isActive ? closeSymbolScale : 1
    }

    static func symbolTransitionStyle(isActive: Bool) -> EditorToolbarSymbolTransitionStyle {
        isActive ? openSymbolTransition : closeSymbolTransition
    }
}

enum EditorToolbarSymbolTransitionStyle: Equatable {
    case replaceOffUp
    case instant
}

struct EditorToolbarIcon: View {
    let systemImage: String
    let isOn: Bool
    let usesDarkChrome: Bool
    var symbolScale: CGFloat = 1
    var symbolTransitionStyle: EditorToolbarSymbolTransitionStyle = .instant

    var body: some View {
        ZStack {
            if isOn {
                Circle()
                    .fill(Color.accentColor.opacity(EditorToolbarTogglePresentation.fillOpacityWhenOn))
                    .frame(
                        width: EditorToolbarTogglePresentation.iconFillDiameter,
                        height: EditorToolbarTogglePresentation.iconFillDiameter
                    )
            }

            Image(systemName: systemImage)
                .contentTransition(contentTransition)
                .animation(symbolAnimation, value: systemImage)
                .scaleEffect(symbolScale)
                .foregroundStyle(
                    isOn
                        ? Color.white.opacity(EditorToolbarTogglePresentation.iconOpacityWhenOn)
                        : EditorToolbarTogglePresentation.offIconColor(usesDarkChrome: usesDarkChrome)
                            .opacity(EditorToolbarTogglePresentation.iconOpacityWhenOff)
                )
        }
    }

    private var contentTransition: ContentTransition {
        switch symbolTransitionStyle {
        case .replaceOffUp:
            return .symbolEffect(.replace.offUp)
        case .instant:
            return .identity
        }
    }

    private var symbolAnimation: Animation? {
        switch symbolTransitionStyle {
        case .replaceOffUp:
            return .easeOut(duration: 0.16)
        case .instant:
            return nil
        }
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
