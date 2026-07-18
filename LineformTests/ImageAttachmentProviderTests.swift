import XCTest
import AppKit
@testable import Lineform

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

    @discardableResult
    private func writePNG(named name: String, width: Int, height: Int) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url
    }
}

/// A fake `ImageAttachmentProviding` that returns a canned image, proving the seam is
/// protocol-injectable without touching the filesystem.
private final class FakeImageAttachmentProvider: ImageAttachmentProviding {
    func image(at url: URL, maxSize: CGSize, scale: CGFloat) -> NSImage? {
        NSImage(size: CGSize(width: 10, height: 10))
    }
}
