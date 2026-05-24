import AppKit
import Foundation

enum LineformAppNotification {
    case showReadingExperience
    case runIntelligentEditingAction
    case setDisplayMode
    case toggleOutline

    var name: Notification.Name {
        switch self {
        case .showReadingExperience:
            return Notification.Name("Lineform.showReadingExperience")
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

        func matches(windowNumber: Int?) -> Bool {
            self.windowNumber == windowNumber
        }
    }

    @MainActor
    static func activeWindowPayload(value: String? = nil) -> Payload {
        Payload(windowNumber: NSApp.keyWindow?.windowNumber, value: value)
    }
}
