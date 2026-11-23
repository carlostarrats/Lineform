import UIKit
import XCTest

/// Runs Xcode's accessibility audit (`performAccessibilityAudit`) on each main iPhone screen: the
/// document in Write and Read, the Menu sheet's sections, the Styling sheet and first run. Each
/// screen runs at the default text size and at the largest accessibility size (AX5), in the test
/// plan's language (the Default configuration is English, the `de` one German).
///
/// A local gate: CI only builds the iPhone tests (`build-for-testing`), it never runs them.
/// Every issue the test ignores is matched by one rule in `AuditExceptions`, with its reason.
@MainActor
final class PhoneAccessibilityAuditUITests: XCTestCase {
    /// The largest accessibility text size (AX5).
    static let largestContentSize = "UICTContentSizeCategoryAccessibilityXXXL"

    override func setUp() async throws {
        // Every issue on every screen is reported, not only the first.
        continueAfterFailure = true
    }

    func testScreensAtDefaultTextSize() throws {
        try auditScreens(contentSize: nil)
    }

    func testScreensAtLargestAccessibilityTextSize() throws {
        try auditScreens(contentSize: Self.largestContentSize)
    }

    func testFirstRunAtDefaultTextSize() throws {
        try auditFirstRun(contentSize: nil)
    }

    func testFirstRunAtLargestAccessibilityTextSize() throws {
        try auditFirstRun(contentSize: Self.largestContentSize)
    }

    // MARK: - Screens

    private func auditScreens(contentSize: String?) throws {
        let app = launch(contentSize: contentSize, firstRunCompleted: true)
        let labels = Labels.current

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "The document's text view never appeared")
        try audit(app, screen: "Write (empty)")

        // A heading and a paragraph, so Read, the Outline and the text view have something to show.
        editor.tap()
        editor.typeText("# Audit\n\nA short paragraph for the accessibility audit.\n")

        tap(app.buttons[labels.read].firstMatch, "Read segment")
        try audit(app, screen: "Read")

        tap(app.buttons[labels.write].firstMatch, "Write segment")
        try audit(app, screen: "Write")

        tap(app.buttons[labels.menu].firstMatch, "Menu button")
        XCTAssertTrue(app.buttons[labels.done].waitForExistence(timeout: 5), "The Menu sheet never appeared")
        for section in labels.menuSections {
            let button = app.buttons[section].firstMatch
            scrollSectionBar(app, toReveal: button)
            tap(button, "Menu section \(section)")
            try audit(app, screen: "Menu ▸ \(section)", sheetIsUp: true)
        }
        tap(app.buttons[labels.done].firstMatch, "Menu Done")
        XCTAssertTrue(app.buttons[labels.styling].waitForExistence(timeout: 5))

        tap(app.buttons[labels.styling].firstMatch, "Reading Experience button")
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 5), "The Styling sheet never appeared")
        try audit(app, screen: "Styling", sheetIsUp: true)
    }

    private func auditFirstRun(contentSize: String?) throws {
        let app = launch(contentSize: contentSize, firstRunCompleted: false, forceFirstRun: true)
        let labels = Labels.current
        let start = app.buttons[labels.startWriting]
        // The line and "What to expect" advance by themselves; the points wait for the writer.
        XCTAssertTrue(start.waitForExistence(timeout: 20), "First run never reached its points")
        try audit(app, screen: "First run ▸ points", textGrowsInScrollView: true)
        start.tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10), "Start Writing never reached the document")
    }

    // MARK: - Helpers

    private func launch(contentSize: String?, firstRunCompleted: Bool, forceFirstRun: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        // The test plan's configuration sets this runner's language; the app is launched in it.
        let language = Labels.languageCode
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "de" ? "de_DE" : "en_US"]
        // `FirstRunGate.completedKey`, through the arguments domain of `UserDefaults.standard`.
        app.launchArguments += ["-LineformiOSFirstRunCompleted.v1", firstRunCompleted ? "YES" : "NO"]
        if forceFirstRun {
            // `FirstRunGate.forceEnvironmentKey`.
            app.launchEnvironment["LINEFORM_SHOW_FIRST_RUN"] = "1"
        }
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
        return app
    }

    /// Taps the element's centre: a section button half off screen has no hit point of its own.
    private func tap(_ element: XCUIElement, _ name: String) {
        guard element.waitForExistence(timeout: 5) else {
            XCTFail("\(name) not found")
            return
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// The Menu sheet's section bar scrolls sideways; at the accessibility sizes the later
    /// sections start off screen.
    private func scrollSectionBar(_ app: XCUIApplication, toReveal button: XCUIElement) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        var attempts = 0
        while attempts < 8 {
            let frame = button.frame
            if frame.minX >= window.minX, frame.maxX <= window.maxX { return }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let right = origin.withOffset(CGVector(dx: window.width * 0.8, dy: frame.midY))
            let left = origin.withOffset(CGVector(dx: window.width * 0.2, dy: frame.midY))
            if frame.minX < window.minX {
                left.press(forDuration: 0.05, thenDragTo: right)
            } else {
                right.press(forDuration: 0.05, thenDragTo: left)
            }
            attempts += 1
        }
    }

    /// - Parameter textGrowsInScrollView: every text on the screen is `.fixedSize(horizontal: false,
    ///   vertical: true)` inside a ScrollView, so it can grow but never clip.
    private func audit(
        _ app: XCUIApplication, screen: String, sheetIsUp: Bool = false, textGrowsInScrollView: Bool = false
    ) throws {
        // Let a sheet or a section switch finish drawing before the audit samples it.
        Thread.sleep(forTimeInterval: 1)
        let exceptions = AuditExceptions(app: app, sheetIsUp: sheetIsUp, textGrowsInScrollView: textGrowsInScrollView)
        try XCTContext.runActivity(named: "Audit \(screen)") { activity in
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = screen
            shot.lifetime = .keepAlways
            activity.add(shot)
            try app.performAccessibilityAudit { issue in
                let reason = exceptions.reasonToIgnore(issue)
                let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label)' \($0.frame)" } ?? "nil"
                print("AUDIT [\(screen)] \(reason.map { "ignored (\($0))" } ?? "ISSUE") "
                    + "\(issue.compactDescription) | \(element)")
                return reason != nil
            }
        }
    }
}

