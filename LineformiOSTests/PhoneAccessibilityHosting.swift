import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// Hosts a SwiftUI view or a view controller in a real `UIWindow` on the test host's scene, at a
/// chosen content size category, and checks what VoiceOver and Dynamic Type users get: every
/// accessibility element on screen sits inside the window, every interactive element has a label
/// and a 44 × 44 pt target, and no reachable `UILabel` is truncated. No snapshot library: these are
/// layout assertions on the live hierarchy (`SelectionRowTests` hosts the same way).
///
/// Run under the test plan's `de` configuration, the same checks cover German.
///
///     let host = try await PhoneAccessibilityHost(MySheet(), contentSize: .accessibilityExtraExtraExtraLarge)
///     defer { host.tearDown() }
///     host.assertElementsInsideWindow()
///     host.assertInteractiveElementsAreLabelledAndLargeEnough(allowlist: ["menu.close"])
@MainActor
final class PhoneAccessibilityHost {
    /// One accessibility element, as VoiceOver would visit it.
    struct Element: CustomStringConvertible {
        var object: NSObject
        var label: String?
        var identifier: String?
        var traits: UIAccessibilityTraits
        /// Screen coordinates (`accessibilityFrame`).
        var frame: CGRect

        /// Button, adjustable (sliders, steppers) or link.
        var isInteractive: Bool {
            !traits.intersection([.button, .adjustable, .link]).isEmpty
        }

        /// The identifier when there is one, else the label: what an allowlist names.
        var name: String { identifier.flatMap { $0.isEmpty ? nil : $0 } ?? label ?? "<unlabelled \(type(of: object))>" }

        var description: String {
            "\(name) [\(type(of: object))] \(NSCoder.string(for: frame))"
        }
    }

    let window: UIWindow
    let contentSize: UIContentSizeCategory

    /// Hosts `view` with `.environment(\.dynamicTypeSize, …)` matching `contentSize`.
    /// - Parameter size: the window's size; nil keeps the scene's (the simulator's screen).
    convenience init<Content: View>(
        _ view: Content,
        contentSize: UIContentSizeCategory = .large,
        size: CGSize? = nil
    ) async throws {
        let dynamicTypeSize = DynamicTypeSize(contentSize) ?? .large
        let controller = UIHostingController(rootView: AnyView(view.environment(\.dynamicTypeSize, dynamicTypeSize)))
        try await self.init(controller: controller, contentSize: contentSize, size: size)
    }

