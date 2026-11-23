import LineformCore
import SwiftUI
import UIKit
import XCTest
@testable import LineformiOS

/// The Menu sheet's Settings: the Mac's keys and defaults (per device), Automatic Dark Mode
/// following the iPhone's appearance, the spelling switch reaching the editor, and no iPhone
/// string that talks about a Mac or a sidebar.
@MainActor
final class SettingsTests: XCTestCase {
    private var folder: URL!
    private var window: UIWindow?
    private var suites: [String] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        try? FileManager.default.removeItem(at: folder)
    }

    func testSettingsUseMacKeysAndDefaults() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.automaticDarkMode, "every setting is on until the writer turns it off")
        XCTAssertTrue(settings.showICloudInFiles)
        XCTAssertTrue(settings.checksSpellingWhileTyping)
        XCTAssertTrue(settings.checksForAnnouncements)
        XCTAssertNil(defaults.object(forKey: LineformSettingKeys.automaticDarkMode), "reading a default writes nothing")

        settings.automaticDarkMode = false
        settings.showICloudInFiles = false
        settings.checksSpellingWhileTyping = false
        settings.checksForAnnouncements = false
        // The Mac's key names, byte for byte.
        XCTAssertEqual(defaults.object(forKey: "Lineform.settings.automaticDarkMode") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "Lineform.settings.showICloudInSidebar") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "Lineform.settings.checksSpellingWhileTyping") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "Lineform.settings.checksForAnnouncements") as? Bool, false)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.automaticDarkMode)
        XCTAssertFalse(reloaded.showICloudInFiles)
        XCTAssertFalse(reloaded.checksSpellingWhileTyping)
        XCTAssertFalse(reloaded.checksForAnnouncements)

        // pinned-en: the rows, in order.
        XCTAssertEqual(SettingsSection.rows.map(\.title), [
            "Automatic Dark Mode", "Show iCloud in Files", "Check spelling while typing", "In-app notifications",
        ])
        XCTAssertTrue(SettingsSection.rows.allSatisfy { !$0.note.isEmpty }, "every row explains itself")
        // pinned-en: every row, the switches then Clear History (the Mac's copy).
        XCTAssertEqual(SettingsSection.rowTitles, [
            "Automatic Dark Mode", "Show iCloud in Files", "Check spelling while typing", "In-app notifications",
            "Clear History",
        ])
        XCTAssertFalse(SettingsSection.clearHistoryNote.isEmpty)
    }

    func testAutomaticDarkModeFollowsAppearance() async throws {
        // The mapping is the Mac's: a light theme draws as Quiet; Quiet and Night keep their own.
        XCTAssertEqual(AppSettings.displayProfile(.original, automaticDarkMode: true, userInterfaceStyle: .dark).themeID, .quiet)
        XCTAssertEqual(AppSettings.displayProfile(.original, automaticDarkMode: true, userInterfaceStyle: .light).themeID, .system)
        XCTAssertEqual(AppSettings.displayProfile(.original, automaticDarkMode: false, userInterfaceStyle: .dark).themeID, .system)
        var night = ReadingProfile.original
        night.themeID = .night
        XCTAssertEqual(AppSettings.displayProfile(night, automaticDarkMode: true, userInterfaceStyle: .dark).themeID, .night)
        XCTAssertEqual(
            AppSettings.displayProfile(.original, automaticDarkMode: true, userInterfaceStyle: .dark),
            ReadingProfile.original.displayProfile(automaticDarkMode: true, systemIsDark: true)
        )

        // On screen: the editor re-renders when the appearance changes, and when the switch does.
        let settings = AppSettings(defaults: try makeDefaults())
        let window = try await hostScreen(settings: settings, style: .dark)
        let editor = try XCTUnwrap(find(LineformTextView.self, in: window))
        XCTAssertEqual(editor.profile.themeID, .quiet, "Dark appearance draws the page as Quiet")

        window.overrideUserInterfaceStyle = .light
        try await spin { editor.profile.themeID == .system }

        window.overrideUserInterfaceStyle = .dark
        try await spin { editor.profile.themeID == .quiet }

        settings.automaticDarkMode = false
        try await spin { editor.profile.themeID == .system }
    }

    func testSpellingToggleStopsPass() async throws {
        _ = try XCTUnwrap(SpellCheckPass.language(primary: "en-US"), "the simulator has an English dictionary")
        let settings = AppSettings(defaults: try makeDefaults())
        settings.checksSpellingWhileTyping = false
        let window = try await hostScreen(settings: settings, style: .light, text: "Ok teh cat\n")
        let editor = try XCTUnwrap(find(LineformTextView.self, in: window))
        XCTAssertFalse(editor.checksSpellingWhileTyping)

        XCTAssertFalse(editor.runSpellCheckPass(), "off: no pass")
        XCTAssertEqual(editor.spellCheck.misspelledRanges, [])
        editor.scheduleSpellCheck()
        try await Task.sleep(for: .seconds(SpellCheckPass.typingDelay + 0.2))
        XCTAssertEqual(editor.spellCheck.misspelledRanges, [], "off: nothing scheduled runs either")

        // Check Document Now is a command: it runs even with the switch off.
        XCTAssertTrue(editor.checkDocumentNow())
        XCTAssertEqual(editor.spellCheck.misspelledRanges, [NSRange(location: 3, length: 3)])

        settings.checksSpellingWhileTyping = true
        try await spin { editor.checksSpellingWhileTyping }
        XCTAssertTrue(editor.runSpellCheckPass())
        XCTAssertEqual(editor.spellCheck.misspelledRanges, [NSRange(location: 3, length: 3)])

        settings.checksSpellingWhileTyping = false
        try await spin { !editor.checksSpellingWhileTyping }
        XCTAssertEqual(editor.spellCheck.misspelledRanges, [], "turning it off clears the underlines")
        editor.layoutIfNeeded()
        XCTAssertNil(editor.spellingUnderlineLayer().path)
    }

    func testNoMacOrSidebarWordingInIPhoneStrings() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LineformiOS/Localizable.xcstrings")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])
        XCTAssertGreaterThan(strings.count, 50)
        let mac = try NSRegularExpression(pattern: "\\bMac(s|’s|'s)?\\b")
        // First run's copy is the owner's own product wording (`FirstRunCopy`, step 11), which may
        // name the Mac app on purpose (iCloud sync with it). The rule is for the app's UI.
        let ownerCopy = Set(FirstRunCopy.points + [FirstRunCopy.heading, FirstRunCopy.startWriting])
        for (key, entry) in strings {
            // The English value is the key unless an `en` localization says otherwise.
            let localizations = entry["localizations"] as? [String: [String: Any]]
            let english = ((localizations?["en"]?["stringUnit"] as? [String: Any])?["value"] as? String) ?? key
            let range = NSRange(english.startIndex..., in: english)
            if !ownerCopy.contains(key) {
                XCTAssertNil(mac.firstMatch(in: english, range: range), "an iPhone string names a Mac: \(english)")
            }
            XCTAssertFalse(english.localizedCaseInsensitiveContains("sidebar"), "an iPhone string names a sidebar: \(english)")
        }
        // The rows the Mac words differently are the iPhone's own.
        XCTAssertTrue(strings.keys.contains("Show iCloud in Files"))
        XCTAssertFalse(strings.keys.contains("Show iCloud in sidebar"))
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> UserDefaults {
        let suite = "SettingsTests-\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func hostScreen(settings: AppSettings, style: UIUserInterfaceStyle, text: String = "Hello\n") async throws -> UIWindow {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: SettingsTestUbiquitousItems())
        await document.prepare()
        document.edit(text)
        let store = ReadingProfileStore(defaults: try makeDefaults())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(
            rootView: DocumentScreen(document: document, profileStore: store, settings: settings)
        )
        window.makeKeyAndVisible()
        self.window = window
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(20))
            window.layoutIfNeeded()
        }
        return window
    }

    /// Waits for `condition`, yielding the main actor (a nested run loop cannot run main-queue
    /// work from inside a main-actor task).
    private func spin(timeout: TimeInterval = 3, until condition: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
            window?.layoutIfNeeded()
        }
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}

/// Every file is local: nothing downloads, and real iCloud is never asked.
private struct SettingsTestUbiquitousItems: UbiquitousItemAccessing {
    func downloadState(_ url: URL) -> UbiquitousDownloadState { .current }
    func startDownloading(_ url: URL) throws {}
}
