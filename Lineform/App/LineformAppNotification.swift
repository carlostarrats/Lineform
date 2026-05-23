import Foundation

enum LineformAppNotification {
    case showReadingExperience
    case runIntelligentEditingAction

    var name: Notification.Name {
        switch self {
        case .showReadingExperience:
            return Notification.Name("Lineform.showReadingExperience")
        case .runIntelligentEditingAction:
            return Notification.Name("Lineform.runIntelligentEditingAction")
        }
    }

    func post(object: Any? = nil, center: NotificationCenter = .default) {
        center.post(name: name, object: object)
    }
}
