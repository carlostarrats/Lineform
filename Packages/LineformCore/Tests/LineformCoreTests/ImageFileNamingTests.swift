import XCTest
@testable import LineformCore

/// Pins the Mac's image file naming (moved from `LineformTextView+ImageInsertion.swift`) so the
/// iPhone names pasted images exactly the same way.
final class ImageFileNamingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageFileNamingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSanitizesSlashesAndColons() {
        XCTAssertEqual(ImageFileNaming.sanitizedFileBase("a/b:c"), "a-b-c")
        // A run of disallowed characters collapses to ONE dash; leading/trailing dashes go.
        XCTAssertEqual(ImageFileNaming.sanitizedFileBase("//a :: b//"), "a-b")
        // The Mac's screenshot name, with its U+202F narrow no-break space before "PM".
        XCTAssertEqual(
            ImageFileNaming.sanitizedFileBase("Screenshot 2026-11-21 at 10.00.00\u{202F}PM"),
            "Screenshot-2026-11-21-at-10.00.00-PM"
        )
        // Letters, digits, `.`, `-` and `_` survive; anything else (accents included) does not.
        XCTAssertEqual(ImageFileNaming.sanitizedFileBase("my_file.v2-final"), "my_file.v2-final")
        XCTAssertEqual(ImageFileNaming.sanitizedFileBase("café menu"), "caf-menu")
        XCTAssertEqual(ImageFileNaming.sanitizedFileBase("[x](y)"), "x-y")
    }

    func testEmptyBaseFallsBackToImage() {
        XCTAssertEqual(ImageFileNaming.sanitizedFileBase(""), "image")
        XCTAssertEqual(ImageFileNaming.sanitizedFileBase("///"), "image")
        XCTAssertEqual(ImageFileNaming.sanitizedFileBase("日本語"), "image")
        XCTAssertEqual(ImageFileNaming.uniqueURL(in: folder, base: "", ext: "png", fileManager: .default).lastPathComponent,
                       "image.png")
    }

    func testUniquesWithSuffix() throws {
        let first = ImageFileNaming.uniqueURL(in: folder, base: "image", ext: "png", fileManager: .default)
        XCTAssertEqual(first, folder.appendingPathComponent("image.png"))
        try Data().write(to: first)

        // The Mac's counter starts the suffix at 2: image.png, image-2.png, image-3.png.
        let second = ImageFileNaming.uniqueURL(in: folder, base: "image", ext: "png", fileManager: .default)
        XCTAssertEqual(second.lastPathComponent, "image-2.png")
        try Data().write(to: second)
        XCTAssertEqual(ImageFileNaming.uniqueURL(in: folder, base: "image", ext: "png", fileManager: .default).lastPathComponent,
                       "image-3.png")

        // The base is sanitized before uniquing.
        try Data().write(to: folder.appendingPathComponent("a-b.png"))
        XCTAssertEqual(ImageFileNaming.uniqueURL(in: folder, base: "a/b", ext: "png", fileManager: .default).lastPathComponent,
                       "a-b-2.png")
    }

    func testImagesFolderDestinationCreatesImagesAndLinksRelatively() throws {
        let destination = try XCTUnwrap(ImageFileNaming.imagesFolderDestination(
            nextTo: folder, preferredName: "Shot 1", ext: "png", fileManager: .default
        ))
        let images = folder.appendingPathComponent("images", isDirectory: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: images.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(destination.url.standardizedFileURL, images.appendingPathComponent("Shot-1.png").standardizedFileURL)
        XCTAssertEqual(destination.link, "images/Shot-1.png")
    }
}