/// The audit issues that are not defects, each with the reason. Everything else fails the test.
@MainActor
private struct AuditExceptions {
    var app: XCUIApplication
    var sheetIsUp: Bool
    var textGrowsInScrollView = false

    /// AA for text. The audit's contrast check is re-measured on the screen's own pixels.
    static let minimumContrast = 4.5

    func reasonToIgnore(_ issue: XCUIAccessibilityAuditIssue) -> String? {
        guard let element = issue.element else {
            // The audit names no element when the text sits under a modal sheet: the page behind
            // the Menu or Styling sheet, which VoiceOver deliberately cannot reach while the sheet
            // is up (the Menu sheet is `.isModal`). That page has its own audit (Write, Read).
            return sheetIsUp ? "page under a modal sheet" : nil
        }
        switch issue.auditType {
        case .dynamicType where element.elementType == .textView:
            // The document's text follows the reading profile's type size, the writer's explicit
            // choice in Styling, and never tracks Dynamic Type (`docs/architecture/iphone-app.md`
            // § Accessibility): parity with the Mac, and exports would re-paginate.
            return "document text follows the reading profile"
        case .dynamicType where isInsidePresetCard(element):
            // The preset cards' "Aa" and titles are drawn in the preset's own face at a size
            // scaled by `@ScaledMetric` (`StylingPresetCard`); the audit only recognises text
            // styles. The AX5 run shows them scaled.
            return "preset card scales with @ScaledMetric"
        case .textClipped where textGrowsInScrollView:
            // First run's points: each is `.fixedSize(horizontal: false, vertical: true)` in a
            // ScrollView (`FirstRunOverlay.points`), so it grows and scrolls; it cannot clip. The
            // German screenshots show every point in full.
            return "grows in a ScrollView"
        case .textClipped where isInSectionBar(element):
            // The Menu sheet's section bar is a sideways ScrollView: each title stays on one line
            // by design and scrolls into view rather than wrapping.
            return "section bar scrolls sideways"
        case .contrast where isInSectionBar(element) && !isWhollyOnScreen(element):
            // A section title the bar has scrolled partly off the sheet: the audit samples the
            // part that is not drawn. Fully on screen, the same title is measured below.
            return "section title scrolled off screen"
        case .contrast where visibleShare(of: element) < 0.5:
            // Mostly below the sheet's bottom edge: what the audit samples is not drawn yet. The
            // row is measured when the audit finds it on screen.
            return "mostly off screen"
        case .textClipped where Self.wrapsAtLargestSize.contains(element.label):
            // The audit predicts these may clip "at larger Dynamic Type sizes". They are plain
            // List rows with no line limit; the AX5 run's screenshots (English and German) show
            // each one wrapping in full. "Sort folders by: …" is deliberately NOT here: it is a
            // SwiftUI Menu label, and at AX5 it truncates.
            return "wraps in full at AX5"
        case .textClipped where element.elementType == .button && isOutlineRow(element):
            // An Outline row: two lines at the default sizes by design (a long heading ends in an
            // ellipsis, and VoiceOver reads the whole heading); no limit at the accessibility
            // sizes (`OutlineSection.lineLimit`).
            return "outline row's line limit is deliberate"
        case .sufficientElementDescription where Self.isFileName(element.label):
            // A file row's label is the file's own name, extension included, exactly as Files
            // shows it.
            return "file name"
        case .contrast:
            // Measured on the screenshot: the element's ink against its page. The audit flags
            // text over the sheet's card that the pixels show well above AA.
            guard let ratio = measuredContrast(of: element), ratio >= Self.minimumContrast else { return nil }
            return String(format: "measured %.1f:1", ratio)
        default:
            return nil
        }
    }

