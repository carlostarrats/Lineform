import LineformCore
import UIKit

/// The iPhone's Normal and Styled PDF. The content is the Mac's (`ExportContent.styled` for
/// Styled, `ExportContent.rawSource` for Normal); only the page machinery is the iPhone's own:
/// `PhonePageLayout` paginates it and `UIGraphicsPDFRenderer` writes each page, filled white, with
/// the text at the preset's margins.
@MainActor
enum PhonePDFRenderer {
    /// The rasterization scale for math, diagrams and images in the PDF (the Mac's Retina export).
    static let attachmentScale: CGFloat = 2

    static func pdfData(
        text: String,
        profile: ReadingProfile,
        paper: ExportPaperSize,
        preset: ExportTypographyPreset,
        documentDirectory: URL?
    ) -> Data {
        let content = paper.contentSize(preset: preset)
        // A document past the page cap is not exported at all rather than cut short: the empty
        // data becomes the export's failure notice.
        guard let layout = PhonePageLayout(
            attributed: attributedString(
                text: text, profile: profile, paper: paper, preset: preset, documentDirectory: documentDirectory
            ),
            pageContentSize: content
        ) else { return Data() }
        let page = CGRect(origin: .zero, size: paper.sizeInPoints)
        let origin = CGPoint(x: preset.pageMargins.left, y: preset.pageMargins.top)
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: UIGraphicsPDFRendererFormat())
        return renderer.pdfData { context in
            for index in 0..<layout.pageCount {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(page)
                layout.drawPage(index, contentOrigin: origin)
            }
        }
    }

    /// Styled renders the document the way Read mode does; Normal prints the raw source.
    static func attributedString(
        text: String,
        profile: ReadingProfile,
        paper: ExportPaperSize,
        preset: ExportTypographyPreset,
        documentDirectory: URL?
    ) -> NSAttributedString {
        guard preset.rendersMarkdown else {
            return ExportContent.rawSource(text: text, preset: preset)
        }
        return ExportContent.styled(
            text: text,
            profile: profile,
            paper: paper,
            preset: preset,
            // The renderer resolves image paths only inside `documentDirectory`; nil loads none.
            documentDirectory: documentDirectory,
            imageProvider: ImageAttachmentProvider(),
            appVersion: ExportContent.appVersion,
            // Block images cap against the page, not the phone's screen.
            displayMetrics: RenderDisplayMetrics(
                scale: attachmentScale,
                visibleViewportHeight: paper.contentSize(preset: preset).height
            )
        )
    }
}
