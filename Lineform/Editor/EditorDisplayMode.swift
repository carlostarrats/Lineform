import Foundation

enum EditorDisplayMode: String, CaseIterable, Equatable, Identifiable {
    case write
    case read
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .write:
            return String(localized: "Write")
        case .read:
            return String(localized: "Read")
        case .split:
            return String(localized: "Preview")
        }
    }
}

extension EditorDisplayMode {
    /// ⌘E toggle target: `.write` flips to `.read`; every other mode (`.read`, `.split`)
    /// flips to `.write`. So ⌘E always lands in Write unless already in Write.
    var toggledWriteRead: EditorDisplayMode {
        self == .write ? .read : .write
    }
}
