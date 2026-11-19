import AppKit
import Foundation

/// Draws a `MermaidPieModel` as an upright NSImage: title, pie circle, and a legend.
///
/// Monochrome by design — Lineform's mermaid diagrams use a strict two-color (page + ink) theme,
/// so slices are the `foreground` ink at stepped alpha with a thin `foreground` stroke, matching
/// the calm look of every other diagram. We draw the raster ourselves (top-left origin via a
/// flipped image), so no `uprightForMacOS` flip is required.
enum MermaidPieRenderer {
    static func image(model: MermaidPieModel, background: NSColor,
                      foreground: NSColor, scale: CGFloat) -> NSImage? {
        let pieDiameter: CGFloat = 200
        let padding: CGFloat = 16
        let titleFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let legendFont = NSFont.systemFont(ofSize: 12)
        let rowHeight: CGFloat = 20
        let swatch: CGFloat = 12

        let titleHeight: CGFloat = model.title == nil ? 0 : 24
        let legendHeight = CGFloat(model.slices.count) * rowHeight
        let contentWidth = pieDiameter + 24 + legendMaxWidth(model, font: legendFont, swatch: swatch)
        let width = contentWidth + padding * 2
        let height = titleHeight + max(pieDiameter, legendHeight) + padding * 2

        // Draw into a FLIPPED vector image first (top-left origin → text draws upright), then
        // rasterize that into a concrete bitmap rep at `scale` so the result is a crisp Retina
        // raster with a real backing store — matching the BeautifulMermaid/math path (which the
        // cache-cost model and resize-refit both assume). A bare `NSImage(flipped:drawingHandler:)`
        // would stay a lazy point-size vector: soft on Retina and undercounted by the cache.
        let vector = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            if background != .clear {
                ctx.setFillColor(background.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }

            var y = padding
            if let title = model.title {
                drawText(title, at: CGPoint(x: padding, y: y), font: titleFont, color: foreground)
                y += titleHeight
            }

            // Pie circle (flipped context → top-left origin, y grows downward).
            let center = CGPoint(x: padding + pieDiameter / 2, y: y + pieDiameter / 2)
            let radius = pieDiameter / 2
            var startAngle: CGFloat = -.pi / 2   // 12 o'clock
            for (i, slice) in model.slices.enumerated() {
                let sweep = CGFloat(model.fraction(of: slice)) * 2 * .pi
                let end = startAngle + sweep
                let path = CGMutablePath()
                path.move(to: center)
                path.addArc(center: center, radius: radius, startAngle: startAngle,
                            endAngle: end, clockwise: false)
                path.closeSubpath()
                ctx.addPath(path)
                ctx.setFillColor(foreground.withAlphaComponent(alpha(i, of: model.slices.count)).cgColor)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(foreground.cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()
                startAngle = end
            }

            // Legend.
            var ly = y
            let lx = padding + pieDiameter + 24
            for (i, slice) in model.slices.enumerated() {
                let sr = CGRect(x: lx, y: ly + (rowHeight - swatch) / 2, width: swatch, height: swatch)
                ctx.setFillColor(foreground.withAlphaComponent(alpha(i, of: model.slices.count)).cgColor)
                ctx.fill(sr)
                ctx.setStrokeColor(foreground.cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(sr)
                let pct = percent(model.fraction(of: slice))
                let text = "\(slice.label)  \(formatValue(slice.value)) (\(pct)%)"
                drawText(text, at: CGPoint(x: lx + swatch + 8, y: ly + 2), font: legendFont, color: foreground)
                ly += rowHeight
            }
            return true
        }

        // Rasterize the flipped vector into a Retina-resolution bitmap. Drawing an IMAGE into a
        // rect is orientation-stable (unlike text, images don't re-flip with context.isFlipped),
        // so the upright text baked into `vector` stays upright.
        let pixelsWide = max(1, Int((width * scale).rounded()))
        let pixelsHigh = max(1, Int((height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: width, height: height)
        guard let bitmapContext = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = bitmapContext
        vector.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: width, height: height))
        out.addRepresentation(rep)
        return out
    }

    /// Stepped alpha so adjacent slices read distinctly without new hues (0.85 → 0.30).
    private static func alpha(_ index: Int, of count: Int) -> CGFloat {
        guard count > 1 else { return 0.7 }
        let steps: [CGFloat] = [0.85, 0.45, 0.65, 0.30, 0.75, 0.40, 0.55, 0.35]
        return steps[index % steps.count]
    }

    /// Total on every Double. The parser already rejects values this could trap on, but both
    /// halves are kept: the parser is the correctness gate, and the renderer must not crash on
    /// anything a future caller hands it.
    private static func formatValue(_ v: Double) -> String {
        guard v.isFinite, v.magnitude <= MermaidPieChart.maximumSliceValue else {
            return String(format: "%g", v)
        }
        return v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }

    /// `Int((fraction * 100).rounded())` traps when `fraction` is NaN — which it is whenever the
    /// slice total is infinite. Clamped instead.
    private static func percent(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int(min(100, max(0, (fraction * 100).rounded())))
    }

    private static func drawText(_ s: String, at p: CGPoint, font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        NSAttributedString(string: s, attributes: attrs).draw(at: p)
    }

    private static func legendMaxWidth(_ model: MermaidPieModel, font: NSFont, swatch: CGFloat) -> CGFloat {
        var maxW: CGFloat = 120
        for slice in model.slices {
            let pct = percent(model.fraction(of: slice))
            let text = "\(slice.label)  \(formatValue(slice.value)) (\(pct)%)"
            let w = (text as NSString).size(withAttributes: [.font: font]).width + swatch + 8
            maxW = max(maxW, w)
        }
        return maxW
    }
}
