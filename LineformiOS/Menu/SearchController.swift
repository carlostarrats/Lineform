import Combine
import LineformCore
import SwiftUI
import UIKit

/// Which results the Search section shows. The raw value is identity, never localized.
enum SearchFilter: String, CaseIterable, Identifiable {
    case all
    case document
    case files

    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .document: String(localized: "In document")
        case .files: String(localized: "Files")
        }
    }
}

/// One Search result: a match in this document, a file whose name matches, or one match inside
/// another file. The right-side `indicator` says where it is: "In document", or the file's name.
struct SearchRow: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A match in this document, at this range of its text.
        case inDocument(NSRange)
        /// A file whose name matches the query.
        case fileName
        /// A match inside another file, at this range of that file's text as it was searched.
        case fileContent(NSRange)
    }

    var id: String
    var kind: Kind
    /// The file to open; nil for a match in this document.
    var url: URL?
    /// The matching line, elided around the match (nil for a file-name match).
    var snippet: CrossFileSearchSnippet?
    /// The containing folder within its root, for a file-name match ("/" at the root).
    var detail: String?
    var indicator: String

    static var inDocumentIndicator: String { String(localized: "In document") }
}

/// The Menu sheet's search: this document's matches, then file-name matches (`QuickOpenIndex`),
/// then file-content matches (`CrossFileSearchModel`) across the Files roots, plus Replace and
/// Replace All on this document. The Mac's rules (search.md) carry over:
///
/// - Matching is `EditorSearchResolver.matches`: literal, case- and diacritic-insensitive.
/// - Replace and Replace All act on this document only, through `EditorCommands`; Replace All is
///   one undo step. There is no cross-file replace.
/// - Replace re-resolves against the live text and only replaces a range that is still a match.
/// - `replacementInsertions` (the resolver's `priorInsertions`) is cleared whenever the search is
///   re-aimed (a query or filter change). A nil active index left by a replacement is a decision:
///   a refresh never auto-selects then.
/// - The all-files search reads off the main thread, skips evicted files and anything over 1 MB,
///   and the latest query wins (all inside `CrossFileSearchModel`).
/// - The status is announced to VoiceOver only when it changes.
///
/// Searching across files is a reason to scan, so the first query that needs file results makes
/// the Files store visible and scans it (never at launch).
@MainActor
@Observable
final class SearchController {
    typealias Opener = @MainActor (URL) async -> String?

    private(set) var query = ""
    private(set) var filter: SearchFilter = .all
    /// The replacement text.
    var replacement = ""
    /// This document's matches, against the text as of the last refresh.
    private(set) var matches: [NSRange] = []
    /// The match Replace acts on.
    private(set) var activeIndex: Int?
    /// Every span this replace run wrote, so Replace never rewrites its own output.
    private(set) var replacementInsertions: [NSRange] = []
    private(set) var rows: [SearchRow] = []
    private(set) var isSearchingFiles = false
    /// The last file search skipped iCloud documents that are not downloaded (their names were
    /// still matched, their text was not read).
    private(set) var skippedNotDownloadedFiles = false

    /// The scan this search started, if any (tests await it).
    @ObservationIgnored private(set) var pendingScan: Task<Void, Never>?
    /// The latest file search (tests await it).
    @ObservationIgnored private(set) var pendingFileSearch: Task<Void, Never>?

    @ObservationIgnored private let editor: any EditorCommands
    @ObservationIgnored private let files: FilesStore?
    @ObservationIgnored private let currentURL: () -> URL?
    @ObservationIgnored private let fileSearch: CrossFileSearchModel
    @ObservationIgnored private let open: Opener
    @ObservationIgnored private let announce: @MainActor (String) -> Void
    @ObservationIgnored private let editorWait: Duration
    @ObservationIgnored private var lastAnnounced: String?
    @ObservationIgnored private var hasStartedScan = false
    @ObservationIgnored private var inDocumentRows: [SearchRow] = []
    @ObservationIgnored private var nameRows: [SearchRow] = []
    @ObservationIgnored private var contentRows: [SearchRow] = []
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []

