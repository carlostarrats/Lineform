import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The document content an export writes, built once for both apps: the Styled render (PDF and
/// Print), the Normal raw source, RTF and HTML. The Mac's `DocumentExportRenderer` and the iPhone
/// exporter wrap these in their own page machinery; the content itself is the same definition.
///
/// Every renderer call here is the Mac's export call, argument for argument — tables shrink to the
/// page, code stays monochrome, a failed diagram never reaches the on-disk log, and RTF swaps math
/// and Mermaid for caption + source text because plain RTF cannot portably embed images.
@MainActor
public enum ExportContent {
    /// The app's marketing version, stamped into a diagram's failure caption.
    public static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// The Styled export: the document rendered the way Read mode draws it, wrapped to `paper`'s
    /// content width with `preset`'s typography, on a white page with dark ink.
    public static func styled(
        text: String,
        profile: ReadingProfile,
        paper: ExportPaperSize,
        preset: ExportTypographyPreset,
        documentDirectory: URL?,
        imageProvider: ImageAttachmentProviding,
        appVersion: String,
        displayMetrics: RenderDisplayMetrics
    ) -> NSAttributedString {
        let content = paper.contentSize(preset: preset)
        return MarkdownPreviewRenderer().render(
            text,
            profile: preset.exportReadingProfile(basedOn: profile),
            columnWidth: content.width,
            // Constructed per export: these carry caches sized for a long editing session, and an
            // export is a one-shot.
            mermaidProvider: MermaidImageProvider(),
            mathProvider: MathImageProvider(),
            // Export never writes to the diagram failure log — a failed diagram just prints its
            // captioned-source fallback.
            diagramLog: NullDiagramFailureLog(),
            appVersion: appVersion,
            // Tables shrink to fit the fixed page column rather than overflowing off the right edge.
            fitTablesToWidth: true,
            // Exported/printed code stays monochrome — a deliberate product decision.
            highlightsCode: false,
            documentDirectory: documentDirectory,
            imageProvider: imageProvider,
            headingScale: preset.headingScale,
            displayMetrics: displayMetrics
        )
    }

    /// The Normal export: the RAW markdown source laid out as a plain document — a monospaced face
    /// at the preset body size, dark ink on the white page, with the preset's line height. No
    /// markdown parsing: the `#`, `**`, backticks, etc. print verbatim, exactly as typed.
    public static func rawSource(text: String, preset: ExportTypographyPreset) -> NSAttributedString {
        let font = PlatformFont.monospacedSystemFont(ofSize: preset.bodyPointSize, weight: .regular)
        let paragraph = PlatformMutableParagraphStyle()
        paragraph.lineHeightMultiple = preset.lineHeightMultiple ?? 1.2
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: DiagramPalette.ink(isDark: false),
            .paragraphStyle: paragraph
        ])
    }

    /// The rendered export string for RTF: text only (math and Mermaid become caption + source
    /// text), with no attachments.
    public static func rtfAttributedString(
        text: String,
        profile: ReadingProfile,
        paper: ExportPaperSize,
        preset: ExportTypographyPreset,
        appVersion: String
    ) -> NSAttributedString {
        let content = paper.contentSize(preset: preset)
        return MarkdownPreviewRenderer().render(
            text,
            profile: preset.exportReadingProfile(basedOn: profile),
            columnWidth: content.width,
            mermaidProvider: DisabledMermaidImageProvider(),
            mathProvider: DisabledMathImageProvider(),
            diagramLog: NullDiagramFailureLog(),
            appVersion: appVersion,
            fitTablesToWidth: true,
            imagesAsText: true,
            headingScale: preset.headingScale
        )
    }

    /// The document as RTF data. Pure attributed-string serialization — no print subsystem.
    public static func rtfData(
        text: String,
        profile: ReadingProfile,
        paper: ExportPaperSize,
        preset: ExportTypographyPreset,
        appVersion: String
    ) throws -> Data {
        let attributed = rtfAttributedString(text: text, profile: profile, paper: paper, preset: preset, appVersion: appVersion)
        return try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    /// The document as a standalone HTML file.
    ///
    /// `MarkdownHTMLRenderer` is pure and passes every user-authored path through untouched; the
    /// ONLY bytes produced here are the math and mermaid pictures, which have no path to preserve.
    /// Nothing on disk is read and the network is never touched.
    public static func htmlData(text: String, title: String) -> Data {
        // Constructed per export: these carry caches sized for a long editing session, and an
        // export is a one-shot.
        let mathProvider = MathImageProvider()
        let mermaidProvider = MermaidImageProvider()
        let ink = DiagramPalette.ink(isDark: false)

        let html = MarkdownHTMLRenderer.html(for: text, title: title) { generated in
            let image: PlatformImage
            switch generated {
            case let .math(latex):
                guard case let .image(rendered, _) = mathProvider.outcome(
                    latex: latex, style: .display, foreground: ink, pointSize: 16, scale: 2
                ) else { return nil }
                image = rendered
            case let .mermaid(source):
                guard case let .image(rendered) = mermaidProvider.outcome(
                    source: source, background: .white, foreground: ink, scale: 2
                ) else { return nil }
                image = rendered
            }
            return pngData(from: image)
        }
        return Data(html.utf8)
    }

    /// PNG bytes for a rendered diagram/equation, or nil so the emitter falls back to the source.
    private static func pngData(from image: PlatformImage) -> Data? {
        #if os(macOS)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #else
        return image.pngData()
        #endif
    }
}
