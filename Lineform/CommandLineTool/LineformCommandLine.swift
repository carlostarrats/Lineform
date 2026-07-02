import Foundation

/// A parsed `lineform` command. Pure so it is unit-tested in the app module and reused by the
/// bundled helper (compiled together with this file by packaging/build-release.sh).
enum LineformCLICommand: Equatable {
    case open([String])
    case readStdin
    case version
    case help
    case invalid(String)

    static func parse(_ args: [String]) -> LineformCLICommand {
        guard let first = args.first else { return .help }
        switch first {
        case "--version": return .version
        case "--help", "-h": return .help
        case "-": return .readStdin
        default:
            if first.hasPrefix("--") { return .invalid(first) }
            return .open(args)
        }
    }
}

/// Guards for piped stdin: reject empty, oversized, or binary (NUL-containing) input.
enum LineformPipeValidation: Equatable {
    case ok, empty, tooLarge, notText

    /// Single source of truth for the pipe size limit (the read bound in the helper and
    /// the user-facing message are both derived from it).
    static let maxPipedBytes = 10_000_000

    static func validate(_ data: Data, maxBytes: Int = LineformPipeValidation.maxPipedBytes) -> LineformPipeValidation {
        if data.isEmpty { return .empty }
        if data.count > maxBytes { return .tooLarge }
        if data.contains(0x00) { return .notText }
        return .ok
    }
}

/// Path + filename helpers for the CLI and the piped-file store.
enum LineformCLIPaths {
    /// Location of piped files under `~/Library/Application Support/`.
    static let pipedRelativePath = "Lineform/Piped"

    /// The real (non-sandboxed) piped-file directory under a given home directory.
    static func pipedDirectory(home: URL) -> URL {
        home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(pipedRelativePath, isDirectory: true)
    }

    /// Filename for a piped document. `unique` disambiguates pipes that land in the same
    /// millisecond so concurrent `lineform -` invocations don't clobber each other.
    static func pipedFileName(timestamp: String, unique: String) -> String {
        "piped-\(timestamp)-\(unique).md"
    }

    /// Timestamp component of a piped filename (stable, testable format).
    static func pipedTimestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    static func resolve(_ path: String, relativeTo base: URL) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return base.appendingPathComponent(path)
    }
}

/// Pure 7-day housekeeping decision for the Piped folder: return files whose last activity
/// (the later of modification and access) is older than the cutoff. Age-only: the helper is a
/// separate short-lived process and cannot know the app's open documents, but a document that
/// is open and being edited keeps its modification date fresh via autosave.
enum LineformPipedHousekeeping {
    static func stale(
        entries: [(url: URL, lastActivity: Date)],
        now: Date,
        olderThan: TimeInterval
    ) -> [URL] {
        entries.compactMap { entry in
            guard now.timeIntervalSince(entry.lastActivity) > olderThan else { return nil }
            return entry.url
        }
    }
}

/// Exact user-facing CLI strings (asserted in tests so wording stays stable).
enum LineformCLIMessages {
    static func noSuchFile(_ path: String) -> String { "lineform: no such file: \(path)" }
    static func isDirectory(_ path: String) -> String { "lineform: \(path) is a directory (not supported yet)" }
    static let emptyInput = "lineform: empty input"
    static let notText = "lineform: input is not text"
    static let tooLarge = "lineform: input too large (limit \(LineformPipeValidation.maxPipedBytes / 1_000_000) MB)"
    static let usage = """
    lineform — open Markdown/text files in Lineform.

    Usage:
      lineform <file> [<file> …]   Open one or more files
      lineform -                   Open text piped on stdin
      lineform --version           Print the app version
      lineform --help              Show this help
    """
}