    /// - Parameters:
    ///   - files: the Files store whose roots are searched; nil searches this document only.
    ///   - currentURL: the open document's file, left out of the file results (its matches are the
    ///     In document ones).
    ///   - open: opens a file and returns its text, or nil when it did not open.
    ///   - editorWait: how long a file result waits for the editor to show the opened text.
    init(
        editor: any EditorCommands,
        files: FilesStore?,
        currentURL: @escaping () -> URL?,
        fileSearch: CrossFileSearchModel = CrossFileSearchModel(debounceInterval: SearchController.fileSearchDebounce),
        open: @escaping Opener,
        announce: @escaping @MainActor (String) -> Void = SearchController.announceToVoiceOver,
        editorWait: Duration = .seconds(2)
    ) {
        self.editor = editor
        self.files = files
        self.currentURL = currentURL
        self.fileSearch = fileSearch
        self.open = open
        self.announce = announce
        self.editorWait = editorWait
        fileSearch.$results
            .sink { [weak self] results in self?.fileResultsChanged(results) }
            .store(in: &subscriptions)
        fileSearch.$isSearching
            .sink { [weak self] searching in
                guard let self, isSearchingFiles != searching else { return }
                isSearchingFiles = searching
            }
            .store(in: &subscriptions)
        fileSearch.$skippedNotDownloaded
            .sink { [weak self] skipped in
                guard let self, skippedNotDownloadedFiles != skipped else { return }
                skippedNotDownloadedFiles = skipped
            }
            .store(in: &subscriptions)
    }

    /// How long the file-content search waits after a keystroke: 0.1 s on iPhone (the Mac's
    /// 0.3 s made results lag behind typing; the files are read off the main thread, the latest
    /// query winning).
    nonisolated static let fileSearchDebounce: TimeInterval = 0.1

