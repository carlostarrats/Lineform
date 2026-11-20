import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LineformCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class ImageAttachmentProviderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Cache key

    func testCacheKeyIncludesUrlModificationDateAndBox() {
        let urlA = URL(fileURLWithPath: "/tmp/a.png")
        let urlB = URL(fileURLWithPath: "/tmp/b.png")
        let dateA = Date(timeIntervalSince1970: 1000)
        let dateB = Date(timeIntervalSince1970: 2000)
        let boxA = CGSize(width: 700, height: 500)
        let boxB = CGSize(width: 400, height: 500)

        let base = ImageAttachmentCacheKey.key(url: urlA, modificationDate: dateA, maxSize: boxA, scale: 2)

        XCTAssertNotEqual(base, ImageAttachmentCacheKey.key(url: urlB, modificationDate: dateA, maxSize: boxA, scale: 2))
        XCTAssertNotEqual(base, ImageAttachmentCacheKey.key(url: urlA, modificationDate: dateB, maxSize: boxA, scale: 2))
        XCTAssertNotEqual(base, ImageAttachmentCacheKey.key(url: urlA, modificationDate: dateA, maxSize: boxB, scale: 2))
        XCTAssertEqual(base, ImageAttachmentCacheKey.key(url: urlA, modificationDate: dateA, maxSize: boxA, scale: 2))
    }

    // MARK: - Real provider

    func testMissingFileReturnsNil() {
        let provider = ImageAttachmentProvider()
        let url = tempDirectory.appendingPathComponent("nope.png")
        XCTAssertNil(provider.image(at: url, maxSize: CGSize(width: 700, height: 500), scale: 2))
    }

    func testCorruptImageReturnsNil() throws {
        let url = tempDirectory.appendingPathComponent("bad.png")
        try "not an image".data(using: .utf8)!.write(to: url)

        let provider = ImageAttachmentProvider()
        XCTAssertNil(provider.image(at: url, maxSize: CGSize(width: 700, height: 500), scale: 2))
    }

    func testValidImageLoadsAndDownscalesWithinBox() throws {
        let url = try writePNG(named: "wide.png", width: 400, height: 200)

        let provider = ImageAttachmentProvider()
        let result = provider.image(at: url, maxSize: CGSize(width: 100, height: 500), scale: 1)

        let image = try XCTUnwrap(result)
        XCTAssertLessThanOrEqual(image.size.width, 100.5)
    }

    func testSmallImageIsNotUpscaled() throws {
        let url = try writePNG(named: "small.png", width: 40, height: 40)

        let provider = ImageAttachmentProvider()
        let result = provider.image(at: url, maxSize: CGSize(width: 700, height: 500), scale: 1)

        let image = try XCTUnwrap(result)
        XCTAssertEqual(image.size.width, 40, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 40, accuracy: 0.5)
    }

    // MARK: - Protocol seam

    func testProviderProtocolIsInjectable() {
        let fake = FakeImageAttachmentProvider()
        let provider: ImageAttachmentProviding = fake
        let url = URL(fileURLWithPath: "/tmp/whatever.png")
        XCTAssertNotNil(provider.image(at: url, maxSize: CGSize(width: 100, height: 100), scale: 1))
    }

    func testDisabledProviderAlwaysReturnsNil() throws {
        let url = try writePNG(named: "disabled.png", width: 40, height: 40)
        let provider: ImageAttachmentProviding = DisabledImageAttachmentProvider()
        XCTAssertNil(provider.image(at: url, maxSize: CGSize(width: 100, height: 100), scale: 1))
    }

    // MARK: - Helpers

    /// A white `width`×`height` PNG, written with Core Graphics and ImageIO so it is the same
    /// file on both platforms.
    @discardableResult
    private func writePNG(named name: String, width: Int, height: Int) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "could not write \(name)")
        return url
    }
}

/// A fake `ImageAttachmentProviding` that returns a canned image, proving the seam is
/// protocol-injectable without touching the filesystem.
private final class FakeImageAttachmentProvider: ImageAttachmentProviding {
    func image(at url: URL, maxSize: CGSize, scale: CGFloat) -> PlatformImage? {
        #if os(macOS)
        NSImage(size: CGSize(width: 10, height: 10))
        #else
        UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        #endif
    }
}
