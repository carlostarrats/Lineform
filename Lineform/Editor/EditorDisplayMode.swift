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
            return "Split"
        }
    }
}