    /// Hosts `controller` as the window's root.
    init(controller: UIViewController, contentSize: UIContentSizeCategory = .large, size: CGSize? = nil) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        if let size { window.frame = CGRect(origin: .zero, size: size) }
        window.traitOverrides.preferredContentSizeCategory = contentSize
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        self.contentSize = contentSize
        await settle()
    }

    /// Lets SwiftUI and UIKit lay out (and animations start) before measuring.
    func settle(passes: Int = 6) async {
        for _ in 0..<passes {
            try? await Task.sleep(for: .milliseconds(20))
            window.layoutIfNeeded()
        }
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }

    // MARK: - Walking

    /// Every accessibility element under the window, depth first, as VoiceOver orders a
    /// container's children. Hidden views and `accessibilityElementsHidden` subtrees are skipped.
    func elements() -> [Element] {
        var found: [Element] = []
        collect(window, into: &found, depth: 0)
        return found
    }

    private func collect(_ object: NSObject, into found: inout [Element], depth: Int) {
        guard depth < 200 else { return }
        if let view = object as? UIView, view.isHidden || view.alpha < 0.01 { return }
        if object.accessibilityElementsHidden { return }
        if object.isAccessibilityElement {
            found.append(Element(
                object: object,
                label: object.accessibilityLabel,
                identifier: Self.identifier(of: object),
                traits: object.accessibilityTraits,
                frame: object.accessibilityFrame
            ))
            return
        }
        for child in children(of: object) {
            collect(child, into: &found, depth: depth + 1)
        }
    }

    /// SwiftUI's elements answer `accessibilityIdentifier` without declaring
    /// `UIAccessibilityIdentification`, so ask by selector when the cast finds nothing.
    private static func identifier(of object: NSObject) -> String? {
        if let identifier = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier, !identifier.isEmpty {
            return identifier
        }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func children(of object: NSObject) -> [NSObject] {
        if let elements = object.accessibilityElements, !elements.isEmpty {
            return elements.compactMap { $0 as? NSObject }
        }
        let count = object.accessibilityElementCount()
        if count > 0, count != NSNotFound {
            return (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
        }
        return (object as? UIView)?.subviews ?? []
    }

    /// The window's rectangle in the screen coordinates `accessibilityFrame` uses.
    var windowFrameOnScreen: CGRect {
        window.convert(window.bounds, to: window.screen.coordinateSpace)
    }

    // MARK: - Assertions

    /// Every element that is at least partly on screen lies wholly inside the window (nothing is
    /// clipped by its edge). Elements wholly outside — scrolled out of a list — are skipped unless
    /// `ignoresWhollyOffscreen` is false.
    func assertElementsInsideWindow(
        allowlist: Set<String> = [],
        ignoresWhollyOffscreen: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let bounds = windowFrameOnScreen.insetBy(dx: -0.5, dy: -0.5)
        let all = elements()
        XCTAssertFalse(all.isEmpty, "no accessibility elements were found", file: file, line: line)
        for element in all where !allowlist.contains(element.name) {
            if element.frame.isEmpty { continue }
            if ignoresWhollyOffscreen, !element.frame.intersects(bounds) { continue }
            XCTAssertTrue(
                bounds.contains(element.frame),
                "\(element) is not inside the window \(NSCoder.string(for: windowFrameOnScreen)) at \(contentSize.rawValue)",
                file: file, line: line
            )
        }
    }

    /// Every button, adjustable and link carries a non-empty label and a target at least
    /// `minimumSide` points on each side. `allowlist` names elements (identifier, else label)
    /// exempt from the size check, each for a reason the caller states.
    func assertInteractiveElementsAreLabelledAndLargeEnough(
        minimumSide: CGFloat = 44,
        allowlist: Set<String> = [],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let interactive = elements().filter(\.isInteractive)
        for element in interactive {
            let label = element.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            XCTAssertFalse(label.isEmpty, "\(element) has no accessibility label", file: file, line: line)
            guard !allowlist.contains(element.name) else { continue }
            XCTAssertTrue(
                element.frame.width >= minimumSide - 0.5 && element.frame.height >= minimumSide - 0.5,
                "\(element) is smaller than \(minimumSide) × \(minimumSide) pt",
                file: file, line: line
            )
        }
    }

    /// Every visible `UILabel` under the window shows its whole text: it fits its bounds at its
    /// line limit. SwiftUI `Text` is not a `UILabel` and is not reached here; check those through
    /// element frames.
    func assertLabelsAreNotTruncated(
        allowlist: Set<String> = [],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for label in Self.labels(in: window) {
            guard let text = label.text ?? label.attributedText?.string, !text.isEmpty,
                  !allowlist.contains(text), label.bounds.width > 0 else { continue }
            let unlimited = label.textRect(
                forBounds: CGRect(x: 0, y: 0, width: label.bounds.width, height: .greatestFiniteMagnitude),
                limitedToNumberOfLines: 0
            )
            let limited = label.textRect(
                forBounds: CGRect(x: 0, y: 0, width: label.bounds.width, height: .greatestFiniteMagnitude),
                limitedToNumberOfLines: label.numberOfLines
            )
            let fitsLineLimit = unlimited.height <= limited.height + 0.5
            let fitsBounds = unlimited.height <= label.bounds.height + 0.5
            let fitsWidth = label.numberOfLines != 1 || label.intrinsicContentSize.width <= label.bounds.width + 0.5
            XCTAssertTrue(
                fitsLineLimit && fitsBounds && fitsWidth,
                "label “\(text)” is truncated at \(contentSize.rawValue): needs \(NSCoder.string(for: unlimited.size)), has \(NSCoder.string(for: label.bounds.size))",
                file: file, line: line
            )
        }
    }

    private static func labels(in view: UIView) -> [UILabel] {
        guard !view.isHidden, view.alpha >= 0.01 else { return [] }
        if let label = view as? UILabel { return [label] }
        return view.subviews.flatMap { labels(in: $0) }
    }
}

/// The helper finds SwiftUI's elements at all: without that every assertion above passes vacuously.
@MainActor
final class PhoneAccessibilityHostTests: XCTestCase {
    func testFindsSwiftUIElementsAndFlagsSmallTargets() async throws {
        let view = VStack(spacing: 20) {
            Text(verbatim: "Heading")
            Button(action: {}) { Text(verbatim: "Large").frame(width: 120, height: 50) }
                .accessibilityIdentifier("host.large")
            Button(action: {}) { Text(verbatim: "S").frame(width: 20, height: 20) }
                .accessibilityIdentifier("host.small")
        }
        let host = try await PhoneAccessibilityHost(view, contentSize: .accessibilityExtraExtraExtraLarge)
        defer { host.tearDown() }

        let elements = host.elements()
        XCTAssertTrue(elements.contains { $0.label == "Heading" }, "\(elements)")
        let large = try XCTUnwrap(elements.first { $0.identifier == "host.large" }, "\(elements)")
        XCTAssertTrue(large.isInteractive)
        XCTAssertGreaterThanOrEqual(large.frame.width, 44)
        host.assertElementsInsideWindow()
        host.assertInteractiveElementsAreLabelledAndLargeEnough(allowlist: ["host.small"])
        let small = try XCTUnwrap(elements.first { $0.identifier == "host.small" })
        XCTAssertLessThan(small.frame.width, 44, "the small target is measured, so the check is not vacuous")
    }
}

extension XCTestCase {
    /// The interface language the suite runs in: `en` in the plan's Default configuration, `de`
    /// in its `de` configuration (`LineformiOS.xctestplan`).
    var interfaceLanguage: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// Skips a test that pins English (the spec's wording, the Mac's strings, an English
    /// fixture, or the English spelling dictionary the keyboard language selects) when the suite
    /// runs in another language. Test plan configurations share one test selection, so this is
    /// how a test opts out of the `de` run. Completeness of every language is gated separately by
    /// `PhoneCatalogCompletenessTests`.
    func skipUnlessEnglishInterface(_ reason: String = "pins English copy") throws {
        let language = interfaceLanguage
        guard language == "en" else { throw XCTSkip("\(reason); the interface language is \(language)") }
    }
}

/// Turns accessibility on for the test process, so SwiftUI builds the accessibility elements the
/// hosted tests walk. SwiftUI vends no elements while the device's accessibility is off — the
/// default on any fresh simulator — and every test that finds a control by its label then times
/// out or passes vacuously. A UI-test runner gets this from XCUITest's automation session; unit
/// tests have to ask. Test code only: the app never calls this.
///
/// The bundle's principal class (`INFOPLIST_KEY_NSPrincipalClass`) calls `enable()` before the
/// first test and `restore()` after the last, so the simulator's own setting is left as found.
enum TestProcessAccessibility {
    private typealias Getter = @convention(c) () -> Bool
    private typealias Setter = @convention(c) (Bool) -> Void

    nonisolated(unsafe) private static let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW)
    nonisolated(unsafe) private static var saved: (application: Bool, automation: Bool)?

    private static func function<T>(_ name: String, as: T.Type) -> T? {
        guard let library, let symbol = dlsym(library, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    /// Enables application accessibility and automation for this process; returns false when
    /// the library or its functions are missing.
    @discardableResult
    static func enable() -> Bool {
        guard let applicationEnabled = function("_AXSApplicationAccessibilityEnabled", as: Getter.self),
              let setApplication = function("_AXSApplicationAccessibilitySetEnabled", as: Setter.self),
              let automationEnabled = function("_AXSAutomationEnabled", as: Getter.self),
              let setAutomation = function("_AXSSetAutomationEnabled", as: Setter.self)
        else { return false }
        if saved == nil { saved = (applicationEnabled(), automationEnabled()) }
        setApplication(true)
        setAutomation(true)
        return true
    }

    /// Puts both settings back to what `enable()` found.
    static func restore() {
        guard let saved,
              let setApplication = function("_AXSApplicationAccessibilitySetEnabled", as: Setter.self),
              let setAutomation = function("_AXSSetAutomationEnabled", as: Setter.self)
        else { return }
        setApplication(saved.application)
        setAutomation(saved.automation)
        Self.saved = nil
    }
}

/// `LineformiOSTests`' principal class: XCTest makes one before the first test runs.
@objc(LineformiOSTestsPrincipal)
final class LineformiOSTestsPrincipal: NSObject, XCTestObservation {
    override init() {
        super.init()
        TestProcessAccessibility.enable()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        TestProcessAccessibility.restore()
    }
}