    /// List rows that the AX5 screenshots show wrapping in full, in English and German.
    static let wrapsAtLargestSize: Set<String> = [
        "New Document", "Neues Dokument",
        "Open from Files…", "Aus „Dateien“ öffnen…",
        "Show Hidden Folders", "Ausgeblendete Ordner einblenden",
        "Save As…", "Sichern unter …",
        "Insert Table", "Tabelle einfügen",
        "Reformat Table", "Tabelle neu formatieren",
        // Markdown Basics' own heading, inside the section (not the section bar's button).
        "Markdown Basics", "Markdown-Grundlagen",
        // Search's empty state.
        "Search this document and your files.", "Durchsuche dieses Dokument und deine Dateien.",
    ]

    private func isOutlineRow(_ element: XCUIElement) -> Bool {
        guard let value = element.value as? String else { return false }
        return value.hasPrefix("Heading level ") || value.hasPrefix("Überschrift, Ebene ")
    }

    private func isWhollyOnScreen(_ element: XCUIElement) -> Bool {
        app.windows.firstMatch.frame.contains(element.frame)
    }

    /// The share of the element's height that is inside the window.
    private func visibleShare(of element: XCUIElement) -> CGFloat {
        let frame = element.frame
        guard frame.height > 0 else { return 0 }
        let visible = frame.intersection(app.windows.firstMatch.frame)
        return visible.isNull ? 0 : visible.height / frame.height
    }

    private func isInsidePresetCard(_ element: XCUIElement) -> Bool {
        let cards = app.buttons.matching(NSPredicate(
            format: "label ENDSWITH %@ OR label BEGINSWITH %@", " reading theme", "Lesethema "
        ))
        let frame = element.frame
        return cards.allElementsBoundByIndex.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(frame) }
    }

    private func isInSectionBar(_ element: XCUIElement) -> Bool {
        let titles = Set(Labels.current.menuSections)
        guard element.elementType == .staticText, titles.contains(element.label) else { return false }
        // A title of the bar, not the same words elsewhere (Markdown Basics' own heading): it
        // shares the bar's line with a section button.
        return app.buttons.matching(NSPredicate(format: "label IN %@", Array(titles)))
            .allElementsBoundByIndex.contains { abs($0.frame.midY - element.frame.midY) < 2 }
    }

    static func isFileName(_ label: String) -> Bool {
        ["md", "markdown", "txt"].contains((label as NSString).pathExtension.lowercased())
    }

    /// The contrast between the most common colour in the element's on-screen frame (its page)
    /// and the pixel farthest from it (its ink), or nil when the frame is not on screen.
    private func measuredContrast(of element: XCUIElement) -> Double? {
        let screenshot = app.screenshot().image
        guard let cgImage = screenshot.cgImage else { return nil }
        let scale = CGFloat(cgImage.width) / screenshot.size.width
        let window = app.windows.firstMatch.frame
        let visible = element.frame.intersection(window)
        guard !visible.isNull, visible.width >= 2, visible.height >= 2 else { return nil }
        let pixelRect = CGRect(
            x: visible.minX * scale, y: visible.minY * scale,
            width: visible.width * scale, height: visible.height * scale
        ).integral
        guard let crop = cgImage.cropping(to: pixelRect) else { return nil }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var counts: [Int: Int] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let key = Int(pixels[index] >> 3) << 10 | Int(pixels[index + 1] >> 3) << 5 | Int(pixels[index + 2] >> 3)
            counts[key, default: 0] += 1
        }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let page = Self.luminance(
            UInt8((background >> 10 & 31) << 3 | 4), UInt8((background >> 5 & 31) << 3 | 4), UInt8((background & 31) << 3 | 4)
        )
        var best = 1.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let ink = Self.luminance(pixels[index], pixels[index + 1], pixels[index + 2])
            best = max(best, (max(ink, page) + 0.05) / (min(ink, page) + 0.05))
        }
        return best
    }

    /// WCAG relative luminance of an sRGB pixel.
    static func luminance(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Double {
        func linear(_ value: UInt8) -> Double {
            let channel = Double(value) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// The few labels the test taps, in the test plan's languages. English is the catalog key; the
/// German values are the iPhone and package catalogs' translations.
private struct Labels {
    var write: String
    var read: String
    var menu: String
    var done: String
    var styling: String
    var startWriting: String
    var menuSections: [String]

    /// The runner's language, which the test plan's configuration sets.
    static var languageCode: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("de") ? "de" : "en"
    }

    static var current: Labels { languageCode == "de" ? german : english }

    static let english = Labels(
        write: "Write", read: "Read", menu: "Menu", done: "Done", styling: "Reading Experience",
        startWriting: "Start Writing",
        menuSections: ["Files", "Outline", "Markdown Basics", "Search", "Document", "Settings"]
    )

    static let german = Labels(
        write: "Schreiben", read: "Lesen", menu: "Menü", done: "Fertig", styling: "Leseerlebnis",
        startWriting: "Losschreiben",
        menuSections: ["Dateien", "Gliederung", "Markdown-Grundlagen", "Suchen", "Dokument", "Einstellungen"]
    )
}
