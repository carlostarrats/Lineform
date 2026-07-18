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
    case exportPDF
    case newTab
    case closeTab
    case selectNextTab
    case selectPreviousTab

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
        case .exportPDF:
            return Notification.Name("Lineform.exportPDF")
        case .newTab:
            return Notification.Name("Lineform.newTab")
        case .closeTab:
            return Notification.Name("Lineform.closeTab")
        case .selectNextTab:
            return Notification.Name("Lineform.selectNextTab")
        case .selectPreviousTab:
            return Notification.Name("Lineform.selectPreviousTab")
        }
    }

    func post(object: Any? = nil, center: NotificationCenter = .default) {
        center.post(name: name, object: object)
    }

    struct Payload: Equatable {
        var windowNumber: Int?
        var value: String?
        var selectedRange: NSRange? = nil

        func matches(windowNumber: Int?) -> Bool {
            self.windowNumber == windowNumber
        }
    }

    @MainActor
    static func activeWindowPayload(value: String? = nil) -> Payload {
        let selectedRange = (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectedRange()
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
