import CoreGraphics
import Foundation

/// Lineform's design values in one place (spec §7), so the Mac app and the iPhone app read one
/// source. They are the desktop values as shipped: changing one is a visual change on the Mac.
/// Colours live with the themes (`LineformColors`, `Theme`), not here.
public enum LineformDesign {
    /// Corner radii in use. The mode control is a capsule and has no radius here.
    public enum Radius {
        /// Settings and ⌘K modals.
        public static let modal: CGFloat = 20
        /// Preset cards and the sidebar's root cards.
        public static let card: CGFloat = 14
        /// Floating cards (announcement, default app, AI) and the selection toolbar.
        public static let floatingCard: CGFloat = 12
        /// Basics rows.
        public static let row: CGFloat = 8
        /// Buttons.
        public static let button: CGFloat = 7
    }

    /// Animation durations, in seconds. Under Reduce Motion the app turns them off
    /// (`EditorMotionPolicy`); these are the values when motion is on.
    public enum Motion {
        /// Hover highlights.
        public static let hover: Double = 0.12
        /// Cards and mode changes (easeOut).
        public static let standard: Double = 0.24
    }

    /// The chrome every floating bottom card shares (`FloatingCardChrome` in the app).
    public enum FloatingCard {
        public static let radius: CGFloat = Radius.floatingCard
        /// The hairline border's width (SwiftUI's `strokeBorder` default).
        public static let hairlineWidth: CGFloat = 1
        /// Hairline: white at this opacity on dark chrome.
        public static let hairlineOpacityDark: Double = 0.12
        /// Hairline: black at this opacity on light chrome.
        public static let hairlineOpacityLight: Double = 0.08
        public static let shadowRadius: CGFloat = 18
        /// Shadow: black at this opacity on dark chrome.
        public static let shadowOpacityDark: Double = 0.45
        /// Shadow: black at this opacity on light chrome.
        public static let shadowOpacityLight: Double = 0.16
        public static let shadowOffset = CGSize(width: 0, height: 6)
    }
}
