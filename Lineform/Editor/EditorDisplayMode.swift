enum EditorDisplayMode: String, CaseIterable, Equatable, Identifiable {
    case write
    case read
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .write:
            return "Write"
        case .read:
            return "Read"
        case .split:
            return "Preview"
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
