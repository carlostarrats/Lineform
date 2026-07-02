import AppKit
import CryptoKit

/// One deduped mermaid-failure record. Deliberately carries NO file names, paths, or identity —
/// only the diagram source snippet, the error, the app version, a count, and a last-seen date.
struct DiagramLogEntry: Codable, Equatable {
    let sourceHash: String
    var sourceSnippet: String
    var error: String
    var appVersion: String
    var count: Int
    var lastSeen: Date
}

/// Pure diagram-log operations (dedup + readable export), independent of the filesystem.
enum DiagramLog {
    static func sourceHash(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Upsert by source hash: bump count + last-seen if present, else append.
    static func merge(_ existing: [DiagramLogEntry], adding entry: DiagramLogEntry, now: Date) -> [DiagramLogEntry] {
        var result = existing
        if let index = result.firstIndex(where: { $0.sourceHash == entry.sourceHash }) {
            result[index].count += 1
            result[index].lastSeen = now
            result[index].error = entry.error
            result[index].appVersion = entry.appVersion
        } else {
            var appended = entry
            appended.lastSeen = now
            result.append(appended)
        }
        return result
    }

    /// A single human-readable file for the developer-user's own triage.
    static func readableReport(_ entries: [DiagramLogEntry], now: Date = Date()) -> String {
        guard !entries.isEmpty else { return "Lineform Diagram Log — no entries.\n" }
        let formatter = ISO8601DateFormatter()
        var lines = ["Lineform Diagram Log (\(entries.count) entr\(entries.count == 1 ? "y" : "ies"))", ""]
        for entry in entries.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            lines.append("• \(entry.error)  ×\(entry.count)  (last seen \(formatter.string(from: entry.lastSeen)), app \(entry.appVersion))")
            lines.append("  hash: \(entry.sourceHash)")
            lines.append("  source:")
            for sourceLine in entry.sourceSnippet.components(separatedBy: "\n") {
                lines.append("    \(sourceLine)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

/// Abstracts failure recording so the preview renderer is testable without touching disk.
protocol DiagramFailureLogging: AnyObject {
    func record(source: String, error: String, appVersion: String)
}

/// A no-op failure log (used by the back-compat renderer convenience and by tests).
final class NullDiagramFailureLog: DiagramFailureLogging {
    func record(source: String, error: String, appVersion: String) {}
}

/// Persists the deduped diagram log as JSON under Application Support. Failure-tolerant.
final class DiagramLogStore: DiagramFailureLogging {
    private let directory: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = LineformCLIPaths.diagramLogDirectory(home: fileManager.homeDirectoryForCurrentUser)
    }

    private var fileURL: URL { directory.appendingPathComponent("log.json") }

    func entries() -> [DiagramLogEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DiagramLogEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    func record(source: String, error: String, appVersion: String) {
        let now = Date()
        let snippet = String(source.prefix(2_000))
        let entry = DiagramLogEntry(
            sourceHash: DiagramLog.sourceHash(source),
            sourceSnippet: snippet,
            error: error,
            appVersion: appVersion,
            count: 1,
            lastSeen: now
        )
        let merged = DiagramLog.merge(entries(), adding: entry, now: now)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(merged) {
            try? data.write(to: fileURL)
        }
    }

    func exportReadable(to destination: URL) throws {
        try Data(DiagramLog.readableReport(entries()).utf8).write(to: destination)
    }

    func clear() {
        try? fileManager.removeItem(at: fileURL)
    }
}

/// Menu-driven Export / Clear actions for the diagram log (mirrors CommandLineToolInstaller).
enum DiagramLogMenuActions {
    @MainActor
    static func presentExport(store: DiagramLogStore = DiagramLogStore()) {
        let panel = NSSavePanel()
        panel.title = "Export Diagram Log"
        panel.message = "Save the local mermaid diagram log for triage."
        panel.nameFieldStringValue = "LineformDiagramLog.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try store.exportReadable(to: destination)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t export the diagram log"
            alert.informativeText = String(describing: error)
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @MainActor
    static func presentClear(store: DiagramLogStore = DiagramLogStore()) {
        let alert = NSAlert()
        alert.messageText = "Clear Diagram Log?"
        alert.informativeText = "This deletes the local mermaid diagram log. This cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.clear()
        }
    }
}
