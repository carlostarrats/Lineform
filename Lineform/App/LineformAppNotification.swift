import AppKit
import Foundation

enum LineformAppNotification {
    case showReadingExperience
    case focusSearch
    case runIntelligentEditingAction
    case setDisplayMode
    case toggleOutline

    var name: Notification.Name {
        switch self {
        case .showReadingExperience:
            return Notification.Name("Lineform.showReadingExperience")
        case .focusSearch:
            return Notification.Name("Lineform.focusSearch")
        case .runIntelligentEditingAction:
            return Notification.Name("Lineform.runIntelligentEditingAction")
        case .setDisplayMode:
            return Notification.Name("Lineform.setDisplayMode")
        case .toggleOutline:
            return Notification.Name("Lineform.toggleOutline")
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
}
