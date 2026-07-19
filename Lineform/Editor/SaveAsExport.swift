import AppKit
import UniformTypeIdentifiers

/// The formats offered by the single File ▸ Save As… command. Markdown writes the real `.md`
/// document; PDF / Styled PDF export the rendered document at the two typographic presets; RTF
/// exports styled rich text for Word/Pages.
enum SaveAsFormat: Int, CaseIterable {
    case markdown, pdf, styledPDF, rtf

    var title: String {
        switch self {
        case .markdown: return "Markdown (.md)"
        case .pdf: return "PDF"
        case .styledPDF: return "Styled PDF"
        case .rtf: return "Rich Text (.rtf)"
        }
    }

    /// One-line explanation shown under the Format popup in the Save As panel, so the difference
    /// between PDF and Styled PDF is legible before choosing.
    var description: String {
        switch self {
        case .markdown: return "The editable source file."
        case .pdf: return "Plain markdown source — shows #, ** as typed."
        case .styledPDF: return "Rendered like Read mode — with images, tables, math & diagrams."
        case .rtf: return "Styled text for Word, Pages & Google Docs."
        }
    }

    var pathExtension: String {
        switch self {
        case .markdown: return "md"
        case .pdf, .styledPDF: return "pdf"
        case .rtf: return "rtf"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .pdf, .styledPDF: return .pdf
        case .rtf: return .rtf
        }
    }

    /// PDF formats print to paper; Markdown/RTF reflow in their target app.
    var usesPaper: Bool { self == .pdf || self == .styledPDF }
}

/// Guards the one way Save As can still lose work: choosing a destination that is ALREADY open in
/// another tab of this window. macOS's own "Replace?" warning is about the file on disk and says
/// nothing about the other tab, whose stale in-memory snapshot would then autosave straight over the
/// text just written. Rather than dedupe/merge tabs (invasive, and it would silently close a tab the
/// user is looking at), Lineform refuses the save and names the conflicting tab — matching AppKit's
/// own refusal to save one document onto another open document's file.
/// Whether two URLs name the same file on disk. Shared by the Save As destination guard and by
/// open-time tab dedupe (`EditorTabStore.locate`) so "already open" means the same thing in both —
/// if they disagreed, a file could slip past dedupe and then be refused at save, or vice versa.
enum FileIdentity {
    /// Both sides are first put through `resolvingSymlinksInPath()`, which is the only thing that
    /// follows a symlink at the LAST path component — `canonicalPath` resolves symlinked ancestors
    /// but hands back the link's own path for the leaf, so without this an `alias.md` tab and the
    /// `note.md` it points at look like two files. It is safe to use here, unlike inside
    /// `comparisonKey`, precisely because it is applied to BOTH sides before anything else, so it
    /// can't pull the two keys in opposite directions.
    ///
    /// Sameness is deliberately decided by PATH and not by file identity (inode): two HARD LINKS to
    /// one inode are not the same file for our purposes. Every write in this app is a safe-save —
    /// `Data.write(.atomic)` and `NSDocument`'s save alike write a temp file and rename it into
    /// place — which REPLACES the directory entry and breaks the link rather than overwriting shared
    /// bytes, so the other tab's file is left untouched. Verified by measurement across every write
    /// this fronts: `.saveOperation`, `.saveAsOperation`, autosave-in-place and `Data.write(.atomic)`
    /// all leave a new inode with the sibling intact. Matching on inode would refuse a harmless save,
    /// and a wrong refusal has no in-app override.
    static func isSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        key(for: lhs) == key(for: rhs)
    }

    /// The comparison key on its own, so a caller matching ONE url against many (tab dedupe) can
    /// resolve the query once instead of re-walking the file system for every candidate — each call
    /// is up to four disk round-trips on the main thread, and iCloud/network volumes make that felt.
    static func key(for url: URL) -> String {
        comparisonKey(for: url.standardizedFileURL.resolvingSymlinksInPath())
    }

    /// A path normalized far enough that two spellings of one file compare equal. Plain path
    /// comparison is not enough: macOS volumes are case-INSENSITIVE by default, so `Notes.md` and
    /// `notes.md` are one file and a string compare would miss the clobber.
    ///
    /// `canonicalPath` returns the true on-disk casing and resolves symlinked ancestors, so a
    /// case-only difference matches on a case-insensitive volume and does NOT match on a
    /// case-sensitive one (where they really are two files). It exists only for a file that is on
    /// disk, so a not-yet-created destination normalizes its PARENT directory instead and re-attaches
    /// the file name.
    ///
    /// The parent is resolved through symlinks BEFORE being canonicalized, because `canonicalPath`
    /// will not resolve a symlinked directory that is the last component it is handed — so `/tmp`
    /// would stay `/tmp` and `/tmp/ghost.md` vs `/private/tmp/ghost.md` (one directory, two
    /// spellings) would produce two keys. The `canonicalPath` call on the already-resolved parent is
    /// belt-and-braces: no case is known where it changes the result, since `resolvingSymlinksInPath`
    /// also folds case for components that exist.
    ///
    /// KNOWN GAPS (accepted), all requiring NEITHER side to exist: a difference only in the FILE
    /// NAME's case; a last component that is itself a symlink; and a parent chain that isn't on disk
    /// either (`/tmp/nope/x.md` vs `/private/tmp/nope/x.md`). Every one needs a path that isn't on
    /// disk — and both overwriting and opening mean it is, and `NSSavePanel` only ever yields an
    /// existing parent — so none is reachable. Do not "fix" the case gap by lowercasing: that would
    /// wrongly refuse legitimate saves on a case-sensitive volume, with no in-app override.
    private static func comparisonKey(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        if let canonical = try? standardized.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return canonical
        }
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        let canonicalParent = (try? parent.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? parent.path
        return canonicalParent + "/" + standardized.lastPathComponent
    }
}

