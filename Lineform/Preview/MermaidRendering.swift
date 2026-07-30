import AppKit
import BeautifulMermaid
import CryptoKit

/// Converts an NSColor to a `#rrggbb` hex string for BeautifulMermaid's two-color mono theme.
enum MermaidHexColor {
    static func string(from color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}

/// Fence info-string detection for the preview renderer.
enum MermaidFence {
    /// True when a trimmed fence line opens a mermaid block (```mermaid or ~~~mermaid).
    static func isMermaidOpening(_ trimmedLine: String) -> Bool {
        let marker: String
        if trimmedLine.hasPrefix("```") { marker = "```" }
        else if trimmedLine.hasPrefix("~~~") { marker = "~~~" }
        else { return false }
        let info = trimmedLine.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).lowercased()
        return info == "mermaid"
    }

    /// True when a trimmed line is any closing/opening fence delimiter.
    static func isFenceDelimiter(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~")
    }

    /// The opening-fence marker (delimiter character + run length) for a trimmed line, or nil if it
    /// isn't a fence opener. A fence run is 3+ of the same `` ` `` or `~`.
    static func openingMarker(_ trimmedLine: String) -> (character: Character, length: Int)? {
        guard let first = trimmedLine.first, first == "`" || first == "~" else { return nil }
        let length = trimmedLine.prefix { $0 == first }.count
        return length >= 3 ? (first, length) : nil
    }

    /// True when a trimmed line closes a fence opened by `marker`, per CommonMark: the same
    /// delimiter character, a run at least as long as the opener's, and nothing but whitespace after
    /// the run. This is what stops a ```` ``` ```` block from being truncated by an inner `~~~` line
    /// (or vice-versa), and stops a code line like `x = "~~~"` from closing a code block.
    static func isClosingFence(_ trimmedLine: String, matching marker: (character: Character, length: Int)) -> Bool {
        let run = trimmedLine.prefix { $0 == marker.character }
        guard run.count >= marker.length else { return false }
        return trimmedLine.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
    }
}

/// The ONE definition of "what part of a mermaid block is the diagram".
///
/// A leading `---`/`---` front-matter block (Mermaid's own `title:`/`config:` header, which most
/// generators emit) and `%%` comments are not diagram source. This was implemented separately in
/// `MermaidTypeClassifier` and in `MermaidPieChart`, and — critically — NOT at the seam where the
/// source is handed to BeautifulMermaid, whose parser reads `"---"` as the first line and throws
/// `invalidHeader("---")`. So a front-matter diagram classified `.supported`, failed, and took the
/// `.failed` path: no diagram, just the captioned source,
/// and 2,000 characters of it written to the on-disk diagram log — the path reserved for genuine
/// library bugs. Every consumer reads this type so the four can't disagree again.
enum MermaidSource {
    /// Lines with blanks, `%%` comments, and a leading front-matter block removed.
    static func significantLines(_ source: String) -> [String] {
        var out: [String] = []
        forEachBodyLine(source) { line in
            if !line.hasPrefix("%%") { out.append(line) }
        }
        return out
    }

    /// First line that is actual diagram source, or nil.
    static func firstSignificantLine(_ source: String) -> String? {
        significantLines(source).first
    }

    /// `source` with a leading `---`/`---` front-matter block removed and everything else kept
    /// verbatim. This is what BeautifulMermaid is given; the front matter carries only config and
    /// title, which Lineform's strict two-color theme ignores anyway.
    static func withoutFrontMatter(_ source: String) -> String {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let openIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[openIndex].trimmingCharacters(in: .whitespaces) == "---",
              let closeIndex = lines[(openIndex + 1)...].firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return source }
        return lines[(closeIndex + 1)...].joined(separator: "\n")
    }

    /// Walks the trimmed, non-blank lines that sit outside a leading front-matter block.
    private static func forEachBodyLine(_ source: String, _ body: (String) -> Void) {
        var inFrontMatter = false
        var seenFirstLine = false
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { seenFirstLine = true; continue }
            if !seenFirstLine, line == "---" { inFrontMatter = true; seenFirstLine = true; continue }
            seenFirstLine = true
            if inFrontMatter {
                if line == "---" { inFrontMatter = false }
                continue
            }
            body(line)
        }
    }
}

