import AppIntents
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

// The home-screen widget's data, shared by the app and the widget extension (compiled into both
// targets; `LINEFORM_WIDGET` is set in the extension). The app writes the newest documents to a
// small JSON file in the App Group container; the widget only reads it. Titles and locations
// only — never document contents. Nothing leaves the device.

/// One line of the Recent documents widget.
struct WidgetRecentDocument: Codable, Hashable, Sendable {
    var title: String
    var path: String
    /// "iCloud" or "On My iPhone", already localized by the app.
    var location: String
    var modified: Date?
}

enum WidgetRecents {
    static let appGroup = "group.com.lineform.app"
    static let fileName = "RecentDocuments.json"
    /// The large widget shows this many; the smaller sizes show fewer.
    static let limit = 8
    static let widgetKind = "LineformRecentDocuments"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    static func load(from url: URL? = fileURL) -> [WidgetRecentDocument] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([WidgetRecentDocument].self, from: data)) ?? []
    }

    /// Writes the list when it changed, then asks the widget to redraw.
    @discardableResult
    static func save(_ documents: [WidgetRecentDocument], to url: URL? = fileURL) -> Bool {
        guard let url else { return false }
        let list = Array(documents.prefix(limit))
        guard list != load(from: url), let data = try? JSONEncoder().encode(list) else { return false }
        do { try data.write(to: url, options: .atomic) } catch { return false }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        #endif
        return true
    }

    // MARK: Links into the app

    static let scheme = "lineform"
    static let newNoteURL = URL(string: "lineform://new")!

    /// The link a widget line opens: `lineform://open?path=…`.
    static func openURL(for document: WidgetRecentDocument) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: document.path)]
        return components.url ?? newNoteURL
    }

    enum Link: Equatable {
        case newNote
        case open(URL)
    }

    /// What a `lineform://` link asks for; nil for any other URL.
    static func link(from url: URL) -> Link? {
        guard url.scheme == scheme else { return nil }
        switch url.host() {
        case "new": return .newNote
        case "open":
            guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value, path.hasPrefix("/")
            else { return nil }
            return .open(URL(fileURLWithPath: path))
        default: return nil
        }
    }

    // MARK: Building the list (app side)

    /// The newest Markdown and text documents under `roots` (each with its location label),
    /// newest first. Hidden files are skipped; an iCloud file not downloaded yet (`.name.md.icloud`)
    /// counts under its real name.
    static func newestDocuments(in roots: [(url: URL, location: String)], limit: Int = limit) -> [WidgetRecentDocument] {
        var found: [WidgetRecentDocument] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root.url, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                var name = url.lastPathComponent
                var fileURL = url
                if name.hasPrefix("."), name.hasSuffix(".icloud") {
                    name = String(name.dropFirst().dropLast(".icloud".count))
                    fileURL = url.deletingLastPathComponent().appendingPathComponent(name)
                } else if name.hasPrefix(".") {
                    enumerator.skipDescendants()
                    continue
                }
                let ext = (name as NSString).pathExtension.lowercased()
                guard ["md", "markdown", "txt"].contains(ext) else { continue }
                let path = fileURL.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                found.append(WidgetRecentDocument(
                    title: (name as NSString).deletingPathExtension,
                    path: path,
                    location: root.location,
                    modified: modified
                ))
            }
        }
        found.sort { lhs, rhs in
            switch (lhs.modified, rhs.modified) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
        return Array(found.prefix(limit))
    }
}

/// Control Center's "New Lineform Note": opens Lineform on a new note. It runs in the app
/// (`openAppWhenRun`); the widget extension only needs to know it exists.
struct NewLineformNoteControlIntent: AppIntent {
    static let title: LocalizedStringResource = "New Lineform Note"
    static let description = IntentDescription("Opens a new note in Lineform.")
    static let openAppWhenRun = true
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !LINEFORM_WIDGET
        try await PhoneIntentRouter.shared.handle(.newNote(""))
        #endif
        return .result()
    }
}