enum SaveAsConflict {
    /// The display title of another tab already pointing at `destination`, or nil when the save is
    /// safe. `tabs` is every tab in every window; the active tab is identified by `activeTabID`.
    static func conflictingTabTitle(destination: URL, tabs: [DocumentTab], activeTabID: UUID?) -> String? {
        let activeTab = tabs.first { $0.id == activeTabID }
        // Saving a document back onto the file it already occupies is an ordinary Save As, never the
        // hazard this guards. It must be excluded by PATH and not merely by tab ID: nothing stops
        // the same file being open in a second window, and matching that tab would refuse the most
        // routine Save As there is ("keep the same name") with no way for the user to proceed.
        //
        // The state this exclusion permits — a second window holding the active tab's own file — is
        // what `EditorTabStore.locate` exists to prevent, by revealing the window that already has
        // the file instead of opening a copy. That covers every IN-APP open (sidebar, ⌘K, cross-file
        // search). It does NOT cover ⌘O/Finder/CLI/App Intents, which build a fresh window through
        // DocumentGroup: AppKit dedupes on `NSDocument.fileURL`, and this app repoints that to the
        // ACTIVE tab's file, so a file sitting in a BACKGROUND tab is invisible to it and can be
        // opened a second time. In that residual case plain ⌘S races identically — the duplicate
        // window is the bug, not this save, and refusing here would block a routine save without
        // fixing it.
        if let activeURL = activeTab?.fileURL, FileIdentity.isSameFile(activeURL, destination) {
            return nil
        }
        return tabs.first { tab in
            guard tab.id != activeTabID, let url = tab.fileURL else { return false }
            return FileIdentity.isSameFile(url, destination)
        }?.title
    }
}

/// Owns the Format (and Paper) popups in the Save As… panel's accessory view and keeps the panel's
/// filename extension + allowed type in sync as the user changes the format. An `NSObject` so it can
/// be the popup's target/action.
@MainActor
final class SaveAsPanelController: NSObject {
    private weak var panel: NSSavePanel?
    private let baseName: String
    private let formatPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 25))
    let paperPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 150, height: 25))
    private let descriptionLabel: NSTextField = {
        let field = NSTextField(wrappingLabelWithString: "")
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 11)
        field.alignment = .center
        field.isSelectable = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.preferredMaxLayoutWidth = 280
        return field
    }()

    var selectedFormat: SaveAsFormat {
        SaveAsFormat(rawValue: formatPopup.indexOfSelectedItem) ?? .markdown
    }

    init(panel: NSSavePanel, baseName: String, paperTitles: [String], selectedPaper: Int, initialFormat: SaveAsFormat) {
        self.panel = panel
        self.baseName = baseName.isEmpty ? "Untitled" : baseName
        super.init()

        for format in SaveAsFormat.allCases { formatPopup.addItem(withTitle: format.title) }
        formatPopup.selectItem(at: initialFormat.rawValue)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        // The adjacent "Format:" text field is not programmatically associated, so VoiceOver would
        // otherwise announce only the selected value with no field name.
        formatPopup.setAccessibilityLabel("Format")

        for title in paperTitles { paperPopup.addItem(withTitle: title) }
        if paperTitles.indices.contains(selectedPaper) { paperPopup.selectItem(at: selectedPaper) }
        paperPopup.setAccessibilityLabel("Paper Size")

        panel.accessoryView = makeAccessory()
        syncPanel()
    }

    @objc private func formatChanged() { syncPanel() }

    /// Keep the panel's filename extension + allowed type matching the chosen format, and show the
    /// paper row only for the PDF formats.
    private func syncPanel() {
        let format = selectedFormat
        panel?.nameFieldStringValue = "\(baseName).\(format.pathExtension)"
        panel?.allowedContentTypes = [format.contentType]
        paperRow.isHidden = !format.usesPaper
        descriptionLabel.stringValue = format.description
    }

    private var paperRow = NSView()

    private func makeAccessory() -> NSView {
        let formatLabel = label("Format:")
        let formatRow = row(formatLabel, formatPopup)

        let paperLabel = label("Paper Size:")
        paperRow = row(paperLabel, paperPopup)

        // The accessory HUGS its content (no fixed width, no edge-pinning to a full-width container);
        // NSSavePanel then centers the hugging accessory horizontally, like TextEdit's format popup.
        // `.centerX` centers the two rows relative to each other.
        let stack = NSStackView(views: [formatRow, descriptionLabel, paperRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        return stack
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }

    private func row(_ label: NSView, _ control: NSView) -> NSView {
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        return row
    }
}
