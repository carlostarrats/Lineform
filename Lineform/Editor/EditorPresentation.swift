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

enum IntelligentEditingOverlayPlacement {
    struct Placement: Equatable {
        let position: CGPoint
        let width: CGFloat
        let bodyHeight: CGFloat?
    }

    static let canvasInset: CGFloat = 24
    static let expandedPanelChromeHeight: CGFloat = 140
    static let composerGap: CGFloat = 16
    static var bottomComposerClearance: CGFloat {
        IntelligenceActionRailPresentation.bottomInset
            + IntelligenceInstructionComposerPresentation.height
            + composerGap
    }

    static func placement(anchorRect _: CGRect?, containerSize: CGSize, replacementText: String) -> Placement {
        let mode = IntelligentEditingOptionsPresentation.presentation(for: replacementText)
        let maxWidth = mode == .expandedReview
            ? IntelligentEditingOptionsPresentation.expandedMaximumWidth
            : IntelligentEditingOptionsPresentation.compactMaximumWidth
        let availableWidth = max(0, containerSize.width - canvasInset * 2)
        let availableHeight = max(0, containerSize.height - canvasInset - bottomComposerClearance)
        let width = min(maxWidth, availableWidth)
        let bodyHeight = mode == .expandedReview
            ? max(0, availableHeight - Self.expandedPanelChromeHeight)
            : nil

        return Placement(
            position: CGPoint(
                x: containerSize.width / 2,
                y: canvasInset + availableHeight / 2
            ),
            width: width,
            bodyHeight: bodyHeight
        )
    }
}

enum EditorToolbarVisibility {
    static func showsMarkdownBasics(in mode: EditorDisplayMode) -> Bool {
        mode != .read
    }

    static func showsIntelligence(in mode: EditorDisplayMode) -> Bool {
        mode == .write
    }
}

enum IntelligenceActionRailPresentation {
    static let placement = IntelligenceActionRailPlacement.bottomCenter
    static let bottomInset: CGFloat = 30
    static let transitionStyle = EditorAuxiliaryTransitionStyle.fadeAndMoveUp
    static let animationDuration = 0.24
    static let entranceYOffset: CGFloat = 10
    static let usesHorizontalLayout = true
    static let showsActionLabels = true
    static let buttonWidth: CGFloat = 88
    static let buttonHeight: CGFloat = 52
    static let iconSize: CGFloat = 15
    static let labelSize: CGFloat = 10
    static let cornerRadius: CGFloat = 12
    static let railSpacing: CGFloat = 10
    static let backgroundRedComponent: CGFloat = 0.90
    static let backgroundGreenComponent: CGFloat = 0.95
    static let backgroundBlueComponent: CGFloat = 1.0
    static let hoverBackgroundRedComponent: CGFloat = 0.80
    static let hoverBackgroundGreenComponent: CGFloat = 0.90
    static let hoverBackgroundBlueComponent: CGFloat = 1.0
    static let backgroundAlpha: CGFloat = 1.0
    static let borderOpacity = 0.55
    static let hoverBorderOpacity = 0.95
    static let disabledContentOpacity = 0.45
    static let shadowOpacity = 0.035
    static let shadowRadius: CGFloat = 5
    static let shadowYOffset: CGFloat = 1
    static let supportsHoverState = true
    static let hoverFeedbackRequiresEnabledAction = false
    static let usesRestoringHoverCursor = true
    static let usesAppKitCursorRect = true
    static let usesAppKitHoverTracking = true
    static let reassertsHoverCursorOnEnter = true
    static let hoverCursor = IntelligenceActionRailHoverCursor.pointingHand
    static let restoresPreviousCursorOnExit = true
    static let restoresPreviousCursorOnDisappear = true
    static let usesAccentTint = true

    static func isVisible(isEnabled: Bool, hasSelection: Bool, displayMode: EditorDisplayMode) -> Bool {
        isEnabled && hasSelection && displayMode == .write
    }

