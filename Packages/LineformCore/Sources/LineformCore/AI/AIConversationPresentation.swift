import Foundation

/// The AI drawer's words (Mac drawer and iPhone sheet), from the package catalog so both apps
/// draw the same text. The drawer has no title (2026-11-24): its input says "Ask Lineform…".
public enum AIConversationPresentation {
    /// The Mac's wording is unchanged; on iPhone there is no closing a document, only opening
    /// another one (the conversation goes with the swap).
    public static var startNote: String {
        #if os(iOS)
        String(localized: "This conversation ends when you open another document.", bundle: .module)
        #else
        String(localized: "This conversation lasts until you close the document.", bundle: .module)
        #endif
    }
    public static var placeholder: String { String(localized: "Ask Lineform…", bundle: .module) }
    public static var inputLabel: String { String(localized: "Instruction for the AI", bundle: .module) }
    public static var quickActionsLabel: String { String(localized: "Quick actions", bundle: .module) }
    public static var conversationLabel: String { String(localized: "AI conversation", bundle: .module) }
    /// The toolbar button's help and VoiceOver label (it draws only an icon).
    public static var toolbarTitle: String { String(localized: "Ask AI", bundle: .module) }
    public static var acceptTitle: String { String(localized: "Accept", bundle: .module) }
    public static var rejectTitle: String { String(localized: "Reject", bundle: .module) }
    public static var tryAgainTitle: String { String(localized: "Try Again", bundle: .module) }
    public static var applyTitle: String { String(localized: "Apply", bundle: .module) }
    public static var cancelTitle: String { String(localized: "Cancel", bundle: .module) }
    public static var closeTitle: String { String(localized: "Close", bundle: .module) }
    public static var sendTitle: String { String(localized: "Send", bundle: .module) }
    public static var stopTitle: String { String(localized: "Stop", bundle: .module) }
    public static var somethingElsePlaceholder: String { String(localized: "Something else…", bundle: .module) }
    public static var addTitle: String { String(localized: "Add", bundle: .module) }
    public static var previousVersionTitle: String { String(localized: "Previous Version", bundle: .module) }
    public static var nextVersionTitle: String { String(localized: "Next Version", bundle: .module) }
    public static var blankHint: String { String(localized: "Shows choices", bundle: .module) }
    public static var workingLabel: String { String(localized: "Working…", bundle: .module) }

    /// "v2": the version on screen.
    public static func versionLabel(_ number: Int) -> String {
        String(localized: "v\(number)", bundle: .module)
    }
}
