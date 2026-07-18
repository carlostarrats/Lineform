import Foundation

/// One openable file in the quick-open (⌘K "Jump to File") palette.
struct QuickOpenEntry: Identifiable, Equatable {
    /// Full URL path — same identity rule as `OutlineFileTreeItem.id`.
    let id: String
    let url: URL
    /// File name, e.g. "roadmap.md". The fuzzy matcher runs against this only.
    let name: String
    /// Path within its root, e.g. "projects/roadmap.md" — shown to disambiguate
    /// same-named files in different folders or roots.
    let relativePath: String
    /// The owning root's display title ("Lineform" for iCloud, the workspace folder's name).
    let rootTitle: String

    /// The containing folder within the root, for display beside the filename —
    /// "projects" for "projects/roadmap.md", "/" for a file at the root itself.
    var directoryDisplayPath: String {
        guard relativePath.count > name.count else { return "/" }
        return String(relativePath.dropLast(name.count + 1))
    }
}

/// Pure flatten + fuzzy-rank logic behind the ⌘K palette. Operates on the trees the
/// Files sidebar's `OutlineFileBrowserStore` has already scanned — no I/O, no scanning,
/// fully unit-testable (the `EditorSearchResolver` pattern).
enum QuickOpenIndex {
    /// Flattens both roots' already-scanned trees into a flat list of files
    /// (directories recursed into, never listed themselves).
    static func flatten(iCloudRoot: OutlineFileRoot, workspaceRoot: OutlineFileRoot) -> [QuickOpenEntry] {
        var entries: [QuickOpenEntry] = []
        func walk(_ items: [OutlineFileTreeItem], pathPrefix: String, rootTitle: String) {
            for item in items {
                let path = pathPrefix.isEmpty ? item.name : "\(pathPrefix)/\(item.name)"
                if item.isDirectory {
                    walk(item.children, pathPrefix: path, rootTitle: rootTitle)
                } else {
                    entries.append(QuickOpenEntry(
                        id: item.url.path,
                        url: item.url,
                        name: item.name,
                        relativePath: path,
                        rootTitle: rootTitle
                    ))
                }
            }
        }
        walk(iCloudRoot.items, pathPrefix: "", rootTitle: iCloudRoot.title)
        walk(workspaceRoot.items, pathPrefix: "", rootTitle: workspaceRoot.title)
        return entries
    }

    /// Fuzzy-filters and ranks `entries` against `query` (matched against `name` only).
    /// Empty/whitespace query → []. Case-insensitive. Subsequence match with bonuses for
    /// exact substring, match at start of name, and contiguous runs; ties break toward
    /// shorter names, then lexicographic relative path (stable, deterministic).
    static func search(_ entries: [QuickOpenEntry], query: String, limit: Int = 20) -> [QuickOpenEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return entries
            .compactMap { entry in score(name: entry.name, query: trimmed).map { (entry: entry, score: $0) } }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.entry.name.count != rhs.entry.name.count { return lhs.entry.name.count < rhs.entry.name.count }
                return lhs.entry.relativePath < rhs.entry.relativePath
            }
            .prefix(limit)
            .map(\.entry)
    }

    /// Nil when `query` is not an in-order subsequence of `name` (case-insensitive).
    /// Higher is better. Not exposed; ranking behavior is asserted via `search`.
    private static func score(name: String, query: String) -> Int? {
        let name = name.lowercased()
        let query = query.lowercased()

        // Exact substring: a large fixed bonus, better the earlier it starts.
        if let range = name.range(of: query) {
            var substringScore = 1000 - name.distance(from: name.startIndex, to: range.lowerBound) * 2 - name.count
            if range.lowerBound == name.startIndex {
                substringScore += 200
            }
            return substringScore
        }

        // Subsequence walk: every query character must appear, in order. Contiguous
        // pairs earn a run bonus; skipped characters cost a little each.
        var subsequenceScore = 0
        var searchStart = name.startIndex
        var previousMatch: String.Index?
        for character in query {
            guard let found = name[searchStart...].firstIndex(of: character) else { return nil }
            if let previous = previousMatch, name.index(after: previous) == found {
                subsequenceScore += 15
            }
            if found == name.startIndex {
                subsequenceScore += 50
            }
            subsequenceScore -= name.distance(from: searchStart, to: found)
            previousMatch = found
            searchStart = name.index(after: found)
        }
        return subsequenceScore - name.count
    }
}
