import AppKit
import UniformTypeIdentifiers
import LineformCore

/// A target for File ▸ Export As. Markdown is deliberately absent: saving your document is
/// Save As, exporting a copy in another format is Export As, and keeping a Markdown entry here
/// would put two routes on the same file.
enum ExportFormat: Int, CaseIterable {
    case html, pdf, styledPDF, rtf

    var title: String {
        switch self {
        case .html: return String(localized: "HTML")
        case .pdf: return String(localized: "PDF")
        case .styledPDF: return String(localized: "Styled PDF")
        case .rtf: return String(localized: "Rich Text (.rtf)")
        }
    }

    /// Shown under the format's name in the export panel.
    var description: String {
        switch self {
        case .html: return String(localized: "A web page — your image and link paths kept exactly as written.")
        case .pdf: return String(localized: "Plain markdown source — shows #, ** as typed.")
        case .styledPDF: return String(localized: "Rendered like Read mode — with images, tables, math & diagrams.")
        case .rtf: return String(localized: "Styled text for Word, Pages & Google Docs.")
        }
    }

    var pathExtension: String {
        switch self {
        case .html: return "html"
        case .pdf, .styledPDF: return "pdf"
        case .rtf: return "rtf"
        }
    }

    var contentType: UTType {
        switch self {
        case .html: return .html
        case .pdf, .styledPDF: return .pdf
        case .rtf: return .rtf
        }
    }

    /// PDF formats print to paper; HTML/RTF reflow in their target app.
    var usesPaper: Bool { self == .pdf || self == .styledPDF }
}

/// Guards the one way Save As can still lose work: choosing a destination that is ALREADY open in
/// another tab of this window. macOS's own "Replace?" warning is about the file on disk and says
/// nothing about the other tab, whose stale in-memory snapshot would then autosave straight over the
/// text just written. Rather than dedupe/merge tabs (invasive, and it would silently close a tab the
/// user is looking at), Lineform refuses the save and names the conflicting tab — matching AppKit's
/// own refusal to save one document onto another open document's file.
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

/// Chooses the initial directory for an untitled document's Save As panel. This is a proposal,
/// not a restriction: users can always navigate to any location, including iCloud, in the native
/// panel. When iCloud is hidden in Lineform, however, the system must not silently steer a new
/// document back to Lineform's own iCloud container.
enum NewDocumentSaveLocation {
    static func preferredDirectory(
        showICloudInSidebar: Bool,
        workspaceURL: URL?,
        documentsDirectory: URL?
    ) -> URL? {
        guard !showICloudInSidebar else { return nil }
        return workspaceURL ?? documentsDirectory
    }
}

/// Owns the export panel's accessory: a one-line description of the chosen format, plus a Paper
/// Size popup for the two PDF formats. There is no Format popup — File ▸ Export As already chose
/// the format, so the panel only collects what is still open.
@MainActor
final class ExportPanelController: NSObject {
    let paperPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 150, height: 25))
    private let format: ExportFormat

    init(panel: NSSavePanel, baseName: String, format: ExportFormat, paperTitles: [String], selectedPaper: Int) {
        self.format = format
        super.init()

        let name = baseName.isEmpty ? String(localized: "Untitled") : baseName
        panel.nameFieldStringValue = "\(name).\(format.pathExtension)"
        panel.allowedContentTypes = [format.contentType]

        for title in paperTitles { paperPopup.addItem(withTitle: title) }
        if paperTitles.indices.contains(selectedPaper) { paperPopup.selectItem(at: selectedPaper) }
        // The adjacent "Paper Size:" text field is not programmatically associated, so VoiceOver
        // would otherwise announce only the selected value with no field name.
        paperPopup.setAccessibilityLabel(String(localized: "Paper Size"))

        panel.accessoryView = makeAccessory()
    }

    private func makeAccessory() -> NSView {
        let description = NSTextField(wrappingLabelWithString: format.description)
        description.textColor = .secondaryLabelColor
        description.font = .systemFont(ofSize: 11)
        description.alignment = .center
        description.isSelectable = false
        description.setContentHuggingPriority(.defaultLow, for: .horizontal)
        description.preferredMaxLayoutWidth = 280

        var views: [NSView] = [description]
        if format.usesPaper {
            let label = NSTextField(labelWithString: String(localized: "Paper Size:"))
            label.setContentHuggingPriority(.required, for: .horizontal)
            let row = NSStackView(views: [label, paperPopup])
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .firstBaseline
            views.append(row)
        }

        // The accessory HUGS its content (no fixed width, no edge-pinning to a full-width
        // container); NSSavePanel then centers the hugging accessory horizontally, like TextEdit's
        // format popup. Pinning it full-width left-aligns it instead.
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
        return stack
    }
}