    static func backgroundColor(isHovered: Bool) -> Color {
        Color(
            nsColor: NSColor(
                srgbRed: isHovered ? hoverBackgroundRedComponent : backgroundRedComponent,
                green: isHovered ? hoverBackgroundGreenComponent : backgroundGreenComponent,
                blue: isHovered ? hoverBackgroundBlueComponent : backgroundBlueComponent,
                alpha: backgroundAlpha
            )
        )
    }

    static func borderColor(isHovered: Bool) -> Color {
        Color.accentColor.opacity(isHovered ? hoverBorderOpacity : borderOpacity)
    }
}

enum IntelligenceInstructionComposerPresentation {
    static let prompt = "Tell AI what to do..."
    static let submitSystemImage = "arrow.up"
    static let inputAccessibilityLabel = "AI instruction"
    static let inputAccessibilityHelp = "Describe how Lineform should edit the selected text."
    static let submitAccessibilityLabel = "Run AI instruction"
    static let submitAccessibilityHelp = "Apply the typed AI instruction to the selected text."
    static let usesFixedShortcutButtons = false
    static let animatesSelectionVisibilityChanges = true
    static let usesStableNativePlaceholder = true
    static let darkensWhenFocused = false
    static let showsBorderWhenFocused = true
    static let showsFocusedBorderBeforeTyping = true
    static let sendButtonSupportsHoverState = true
    static let usesWhiteCapsuleBackground = false
    static let usesLightBlueCapsuleBackground = true
    static let usesNavPillLikeShadow = true
    static let usesInlineLoadingState = true
    static let usesExistingSkeletonShimmerForLoading = true
    static let pausesLoadingShimmerForReducedMotion = true
    static let usesNeutralLoadingChrome = true
    static let showsLoadingSpinnerInSubmitSlot = false
    static let loadingStatePreservesCapsuleDimensions = true
    static let loadingDrawsBorder = false
    static let loadingSkeletonMinimumRows = 4
    static let loadingSkeletonColumns = 48
    static let loadingSkeletonBlockHeight: CGFloat = 4
    static let loadingSkeletonSpacing: CGFloat = 2
    static let loadingSkeletonMinimumCellWidth: CGFloat = 6
    static let loadingSkeletonMinimumBlockWidth: CGFloat = 7
    static let loadingSkeletonTextSlotHeight: CGFloat = 24
    static let loadingSkeletonUsesQuickCadence = true
    static var loadingSkeletonGridHeight: CGFloat {
        CGFloat(loadingSkeletonMinimumRows) * loadingSkeletonBlockHeight
            + CGFloat(loadingSkeletonMinimumRows - 1) * loadingSkeletonSpacing
    }
    static var loadingSkeletonCapsuleInset: CGFloat {
        (height - loadingSkeletonGridHeight) / 2
    }
    static let maximumWidth: CGFloat = 560
    static let height: CGFloat = 52
    static let horizontalPadding: CGFloat = 14
    static let cornerRadius: CGFloat = 18
    static let backgroundOpacity = 1.0
    static let borderOpacity = 0.65
    static let disabledOpacity = 0.38
    static let sendButtonSize: CGFloat = 30
    static let sendButtonSymbolPointSize: CGFloat = 16
    static let sendButtonUsesFilledAccentBackground = true
    static let sendButtonUsesWhiteSymbol = true
    static let sendButtonHoverBackgroundOpacity = 0.28
    static let shadowOpacity = 0.08
    static let shadowRadius: CGFloat = 16
    static let shadowYOffset: CGFloat = 4
    static let lightLoadingBackgroundWhiteComponent: CGFloat = 0.68
    static let lightLoadingBackgroundAlpha: CGFloat = 0.82

