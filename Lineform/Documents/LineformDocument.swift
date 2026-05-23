import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let lineformMarkdown = UTType(exportedAs: "com.lineform.markdown")
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown")
}

struct LineformDocument: FileDocument, Equatable {
    static var readableContentTypes: [UTType] {
        [.lineformMarkdown, .markdownText, .plainText]
    }

    static var writableContentTypes: [UTType] {
        [.lineformMarkdown, .markdownText, .plainText]
    }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(markdownData: Data) throws {
        text = String(decoding: markdownData, as: UTF8.self)
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
