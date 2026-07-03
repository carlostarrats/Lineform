import Foundation
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
    /// Cap on retained entries: intermediate keystroke states of a diagram being edited each
    /// hash differently, so without a cap the log grows without bound. Oldest-seen drop first.
    static let maxEntries = 200

    /// Location of the local diagram failure log under `~/Library/Application Support/`
    /// (the app's sandbox container).
    static let relativePath = "Lineform/DiagramLog"

    static func directory(home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: true)
    }

    static func sourceHash(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Upsert by source hash: bump count + last-seen if present, else append (dropping the
    /// oldest-seen entries beyond `maxEntries`).
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
        if result.count > maxEntries {
            result.sort { $0.lastSeen > $1.lastSeen }
            result.removeLast(result.count - maxEntries)
        }
        return result
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
    /// Hash+error pairs already written this session: repeated failures of the same source
    /// (every preview pass over an unchanged broken diagram) skip the read-merge-write cycle.
    private var recordedThisSession: Set<String> = []
    /// Cap on the in-memory dedup set so a long editing session can't grow it without bound.
    private let maxRecordedThisSession = 500

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = DiagramLog.directory(home: fileManager.homeDirectoryForCurrentUser)
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
        let hash = DiagramLog.sourceHash(source)
        let sessionKey = "\(hash)\n\(error)"
        guard !recordedThisSession.contains(sessionKey) else { return }
        // Bound the in-memory dedup set: editing a broken diagram produces a fresh hash per
        // keystroke, so without a cap this grows all session. Drop the whole set past the cap —
        // the on-disk log is the source of truth, so re-recording a few entries is harmless.
        if recordedThisSession.count >= maxRecordedThisSession { recordedThisSession.removeAll() }
        let entry = DiagramLogEntry(
            sourceHash: hash,
            sourceSnippet: String(source.prefix(2_000)),
            error: error,
            appVersion: appVersion,
            count: 1,
            lastSeen: now
        )
        let merged = DiagramLog.merge(entries(), adding: entry, now: now)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(merged) {
            // Atomic: a crash mid-write can't leave log.json truncated.
            try? data.write(to: fileURL, options: .atomic)
            recordedThisSession.insert(sessionKey)
        }
    }

    func clear() {
        try? fileManager.removeItem(at: fileURL)
        recordedThisSession.removeAll()
    }
}
