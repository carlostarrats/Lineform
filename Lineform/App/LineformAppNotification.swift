import AppKit
import Foundation

enum LineformAppNotification {
    case showSettings
    case showReadingExperience
    case focusSearch
    case showFindReplace
    case showQuickOpen
    case setDisplayMode
    case toggleOutline
    case toggleHiddenFolders
    case convertTextFormat
    case refreshSidebarFiles
    case sidebarItemRenamed
    case sidebarFileDeleted
    case renameCurrentFile
    case deleteCurrentFile
    case printDocument
    case saveAsDocument
    case exportDocument
    case newTab
    case closeTab
    case selectNextTab
    case selectPreviousTab
    case startSpeaking
    case pauseResumeSpeech
    case stopSpeech

    var name: Notification.Name {
        switch self {
        case .showSettings:
            return Notification.Name("Lineform.showSettings")
        case .showReadingExperience:
            return Notification.Name("Lineform.showReadingExperience")
        case .focusSearch:
            return Notification.Name("Lineform.focusSearch")
        case .showFindReplace:
            return Notification.Name("Lineform.showFindReplace")
        case .showQuickOpen:
            return Notification.Name("Lineform.showQuickOpen")
        case .setDisplayMode:
            return Notification.Name("Lineform.setDisplayMode")
        case .toggleOutline:
            return Notification.Name("Lineform.toggleOutline")
        case .toggleHiddenFolders:
            return Notification.Name("Lineform.toggleHiddenFolders")
        case .convertTextFormat:
            return Notification.Name("Lineform.convertTextFormat")
        case .refreshSidebarFiles:
            return Notification.Name("Lineform.refreshSidebarFiles")
        case .sidebarItemRenamed:
            return Notification.Name("Lineform.sidebarItemRenamed")
        case .sidebarFileDeleted:
            return Notification.Name("Lineform.sidebarFileDeleted")
        case .renameCurrentFile:
            return Notification.Name("Lineform.renameCurrentFile")
        case .deleteCurrentFile:
            return Notification.Name("Lineform.deleteCurrentFile")
        case .printDocument:
            return Notification.Name("Lineform.printDocument")
        case .saveAsDocument:
            return Notification.Name("Lineform.saveAsDocument")
        case .exportDocument:
            return Notification.Name("Lineform.exportDocument")
        case .newTab:
            return Notification.Name("Lineform.newTab")
        case .closeTab:
            return Notification.Name("Lineform.closeTab")
        case .selectNextTab:
            return Notification.Name("Lineform.selectNextTab")
        case .selectPreviousTab:
            return Notification.Name("Lineform.selectPreviousTab")
        case .startSpeaking:
            return Notification.Name("Lineform.startSpeaking")
        case .pauseResumeSpeech:
            return Notification.Name("Lineform.pauseResumeSpeech")
        case .stopSpeech:
            return Notification.Name("Lineform.stopSpeech")
        }
    }

    func post(object: Any? = nil, center: NotificationCenter = .default) {
        center.post(name: name, object: object)
    }

    struct Payload: Equatable {
        var windowNumber: Int?
        var value: String?
        var selectedRange: NSRange? = nil

        /// An UNKNOWN window on either side matches NOTHING. A plain `==` made `nil == nil`
        /// true, so a command posted while no window was key (`NSApp.keyWindow` nil) was
        /// delivered to EVERY window still resolving its own number — `windowNumber` is
        /// published a runloop after a window appears, so a freshly opened window sits in
        /// exactly that state. The commands routed through this include Close Tab, Save As,
        /// and Delete, which must never fan out. `showSettings` already refused to use this
        /// path for the same reason; the rule now holds for every caller.
        func matches(windowNumber: Int?) -> Bool {
            guard let mine = self.windowNumber, let candidate = windowNumber else {
                return false
            }
            return mine == candidate
        }
    }

    @MainActor
    static func activeWindowPayload(value: String? = nil) -> Payload {
        // `LineformTextView`, NOT the general `NSTextView`. Both consumers of this range — read
        // aloud and Convert to Plain Text — substring `document.text` with it, so it must come from
        // the document editor and nothing else. `as? NSTextView` also matched an NSSearchField's
        // FIELD EDITOR (⌘F selects the field's whole contents, so Start Speaking then read only the
        // first `query.count` characters of the document) and the Split-mode preview pane, whose
        // ranges are in RENDERED coordinates — the thing `speechSource` explicitly guards against
        // for `.read` mode but could not catch for `.split`.
        let selectedRange = (NSApp.keyWindow?.firstResponder as? LineformTextView)?.selectedRange()
        return Payload(windowNumber: NSApp.keyWindow?.windowNumber, value: value, selectedRange: selectedRange)
    }

    /// Object of `sidebarItemRenamed`. Not window-scoped: every window checks whether its
    /// own document lives at (or under) the renamed path and retargets itself.
    struct RenamePayload {
        var from: URL
        var to: URL
        var isDirectory: Bool

        /// The new location of `url` after this rename: the destination itself for an
        /// exact match, a re-prefixed path for descendants of a renamed folder, nil if
        /// the rename does not affect `url`.
        func rebased(_ url: URL?) -> URL? {
            guard let url else { return nil }
            let target = url.standardizedFileURL.path
            let source = from.standardizedFileURL.path
            if target == source {
                return to
            }
            guard isDirectory, target.hasPrefix(source + "/") else {
                return nil
            }
            return URL(fileURLWithPath: to.standardizedFileURL.path + String(target.dropFirst(source.count)))
        }
    }
}
