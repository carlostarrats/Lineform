import Foundation

public enum EditorDisplayMode: String, CaseIterable, Equatable, Identifiable {
    case write
    case read
    case split

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .write:
            return String(localized: "Write", bundle: .module)
        case .read:
            return String(localized: "Read", bundle: .module)
        case .split:
            return String(localized: "Preview", bundle: .module)
        }
    }
}

extension EditorDisplayMode {
    /// ⌘E toggle target: `.write` flips to `.read`; every other mode (`.read`, `.split`)
    /// flips to `.write`. So ⌘E always lands in Write unless already in Write.
    public var toggledWriteRead: EditorDisplayMode {
        self == .write ? .read : .write
    }
}
