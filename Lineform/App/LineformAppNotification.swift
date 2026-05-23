import Foundation

enum LineformAppNotification {
    case showReadingExperience

    var name: Notification.Name {
        switch self {
        case .showReadingExperience:
            return Notification.Name("Lineform.showReadingExperience")
        }
    }

    func post(center: NotificationCenter = .default) {
        center.post(name: name, object: nil)
    }
}