    static func usesDarkAppearance(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func backgroundColor(usesDarkAppearance: Bool) -> NSColor {
        usesDarkAppearance
            ? NSColor(srgbRed: 0x23 / 255.0, green: 0x23 / 255.0, blue: 0x23 / 255.0, alpha: 1)
            : .actionRailBackground(isHovered: false)
    }

    static func loadingBackgroundColor(usesDarkAppearance: Bool) -> NSColor {
        usesDarkAppearance
            ? NSColor(srgbRed: 0x23 / 255.0, green: 0x23 / 255.0, blue: 0x23 / 255.0, alpha: 1)
            : NSColor(
                srgbRed: lightLoadingBackgroundWhiteComponent,
                green: lightLoadingBackgroundWhiteComponent,
                blue: lightLoadingBackgroundWhiteComponent,
                alpha: lightLoadingBackgroundAlpha
            )
    }

    static func borderColor(usesDarkAppearance: Bool, isFocused: Bool) -> NSColor {
        if usesDarkAppearance {
            return NSColor.white.withAlphaComponent(isFocused ? 0.95 : 0.78)
        }

        return NSColor.controlAccentColor.withAlphaComponent(
            isFocused ? IntelligenceActionRailPresentation.hoverBorderOpacity : 0
        )
    }

    static func drawsInputBorder(
        usesDarkAppearance _: Bool,
        isFocused _: Bool,
        hasExplicitInputInteraction _: Bool
    ) -> Bool {
        false
    }

    static func foregroundColor(usesDarkAppearance: Bool) -> NSColor {
        usesDarkAppearance ? .white : LineformColors.primaryText
    }

    static func insertionPointColor(usesDarkAppearance: Bool) -> NSColor {
        usesDarkAppearance ? .white : .controlAccentColor
    }

    static func iconColor(usesDarkAppearance: Bool) -> NSColor {
        usesDarkAppearance ? .white : .controlAccentColor
    }

    static func loadingSkeletonBaseColor(usesDarkAppearance: Bool, alpha: CGFloat) -> NSColor {
        usesDarkAppearance
            ? NSColor.labelColor.withAlphaComponent(0.08 + alpha * 0.17)
            : NSColor.white.withAlphaComponent(0.12 + alpha * 0.12)
    }

    static func loadingSkeletonGradientColors(usesDarkAppearance: Bool, alpha: CGFloat) -> [NSColor] {
        if usesDarkAppearance {
            return [
                NSColor.labelColor.withAlphaComponent(0.018 + alpha * 0.04),
                NSColor.labelColor.withAlphaComponent(0.07 + alpha * 0.24),
                NSColor.labelColor.withAlphaComponent(0.022 + alpha * 0.05),
            ]
        }

        return [
            NSColor.white.withAlphaComponent(0.08 + alpha * 0.10),
            NSColor.white.withAlphaComponent(0.22 + alpha * 0.74),
            NSColor.white.withAlphaComponent(0.10 + alpha * 0.12),
        ]
    }

    static func placeholderColor(usesDarkAppearance: Bool) -> NSColor {
        usesDarkAppearance
            ? NSColor.white.withAlphaComponent(0.62)
            : LineformColors.primaryText.withAlphaComponent(0.48)
    }

    static func sendButtonFillColor(
        usesDarkAppearance: Bool,
        isHovered: Bool,
        isEnabled: Bool
    ) -> NSColor {
        let baseColor: NSColor
        if usesDarkAppearance {
            baseColor = isHovered ? NSColor.white.withAlphaComponent(0.84) : .white
        } else {
            let accentColor = NSColor.controlAccentColor
            baseColor = isHovered
                ? accentColor.blended(withFraction: 0.14, of: .black) ?? accentColor
                : accentColor
        }

        return baseColor.withAlphaComponent(isEnabled ? baseColor.alphaComponent : disabledOpacity)
    }

    static func sendButtonSymbolColor(usesDarkAppearance: Bool, isEnabled: Bool) -> NSColor {
        let baseColor: NSColor = usesDarkAppearance ? .black : .white
        return baseColor.withAlphaComponent(isEnabled ? 1 : disabledOpacity)
    }
}

enum IntelligenceInstructionComposerState {
    static func activeSelection(current: SelectionContext, retained: SelectionContext?) -> SelectionContext? {
        if !current.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return current
        }

        guard
            let retained,
            !retained.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        return retained
    }

    static func hasVisibleSelection(
        current: SelectionContext,
        retained: SelectionContext?,
        isPreparingSuggestion: Bool
    ) -> Bool {
        isPreparingSuggestion || activeSelection(current: current, retained: retained) != nil
    }

