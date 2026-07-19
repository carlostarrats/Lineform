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

        for title in paperTitles { paperPopup.addItem(withTitle: title) }
        if paperTitles.indices.contains(selectedPaper) { paperPopup.selectItem(at: selectedPaper) }

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
