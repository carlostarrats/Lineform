import CoreGraphics
import PDFKit
import UIKit
import XCTest

/// Reads a rendered image's pixels in visual order (row 0 is the TOP row) so orientation tests can
/// ask where the ink is. The iPhone mirror of the package's `RasterInkScan` (the app's tests cannot
/// import the package's test target): the image is drawn onto an opaque white page first, so a
/// transparent background reads as white; a pixel is ink when any channel is darker than
/// `threshold`.
struct PhoneRasterInk {
    let width: Int
    let height: Int
    private let ink: [Bool]

    init(_ image: UIImage, threshold: UInt8 = 160) throws {
        // `cgImage` ignores `imageOrientation`, so the scan is only visual order when it is `.up`.
        XCTAssertEqual(image.imageOrientation, .up, "the scan reads cgImage, which ignores orientation")
        let cgImage = try XCTUnwrap(image.cgImage, "the image has no CGImage")
        let width = cgImage.width
        let height = cgImage.height
        self.width = width
        self.height = height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Drawing a CGImage into a bitmap context keeps it upright, and the context's first
            // row in memory is the image's visual top row.
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drawn, "could not create the scan context")
        var ink = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                ink[y * width + x] = min(pixels[offset], pixels[offset + 1], pixels[offset + 2]) < threshold
            }
        }
        self.ink = ink
    }

    func isInk(x: Int, y: Int) -> Bool { ink[y * width + x] }

    /// The first row (from the top) holding any ink.
    var firstInkRow: Int? {
        (0..<height).first { y in (0..<width).contains { isInk(x: $0, y: y) } }
    }

    /// The last row (from the top) holding any ink.
    var lastInkRow: Int? {
        (0..<height).last { y in (0..<width).contains { isInk(x: $0, y: y) } }
    }

    /// The distance from row `y`'s left-most to its right-most ink pixel, or nil without ink.
    func inkSpan(row y: Int) -> Int? {
        guard let left = (0..<width).first(where: { isInk(x: $0, y: y) }),
              let right = (0..<width).last(where: { isInk(x: $0, y: y) }) else { return nil }
        return right - left
    }

    /// The row whose ink spans the widest distance from its left-most to its right-most ink pixel.
    var widestInkRow: Int? {
        var best: (row: Int, span: Int)?
        for y in 0..<height {
            guard let span = inkSpan(row: y) else { continue }
            if best == nil || span > best!.span { best = (y, span) }
        }
        return best?.row
    }

    /// The left-most column holding any ink.
    var leftmostInkColumn: Int? {
        (0..<width).first { x in (0..<height).contains { isInk(x: x, y: $0) } }
    }

    /// The right-most column holding any ink.
    var rightmostInkColumn: Int? {
        (0..<width).last { x in (0..<height).contains { isInk(x: x, y: $0) } }
    }

    /// The topmost ink row in column `x`.
    func topmostInk(inColumn x: Int) -> Int? {
        (0..<height).first { isInk(x: x, y: $0) }
    }

    /// A PDF page drawn at `scale` pixels per point onto a pure RED canvas, so a page that paints
    /// nothing reads as red (ink) and a page that paints itself white reads as white.
    static func renderOnRed(_ page: PDFPage, scale: CGFloat) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: bounds.size))
            let cg = context.cgContext
            // PDF space is bottom-left; the image renderer's context is top-left.
            cg.translateBy(x: 0, y: bounds.height)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: cg)
        }
    }
}