/// Decides whether a mermaid block is safe to attempt rendering (size guard → fallback).
enum MermaidBlockPolicy {
    /// Character cap. Cheap, but it bounds only the SOURCE — see `maxSignificantLines`.
    static let maxSourceLength = 20_000

    /// Structural cap, and the one that actually bounds the work. BeautifulMermaid's cost grows
    /// with node count, and its raster area grows roughly quadratically with layout width, so a
    /// 3 KB / 200-node flowchart — one seventh of the character cap — renders for ~1 s on the MAIN
    /// THREAD into a ~392 MB bitmap that instantly exceeds the diagram cache's whole budget and is
    /// evicted, so every keystroke in Split mode pays the full cost again. At 600 nodes it is 22 s
    /// and multi-gigabyte. A real diagram is readable at a fraction of this.
    static let maxSignificantLines = 120

    static func shouldAttemptRender(source: String) -> Bool {
        guard source.count <= maxSourceLength else { return false }
        return MermaidSource.significantLines(source).count <= maxSignificantLines
    }
}

/// Stable, compact cache key for a rendered diagram, keyed by source + theme + scale.
enum MermaidCacheKey {
    static func key(source: String, backgroundHex: String, foregroundHex: String, scale: CGFloat) -> String {
        let material = "\(scale)\n\(backgroundHex)\n\(foregroundHex)\n\(source)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Corrects the orientation of a diagram raster produced by BeautifulMermaid on macOS.
///
/// BeautifulMermaid 1.0.4's AppKit path (`MermaidImageRenderer._renderPrepared`) draws into a
/// raw `CGContext` bitmap, which has a bottom-left origin (y-up), while the library's drawing
/// code is written for a top-left origin (y-down, the UIKit/`UIGraphicsImageRenderer` convention
/// it also targets). No compensating y-flip is inserted, so on macOS every rendered diagram comes
/// back vertically mirrored — layout upside down and text mirrored. The library is a pinned remote
/// dependency and this is the single seam that touches it, so we flip the finished raster upright
/// here rather than forking the package.
/// Returns nil rather than the input when the flip cannot be performed. Handing back the
/// un-flipped image would put a MIRRORED diagram on screen — the one outcome this type exists to
/// prevent — and the allocation only fails for rasters big enough that a retry is the right
/// answer. The caller treats nil as a transient failure.
enum MermaidImageOrientation {
    static func uprightForMacOS(_ image: NSImage) -> NSImage? {
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let ctx = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let flipped = ctx.makeImage() else { return nil }
        // Preserve the point size so Retina scale (pixels-per-point) is retained.
        return NSImage(cgImage: flipped, size: image.size)
    }
}

/// Which renderer, if any, handles a mermaid block.
enum MermaidDiagramKind: Equatable {
    case supported     // BeautifulMermaid renders it
    case pie           // Lineform renders it natively (MermaidPieChart)
    case unsupported   // recognized-but-unrenderable → clean captioned fallback
}

/// Classifies a mermaid block by its declared type WITHOUT invoking BeautifulMermaid.
///
/// BeautifulMermaid 1.0.4's `Parser.parse` matches a fixed prefix set and DEFAULTS everything
/// else to flowchart, so an unsupported type (pie/gantt/mindmap/…) is silently mis-drawn as a
/// garbage flowchart instead of degrading to our clean fallback. This mirrors that parser's
/// supported prefixes exactly. If the BeautifulMermaid pin is bumped, re-check its parser and
/// update this list (same discipline as the orientation-flip note above).
enum MermaidTypeClassifier {
    /// Prefixes BeautifulMermaid 1.0.4 actually renders (lowercased, matched on the first line).
    private static let supportedPrefixes = [
        "sequencediagram", "classdiagram", "erdiagram", "xychart", "statediagram",
        "flowchart", "graph"
    ]

    static func classify(_ source: String) -> MermaidDiagramKind {
        guard let first = MermaidSource.firstSignificantLine(source) else { return .unsupported }
        let lower = first.lowercased()
        if lower.hasPrefix("pie") { return .pie }
        if supportedPrefixes.contains(where: { lower.hasPrefix($0) }) { return .supported }
        return .unsupported
    }
}

/// The result of attempting to render a mermaid block.
enum MermaidRenderOutcome {
    case image(NSImage)
    case skipped               // size guard tripped
    case unsupported(String)   // recognized-but-unrenderable type (e.g. "gantt"); clean fallback, no report/log
    case failed(String)        // render threw or produced no image
}

/// Abstracts diagram image production so the preview renderer's fallback path is testable
/// without the library.
protocol MermaidImageProviding: AnyObject {
    func outcome(source: String, background: NSColor, foreground: NSColor, scale: CGFloat) -> MermaidRenderOutcome
}

/// A provider that never renders (mermaid blocks fall back to captioned source). Used by the
/// back-compat `render(_:profile:)` convenience and by tests.
final class DisabledMermaidImageProvider: MermaidImageProviding {
    func outcome(source: String, background: NSColor, foreground: NSColor, scale: CGFloat) -> MermaidRenderOutcome {
        .skipped
    }
}

/// The single seam that touches BeautifulMermaid. Every render is defensive (do/catch) so any
/// library failure degrades to `.failed` → the captioned-source fallback.
final class MermaidImageProvider: MermaidImageProviding {
    private let cache = NSCache<NSString, NSImage>()
    /// Failed sources are remembered too (key → error), so a broken diagram isn't re-parsed
    /// on every preview pass while the user types elsewhere in the document.
    private let failureCache = NSCache<NSString, NSString>()

    init() {
        cache.countLimit = DiagramCacheBudget.countLimit
        cache.totalCostLimit = DiagramCacheBudget.totalCostLimitBytes
        failureCache.countLimit = 200
    }

    func outcome(source: String, background: NSColor, foreground: NSColor, scale: CGFloat) -> MermaidRenderOutcome {
        guard MermaidBlockPolicy.shouldAttemptRender(source: source) else { return .skipped }

        let kind = MermaidTypeClassifier.classify(source)
        if kind == .unsupported { return .unsupported("unsupported mermaid type") }

        let key = MermaidCacheKey.key(
            source: source,
            backgroundHex: MermaidHexColor.string(from: background),
            foregroundHex: MermaidHexColor.string(from: foreground),
            scale: scale
        ) as NSString
        if let cached = cache.object(forKey: key) { return .image(cached) }
        if let failure = failureCache.object(forKey: key) { return .failed(failure as String) }

        if kind == .pie {
            guard let model = MermaidPieChart.parse(source) else { return .unsupported("malformed pie") }
            guard let image = MermaidPieRenderer.image(model: model, background: background,
                                                       foreground: foreground, scale: scale) else {
                return .failed("Pie render produced no image")   // transient; not neg-cached
            }
            cache.setObject(image, forKey: key, cost: RasterImageCost.bytes(for: image))
            return .image(image)
        }

        // .supported → BeautifulMermaid (existing do/catch, unchanged).
        do {
            let theme = DiagramTheme(background: background, foreground: foreground)
            // Front matter stripped at the seam: BeautifulMermaid throws `invalidHeader("---")`
            // on it, and the classifier that decided this block is `.supported` looked PAST it.
            let renderable = MermaidSource.withoutFrontMatter(source)
            if let image = try MermaidRenderer.renderImage(source: renderable, theme: theme, scale: scale) {
                guard let upright = MermaidImageOrientation.uprightForMacOS(image) else {
                    // The flip's context allocation failed (a huge raster under memory pressure).
                    // Returning the un-flipped image would draw the diagram MIRRORED; a transient
                    // failure that retries later is the honest outcome.
                    return .failed("Mermaid orientation pass could not allocate")
                }
                cache.setObject(upright, forKey: key, cost: RasterImageCost.bytes(for: upright))
                return .image(upright)
            }
            // Not negatively cached: producing no image without an error may be transient
            // (resource pressure), so a later pass should retry.
            return .failed("Mermaid render produced no image")
        } catch {
            // Thrown errors are deterministic parse/render failures for this exact source;
            // cache them so a broken diagram isn't re-parsed on every preview pass.
            let message = String(describing: error)
            failureCache.setObject(message as NSString, forKey: key)
            return .failed(message)
        }
    }
}
