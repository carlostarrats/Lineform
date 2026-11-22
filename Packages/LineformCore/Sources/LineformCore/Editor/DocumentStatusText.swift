import Foundation

/// The save-state words and the word/character count line both apps show for a document. The
/// Mac's `EditorStatusFormatter` keeps its old names as forwarders; its tab-, date- and
/// colour-specific parts stay in the app.
public enum DocumentStatusText {
    public static var saved: String { String(localized: "Saved", bundle: .module) }
    public static var autosaved: String { String(localized: "Autosaved", bundle: .module) }
    public static var unsavedChanges: String { String(localized: "Unsaved changes", bundle: .module) }

    /// "Saved" or "Autosaved" for a document whose text is on disk, "Unsaved changes" otherwise.
    public static func saveState(isSaved: Bool, isAutosaved: Bool) -> String {
        guard isSaved else { return unsavedChanges }
        return isAutosaved ? autosaved : saved
    }

    /// "%lld words — %lld characters", or characters only for predominantly CJK text, whose
    /// run-based word count would be a sentence count.
    public static func counts(_ statistics: DocumentStatistics) -> String {
        if statistics.isPredominantlyCJK {
            return String(localized: "\(statistics.characterCount) characters", bundle: .module)
        }
        return String(localized: "\(statistics.wordCount) words — \(statistics.characterCount) characters", bundle: .module)
    }

    public static func countsAccessibilityText(_ statistics: DocumentStatistics) -> String {
        if statistics.isPredominantlyCJK {
            return String(localized: "Document contains \(statistics.characterCount) characters", bundle: .module)
        }
        return String(localized: "Document contains \(statistics.wordCount) words and \(statistics.characterCount) characters", bundle: .module)
    }
}