    static func shouldClearRetainedSelection(
        current: SelectionContext,
        isFocused: Bool,
        instruction: String,
        isPreparingSuggestion: Bool = false
    ) -> Bool {
        guard !isPreparingSuggestion else {
            return false
        }

        return current.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isFocused
            && instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum IntelligentEditingSelectionDismissal {
    static func acceptedCaretSelection(for suggestion: IntelligentEditingSuggestion) -> NSRange {
        NSRange(
            location: suggestion.selectedRange.location + (suggestion.replacementText as NSString).length,
            length: 0
        )
    }

    static func rejectedCaretSelection(for suggestion: IntelligentEditingSuggestion) -> NSRange {
        NSRange(location: NSMaxRange(suggestion.selectedRange), length: 0)
    }
}

enum IntelligentEditingRequestLifecycle {
    static func isPreparingSuggestion(
        isRunning: Bool,
        pendingRequest: IntelligentEditingRequest?,
        activeRequestID: UUID?
    ) -> Bool {
        isRunning && pendingRequest != nil && activeRequestID != nil
    }

    static func canPublishResult(
        activeRequestID: UUID?,
        completingRequestID: UUID,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && activeRequestID == completingRequestID
    }
}

enum IntelligenceActionRailPlacement: Equatable {
    case bottomCenter
}

enum IntelligenceActionRailHoverCursor: Equatable {
    case pointingHand
}

enum IntelligenceToolbarTogglePresentation {
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
        isIntelligenceRailEnabled: Bool,
        isShowingMarkdownBasics: Bool,
        isShowingReadingInspector: Bool
    ) -> Bool {
        switch action {
        case .intelligence:
            return isIntelligenceRailEnabled
        case .markdownBasics:
            return isShowingMarkdownBasics
        case .readingExperience:
            return isShowingReadingInspector
        }
    }

    static func activeActions(
        isIntelligenceRailEnabled: Bool,
        isShowingMarkdownBasics: Bool,
        isShowingReadingInspector: Bool
    ) -> [EditorToolbarAction] {
        EditorToolbarAction.allCases.filter {
            isActive(
                $0,
                isIntelligenceRailEnabled: isIntelligenceRailEnabled,
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

struct IntelligenceToolbarIcon: View {
    let systemImage: String
    let isOn: Bool
    let usesDarkChrome: Bool
    var symbolScale: CGFloat = 1
    var symbolTransitionStyle: EditorToolbarSymbolTransitionStyle = .instant

    var body: some View {
        ZStack {
            if isOn {
                Circle()
                    .fill(Color.accentColor.opacity(IntelligenceToolbarTogglePresentation.fillOpacityWhenOn))
                    .frame(
                        width: IntelligenceToolbarTogglePresentation.iconFillDiameter,
                        height: IntelligenceToolbarTogglePresentation.iconFillDiameter
                    )
            }

            Image(systemName: systemImage)
                .contentTransition(contentTransition)
                .animation(symbolAnimation, value: systemImage)
                .scaleEffect(symbolScale)
                .foregroundStyle(
                    isOn
                        ? Color.white.opacity(IntelligenceToolbarTogglePresentation.iconOpacityWhenOn)
                        : IntelligenceToolbarTogglePresentation.offIconColor(usesDarkChrome: usesDarkChrome)
                            .opacity(IntelligenceToolbarTogglePresentation.iconOpacityWhenOff)
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
    case intelligence
    case markdownBasics
    case readingExperience

    var id: Self { self }

    var title: String {
        switch self {
        case .intelligence:
            return "Intelligence"
        case .markdownBasics:
            return "Markdown Basics"
        case .readingExperience:
            return "Reading Experience"
        }
    }

    var systemImage: String {
        switch self {
        case .intelligence:
            return "sparkles"
        case .markdownBasics:
            return "info.circle"
        case .readingExperience:
            return "textformat.size"
        }
    }

    static func primaryActions(in mode: EditorDisplayMode) -> [EditorToolbarAction] {
        if EditorToolbarVisibility.showsIntelligence(in: mode) {
            return [.intelligence, .markdownBasics, .readingExperience]
        }

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
