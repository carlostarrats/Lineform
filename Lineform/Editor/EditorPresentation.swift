import SwiftUI

enum EditorReadingLayout {
    static func textColumnMaxWidth(for profile: ReadingProfile) -> CGFloat {
        // "Full width" means the column is unbounded, so `horizontalInset` clamps to `marginWidth`
        // and the text fills to the margins regardless of window size.
        ReadingProfile.isFullWidthColumn(profile.columnWidth)
            ? .greatestFiniteMagnitude
            : CGFloat(profile.columnWidth)
    }

    static func horizontalInset(forContainerWidth containerWidth: CGFloat, profile: ReadingProfile) -> CGFloat {
        max(CGFloat(profile.marginWidth), (containerWidth - textColumnMaxWidth(for: profile)) / 2)
    }

    static func textContainerWidth(forContainerWidth containerWidth: CGFloat, profile: ReadingProfile) -> CGFloat {
        max(0, containerWidth - (horizontalInset(forContainerWidth: containerWidth, profile: profile) * 2))
    }

    /// The width a block diagram/equation should fit into for a given container (window) width:
    /// the reading column, but never wider than the visible text area — so a wide diagram shrinks
    /// to stay contained when the window is narrower than the column (the resize refit nit).
    static func blockAttachmentFitWidth(forContainerWidth containerWidth: CGFloat, profile: ReadingProfile) -> CGFloat {
        min(textColumnMaxWidth(for: profile), textContainerWidth(forContainerWidth: containerWidth, profile: profile))
    }
}

enum EditorLayout {
    // 220 (was 300, reduced 2026-07-17): opening the sidebar on a small window forced the whole
    // window wider; a thinner floor lets the nav open without pushing the window out. The text
    // column still gets ~140pt after the 40pt minimum margins — thin, but readable and the
    // user's own choice of window size.
    static let minimumContentWidth: CGFloat = 220
    static let minimumContentHeight: CGFloat = 480
}

/// Narrow-window toolbar adaptation (2026-07-17). The native toolbar collapses overflowing items
/// into the "»" popover, which renders custom SwiftUI views CLIPPED — the three-mode segmented
/// control showed only "Write" and the Reading Experience button a bare tiny "Aa". Below this
/// window width the principal control swaps to a compact labeled menu that always fits, so the
/// unreadable overflow popover never appears for our controls.
enum EditorToolbarCompactPresentation {
    /// Measured with the real toolbar (2026-07-17, AX inspection): the Aa button falls into the
    /// "»" overflow at a 780pt window and the segmented mode control at 760pt — the window title,
    /// sidebar toggle, and search field eat far more room than the controls themselves. Swap at
    /// 840 so the compact menu is in place comfortably before anything overflows.
    static let compactModeControlThreshold: CGFloat = 840

    static func usesCompactModeControl(windowWidth: CGFloat) -> Bool {
        windowWidth < compactModeControlThreshold
    }
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

enum EditorToolbarTogglePresentation {
    static let usesNativeToolbarButtonShell = true
    static let outerButtonWidth: CGFloat? = nil
    // Both tones match the sidebar's primary symbol so the Aa glyph reads as the SAME ink as
    // the side-nav symbols in every theme: light chrome uses OutlineSidebarView.primaryText
    // (0.16, near-black), dark chrome uses darkPrimaryText (0.90, white).
    static let lightChromeIconWhiteComponent: CGFloat = 0.16
    static let darkChromeIconWhiteComponent: CGFloat = 0.90
    // Rendered at FULL strength in every theme. The old 0.72 dimming made the glyph composite
    // to a lighter grey than the sidebar symbols — dark grey on the dark toolbar, medium grey
    // on the light page — so it never matched the opaque side-nav symbols (QA 2026-07-06).
    static let lightChromeIconOpacity: CGFloat = 1.0
    static let darkChromeIconOpacity: CGFloat = 1.0

    static func offIconColor(usesDarkChrome: Bool) -> Color {
        Color(nsColor: NSColor(
            calibratedWhite: usesDarkChrome ? darkChromeIconWhiteComponent : lightChromeIconWhiteComponent,
            alpha: 1
        ))
    }

    static func iconOpacity(usesDarkChrome: Bool) -> CGFloat {
        usesDarkChrome ? darkChromeIconOpacity : lightChromeIconOpacity
    }
}

// The reading button no longer morphs into a filled close (✕) when its panel is
// open: the reading inspector now carries its own close in its header, so the
// toolbar button stays its own quiet glyph whether open or closed. `isActive`
// survives only to expose the open state to accessibility (a `.isSelected` trait
// on the button).
enum EditorToolbarPressedState {
    static func isActive(
        _ action: EditorToolbarAction,
        isShowingReadingInspector: Bool
    ) -> Bool {
        switch action {
        case .readingExperience:
            return isShowingReadingInspector
        }
    }

    static func activeActions(
        isShowingReadingInspector: Bool
    ) -> [EditorToolbarAction] {
        EditorToolbarAction.allCases.filter {
            isActive($0, isShowingReadingInspector: isShowingReadingInspector)
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
                    .opacity(EditorToolbarTogglePresentation.iconOpacity(usesDarkChrome: usesDarkChrome))
            )
    }
}

enum EditorToolbarAction: CaseIterable, Equatable, Identifiable {
    case readingExperience

    var id: Self { self }

    var title: String {
        switch self {
        case .readingExperience:
            return "Reading Experience"
        }
    }

    var systemImage: String {
        switch self {
        case .readingExperience:
            return "textformat.alt"
        }
    }

    static func primaryActions(in mode: EditorDisplayMode) -> [EditorToolbarAction] {
        // The Markdown reference moved to the Files-sidebar "Info" tab, so the only
        // primary toolbar toggle left is the Reading Experience inspector — shown in
        // every mode.
        [.readingExperience]
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
