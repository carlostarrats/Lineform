import CoreGraphics
import XCTest
@testable import LineformCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Reads a rendered image's pixels in visual order (row 0 is the TOP row) so orientation tests can
/// ask where the ink is. The image is drawn onto an opaque white page first, so a transparent
/// background reads as white; a pixel is ink when any channel is darker than `threshold`.
struct RasterInkScan {
    let width: Int
    let height: Int
    private let ink: [Bool]

    init(_ image: PlatformImage, threshold: UInt8 = 160) throws {
        #if os(macOS)
        var proposed = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
                                    "the image has no CGImage")
        #else
        let cgImage = try XCTUnwrap(image.cgImage, "the image has no CGImage")
        #endif
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

    /// The row whose ink spans the widest distance from its left-most to its right-most ink pixel.
    var widestInkRow: Int? {
        var best: (row: Int, span: Int)?
        for y in 0..<height {
            guard let left = (0..<width).first(where: { isInk(x: $0, y: y) }),
                  let right = (0..<width).last(where: { isInk(x: $0, y: y) }) else { continue }
            let span = right - left
            if best == nil || span > best!.span { best = (y, span) }
        }
        return best?.row
    }

    /// The right-most column holding any ink.
    var rightmostInkColumn: Int? {
        (0..<width).last { x in (0..<height).contains { isInk(x: x, y: $0) } }
    }

    /// The topmost ink row in column `x`.
    func topmostInk(inColumn x: Int) -> Int? {
        (0..<height).first { isInk(x: x, y: $0) }
    }
}
