import Foundation

struct DocumentTab: Identifiable, Equatable {
    let id: UUID
    var document: LineformDocument
    var fileURL: URL?
    var displayMode: EditorDisplayMode

    init(document: LineformDocument, fileURL: URL? = nil, displayMode: EditorDisplayMode = .write) {
        id = document.id
        self.document = document
        self.fileURL = fileURL
        self.displayMode = displayMode
    }

    var title: String {
        guard let fileURL else { return "Untitled" }
        return fileURL.lastPathComponent
    }

    static func == (lhs: DocumentTab, rhs: DocumentTab) -> Bool {
        lhs.id == rhs.id
            && lhs.document == rhs.document
            && lhs.fileURL == rhs.fileURL
            && lhs.displayMode == rhs.displayMode
    }
}
