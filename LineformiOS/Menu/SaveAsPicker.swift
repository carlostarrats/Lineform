import Foundation

/// Where Save As stages its copy: `tmp/SaveAs/<UUID>/<file name>`. The menu no longer offers Save
/// As (the approved Export & Print has no such row); `OpenDocument.prepareSaveAs` still stages
/// here, and the screen clears the folder at launch so no old copy lingers.
enum SaveAsStaging {
    static var defaultFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SaveAs", isDirectory: true)
    }

    static func removeAll(in folder: URL = defaultFolder) {
        try? FileManager.default.removeItem(at: folder)
    }
}