    static func announceToVoiceOver(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// Opens through the screen's document; the opened text, once the document holds that file.
    static func opener(for document: OpenDocument) -> Opener {
        { [weak document] url in
            guard let document else { return nil }
            await document.openReportingFailure(url)
            let wanted = OpenDocument.realURL(for: url).resolvingSymlinksInPath()
            guard let opened = document.url, opened.resolvingSymlinksInPath() == wanted else { return nil }
            return document.text
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchesDocument: Bool { filter != .files }
    private var searchesFiles: Bool { filter != .document }

    // MARK: - Aiming

    func setQuery(_ newQuery: String) {
        guard newQuery != query else { return }
        query = newQuery
        reaim()
    }

    func setFilter(_ newFilter: SearchFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        reaim()
    }

    /// A new query or filter: the replace run is over, and the first match is selected again.
    private func reaim() {
        replacementInsertions = []
        activeIndex = nil
        refreshDocument(selectFirstWhenNeeded: true)
        updateFiles()
    }

    /// The document's text changed (a replacement landed, or a reload). Never auto-selects while a
    /// replacement is holding the index open.
    func textChanged() {
        refreshDocument(selectFirstWhenNeeded: activeIndex == nil && replacementInsertions.isEmpty)
    }

    /// The Files roots changed (a scan landed): search them again.
    func rootsChanged() {
        guard searchesFiles, !trimmedQuery.isEmpty else { return }
        searchFiles()
    }

    /// The section went away: stop scanning and searching. Only Search's own hold on the store
    /// ends; Files, if it is on screen, keeps the store visible.
    func stop() {
        fileSearch.reset()
        pendingScan?.cancel()
        if hasStartedScan {
            hasStartedScan = false
            files?.setVisible(false, for: .search)
        }
    }

    // MARK: - This document

    private func refreshDocument(selectFirstWhenNeeded: Bool) {
        let text = editor.currentText
        matches = searchesDocument ? EditorSearchResolver.matches(in: text, query: query) : []
        let refresh = EditorSearchResolver.refreshState(
            currentActiveIndex: activeIndex,
            matches: matches,
            selectFirstWhenNeeded: selectFirstWhenNeeded,
            navigatesToActiveMatch: false
        )
        if activeIndex != refresh.activeIndex { activeIndex = refresh.activeIndex }
        rebuildDocumentRows(in: text)
        announceStatus()
    }

    /// How many of this document's matches become rows: a card's few when every document is
    /// searched (a card shows only the first), up to `maximumDocumentRows` when the search is
    /// this document only (the match list).
    private var documentRowLimit: Int {
        filter == .document ? Self.maximumDocumentRows : CrossFileSearchResolver.maximumSnippetsPerFile
    }

    /// The most matches the open document's list shows. The count and the arrows still reach
    /// every match; past this, the current match has no row to outline.
    static let maximumDocumentRows = 500

    private func rebuildDocumentRows(in text: String) {
        let indicator = SearchRow.inDocumentIndicator
        inDocumentRows = matches.prefix(documentRowLimit).enumerated().map { index, range in
            SearchRow(
                id: "document-\(index)-\(range.location)",
                kind: .inDocument(range),
                snippet: CrossFileSearchResolver.snippet(in: text, around: range),
                indicator: indicator
            )
        }
        rebuildRows()
    }

    var canReplace: Bool {
        searchesDocument && !trimmedQuery.isEmpty && activeIndex.map { matches.indices.contains($0) } == true
    }

    var canReplaceAll: Bool {
        searchesDocument && !trimmedQuery.isEmpty && !matches.isEmpty
    }

    /// Replaces the active match and moves to the next one ("Replace & find next").
    func replace() {
        guard canReplace, let currentIndex = activeIndex else { return }
        let matchRange = matches[currentIndex]
        // Re-resolve against the LIVE text: a range that is no longer a match is never replaced.
        let liveText = editor.currentText
        let liveMatches = EditorSearchResolver.matches(in: liveText, query: query)
        guard liveMatches.contains(matchRange) else {
            matches = liveMatches
            activeIndex = liveMatches.isEmpty ? nil : min(currentIndex, liveMatches.count - 1)
            rebuildDocumentRows(in: liveText)
            announceStatus()
            return
        }
        guard editor.replace(range: matchRange, with: replacement) else { return }

        let newText = editor.currentText
        let newMatches = EditorSearchResolver.matches(in: newText, query: query)
        let replacementLength = (replacement as NSString).length
        let nextIndex = EditorSearchResolver.nextActiveIndexAfterReplacement(
            matches: newMatches,
            replacedLocation: matchRange.location,
            replacementLength: replacementLength,
            priorInsertions: replacementInsertions
        )
        replacementInsertions = EditorSearchResolver.insertionsAfterReplacement(
            priorInsertions: replacementInsertions,
            matchRange: matchRange,
            replacementLength: replacementLength
        )
        matches = newMatches
        activeIndex = nextIndex
        rebuildDocumentRows(in: newText)
        announceStatus()
    }

    /// Replaces every match in this document as one undo step.
    func replaceAll() {
        guard canReplaceAll else { return }
        let ranges = EditorSearchResolver.matches(in: editor.currentText, query: query)
        guard !ranges.isEmpty, editor.replaceAll(ranges: ranges, with: replacement) else { return }
        let newText = editor.currentText
        matches = EditorSearchResolver.matches(in: newText, query: query)
        activeIndex = matches.isEmpty ? nil : 0
        rebuildDocumentRows(in: newText)
        announceStatus()
    }

    // MARK: - Stepping (the open document's arrows)

    /// The next match becomes the current one (wrapping), in the list only: the page moves when a
    /// match is tapped.
    func selectNext() {
        guard searchesDocument,
              let next = EditorSearchResolver.nextIndex(after: activeIndex, matchCount: matches.count)
        else { return }
        activeIndex = next
        announceStatus()
    }

    /// The previous match becomes the current one (wrapping; the last when none is current).
    func selectPrevious() {
        guard searchesDocument, !matches.isEmpty else { return }
        let count = matches.count
        activeIndex = activeIndex.map { ($0 - 1 + count) % count } ?? count - 1
        announceStatus()
    }

    var canStep: Bool { searchesDocument && !matches.isEmpty }

    /// The open document's compact count in the field: "2/5", the match count alone while no
    /// match is current (after a replacement), "0" for none. Nil with no query.
    var positionText: String? {
        guard searchesDocument, !trimmedQuery.isEmpty else { return nil }
        guard !matches.isEmpty else { return 0.formatted() }
        guard let activeIndex, matches.indices.contains(activeIndex) else { return matches.count.formatted() }
        return String(localized: "\(activeIndex + 1)/\(matches.count)")
    }

    /// What VoiceOver reads for the count: "2 of 5", "5 matches" or "No matches".
    var positionAccessibilityText: String? {
        guard searchesDocument, !trimmedQuery.isEmpty else { return nil }
        guard !matches.isEmpty else { return String(localized: "No matches") }
        guard let activeIndex, matches.indices.contains(activeIndex) else {
            return String(localized: "\(matches.count) matches")
        }
        return String(localized: "\(activeIndex + 1) of \(matches.count)")
    }

    // MARK: - Files

    private func updateFiles() {
        guard searchesFiles, files != nil, !trimmedQuery.isEmpty else {
            fileSearch.reset()
            pendingFileSearch = nil
            nameRows = []
            contentRows = []
            rebuildRows()
            return
        }
        startScanIfNeeded()
        searchFiles()
    }

    private func startScanIfNeeded() {
        guard let files, !hasStartedScan else { return }
        hasStartedScan = true
        files.setVisible(true, for: .search)
        pendingScan = Task { [weak self] in
            await files.scanIfVisible()
            guard !Task.isCancelled else { return }
            self?.rootsChanged()
        }
    }

    private func searchFiles() {
        guard let files else { return }
        // Only the roots Files shows (iCloud, On My iPhone): the dormant Workspace never shows.
        let entries = Self.entries(from: FilesSection.phoneRoots(files.roots), excluding: currentURL())
        nameRows = QuickOpenIndex.search(entries, query: query).map { entry in
            SearchRow(id: "name-\(entry.id)", kind: .fileName, url: entry.url, detail: entry.directoryDisplayPath, indicator: entry.name)
        }
        rebuildRows()
        pendingFileSearch = fileSearch.search(query: query, entries: entries)
    }

    private func fileResultsChanged(_ results: [CrossFileSearchResult]) {
        contentRows = results.flatMap { result in
            result.snippets.enumerated().map { index, snippet in
                SearchRow(
                    id: "content-\(result.id)-\(index)",
                    kind: .fileContent(snippet.sourceRange),
                    url: result.url,
                    snippet: snippet,
                    indicator: result.name
                )
            }
        }
        rebuildRows()
    }

    /// Every file of the available roots, without the open document.
    static func entries(from roots: [FilesRoot], excluding current: URL?) -> [QuickOpenEntry] {
        let none = OutlineFileRoot(id: "", title: "", systemImage: "", state: .unassigned, items: [])
        let entries = roots.filter { $0.state == .available }.flatMap { root in
            QuickOpenIndex.flatten(
                iCloudRoot: OutlineFileRoot(
                    id: root.id.rawValue, title: root.title, systemImage: root.systemImage, state: .available, items: root.items
                ),
                workspaceRoot: none
            )
        }
        guard let current else { return entries }
        let currentPath = current.resolvingSymlinksInPath().path
        let currentName = current.lastPathComponent
        return entries.filter { entry in
            entry.name != currentName || entry.url.resolvingSymlinksInPath().path != currentPath
        }
    }

    // MARK: - Rows and status

    private func rebuildRows() {
        var built: [SearchRow] = []
        if !trimmedQuery.isEmpty {
            if searchesDocument { built += inDocumentRows }
            if searchesFiles { built += nameRows + contentRows }
        }
        if built != rows { rows = built }
    }

    /// The quiet line under the field: this document's count, "Searching…" while files are read,
    /// or "No matches". Nil with no query.
    var statusText: String? {
        guard !trimmedQuery.isEmpty else { return nil }
        if searchesDocument, !matches.isEmpty { return String(localized: "\(matches.count) matches") }
        if searchesFiles, isSearchingFiles, files != nil { return String(localized: "Searching…") }
        if rows.isEmpty { return String(localized: "No matches") }
        return nil
    }

    /// The quiet line under the results when some iCloud documents could not be searched because
    /// they are not downloaded. Nil otherwise, and while files are still being read.
    var notDownloadedNote: String? {
        guard !trimmedQuery.isEmpty, searchesFiles, files != nil, !isSearchingFiles, skippedNotDownloadedFiles else { return nil }
        return Self.notDownloadedNoteText
    }

    static var notDownloadedNoteText: String {
        String(localized: "Some iCloud documents aren’t downloaded, so their text wasn’t searched.")
    }

    private func announceStatus() {
        guard searchesDocument,
              let summary = EditorSearchResolver.accessibilitySummary(
                query: query, matchCount: matches.count, activeIndex: activeIndex
              )
        else {
            lastAnnounced = nil
            return
        }
        guard summary != lastAnnounced else { return }
        lastAnnounced = summary
        announce(summary)
    }

    // MARK: - Opening a result

    /// A tap on a result. The sheet goes first. A match in this document is then selected and
    /// brought into view; a file is opened, and its match (if it has one) selected once the editor
    /// shows the opened text. Returns the open's task for a file.
    ///
    /// The open's task holds the editor and the match itself, never the controller: the sheet,
    /// and this controller with it, is usually gone before the file has opened.
    @discardableResult
    func activate(_ row: SearchRow, dismiss: () -> Void) -> Task<Void, Never>? {
        switch row.kind {
        case .inDocument(let shown):
            dismiss()
            let live = EditorSearchResolver.matches(in: editor.currentText, query: query)
            guard let target = live.contains(shown) ? shown : Self.firstMatch(in: live, atOrAfter: shown.location) else {
                return nil
            }
            if let index = matches.firstIndex(of: target), activeIndex != index { activeIndex = index }
            select(target)
            return nil
        case .fileName, .fileContent:
            guard let url = row.url else { return nil }
            dismiss()
            let query = self.query
            let open = self.open
            let editor = self.editor
            let editorWait = self.editorWait
            let kind = row.kind
            return Task {
                guard let text = await open(url) else { return }
                guard case .fileContent(let shown) = kind else { return }
                // Re-resolve against the opened text: the file may have changed since it was read.
                let hits = EditorSearchResolver.matches(in: text, query: query)
                guard let target = Self.firstMatch(in: hits, atOrAfter: shown.location) else { return }
                guard await Self.waitForEditor(editor, toShow: text, within: editorWait) else { return }
                Self.select(target, in: editor)
            }
        }
    }

    /// The first hit at or after `location`, else the first hit.
    static func firstMatch(in hits: [NSRange], atOrAfter location: Int) -> NSRange? {
        hits.first { $0.location >= location } ?? hits.first
    }

    private func select(_ range: NSRange) {
        Self.select(range, in: editor)
    }

    private static func select(_ range: NSRange, in editor: any EditorCommands) {
        editor.selectRange(range)
        editor.scrollToCharacterRange(range)
        editor.flashMatch(range)
    }

    /// The editor takes an opened file's text on its next update; wait (briefly) for it.
    private static func waitForEditor(_ editor: any EditorCommands, toShow text: String, within wait: Duration) async -> Bool {
        let deadline = ContinuousClock.now + wait
        while editor.currentText != text {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
