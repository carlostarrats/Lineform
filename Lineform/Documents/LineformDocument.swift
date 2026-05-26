import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown")
}

struct LineformDocument: FileDocument, Equatable {
    static var readableContentTypes: [UTType] {
        [.markdownText, .plainText]
    }

    static var writableContentTypes: [UTType] {
        [.markdownText, .plainText]
    }

    let id: UUID
    var text: String

    init(text: String = "", id: UUID = UUID()) {
        self.id = id
        self.text = text
    }

    init(markdownData: Data, id: UUID = UUID()) throws {
        guard let decodedText = String(data: markdownData, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        self.id = id
        text = decodedText
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        let documentID = UUID()
        try self.init(markdownData: data, id: documentID)

        if let modificationDate = Self.modificationDate(from: configuration.file) {
            Task { @MainActor in
                DocumentSaveStatus.shared.markSaved(documentID: documentID, at: modificationDate)
            }
        }
    }

    func markdownData() -> Data {
        Data(text.utf8)
    }

    static func modificationDate(from fileWrapper: FileWrapper) -> Date? {
        fileWrapper.fileAttributes[FileAttributeKey.modificationDate.rawValue] as? Date
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let documentID = id
        Task { @MainActor in
            DocumentSaveStatus.shared.markSaved(documentID: documentID)
        }

        return FileWrapper(regularFileWithContents: markdownData())
    }

    static func == (lhs: LineformDocument, rhs: LineformDocument) -> Bool {
        lhs.text == rhs.text
    }
}

@MainActor
final class DocumentSaveStatus: ObservableObject {
    static let shared = DocumentSaveStatus()

    @Published private var savedAtByDocumentID: [UUID: Date] = [:]

    private init() {}

    func savedAt(for documentID: UUID) -> Date? {
        savedAtByDocumentID[documentID]
    }

    func markSaved(documentID: UUID, at date: Date = Date()) {
        savedAtByDocumentID[documentID] = date
    }
}
