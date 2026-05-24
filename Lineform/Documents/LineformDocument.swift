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

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(markdownData: Data) throws {
        guard let decodedText = String(data: markdownData, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        text = decodedText
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        try self.init(markdownData: data)
    }

    func markdownData() -> Data {
        Data(text.utf8)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: markdownData())
    }
}
