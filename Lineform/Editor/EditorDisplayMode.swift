enum EditorDisplayMode: String, CaseIterable, Equatable, Identifiable {
    case write
    case preview
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .write:
            return "Write"
        case .preview:
            return "Preview"
        case .split:
            return "Split"
        }
    }
}
