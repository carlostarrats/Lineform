import SwiftUI

/// The iPhone copy of the Mac's `EditorMotionPolicy` (`Lineform/Editor/EditorPresentation.swift`),
/// with the same API and behaviour: under Reduce Motion every animation is off and every
/// transition is a plain fade. It lives here, not in the package, because the package may not
/// import SwiftUI; the file name differs from the Mac's so no two sources share a name.
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
