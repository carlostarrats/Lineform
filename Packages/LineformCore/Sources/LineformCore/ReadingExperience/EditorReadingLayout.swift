import CoreGraphics

/// The editor's reading column: how wide the text runs and how far it is inset for a container
/// width. Moved from the Mac app's `EditorPresentation.swift` so the iPhone editor lays text out
/// with the same arithmetic.
public enum EditorReadingLayout {
    public static func textColumnMaxWidth(for profile: ReadingProfile) -> CGFloat {
        // "Full width" means the column is unbounded, so `horizontalInset` clamps to `marginWidth`
        // and the text fills to the margins regardless of window size.
        ReadingProfile.isFullWidthColumn(profile.columnWidth)
            ? .greatestFiniteMagnitude
            : CGFloat(profile.columnWidth)
    }

    public static func horizontalInset(forContainerWidth containerWidth: CGFloat, profile: ReadingProfile) -> CGFloat {
        max(CGFloat(profile.marginWidth), (containerWidth - textColumnMaxWidth(for: profile)) / 2)
    }

    public static func textContainerWidth(forContainerWidth containerWidth: CGFloat, profile: ReadingProfile) -> CGFloat {
        max(0, containerWidth - (horizontalInset(forContainerWidth: containerWidth, profile: profile) * 2))
    }

    /// The width a block diagram/equation should fit into for a given container (window) width:
    /// the reading column, but never wider than the visible text area — so a wide diagram shrinks
    /// to stay contained when the window is narrower than the column (the resize refit nit).
    public static func blockAttachmentFitWidth(forContainerWidth containerWidth: CGFloat, profile: ReadingProfile) -> CGFloat {
        min(textColumnMaxWidth(for: profile), textContainerWidth(forContainerWidth: containerWidth, profile: profile))
    }
}
