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
        try skipUnlessEnglishInterface()
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

        // pinned-en: the approved mockup's three switches, in order.
        XCTAssertEqual(SettingsSection.rows.map(\.title), [
            "Automatic Dark Mode", "Check spelling while typing", "In-app notifications",
        ])
        // Each row still explains itself, to VoiceOver only (the hint), never as drawn text.
        XCTAssertTrue((SettingsSection.rows + [SettingsSection.iCloudRow]).allSatisfy { !$0.note.isEmpty })
        // pinned-en: the switches, the Files group, then Clear Version History (the Mac's copy).
        // Check Document Now left Settings for the format row's Check Spelling (2026-11-24).
        XCTAssertEqual(SettingsSection.rowTitles, [
            "Automatic Dark Mode", "Check spelling while typing", "In-app notifications",
            "Show iCloud in Files", "Show Hidden Folders", "Sort folders by",
            "Clear Version History",
        ])
        XCTAssertFalse(SettingsSection.clearHistoryNote.isEmpty)
        // Show iCloud in Files only when this device's iCloud container resolves (never in Debug).
        XCTAssertTrue(SettingsSection.shownFilesRows(iCloudAvailable: false).isEmpty)
        XCTAssertEqual(SettingsSection.shownFilesRows(iCloudAvailable: true).map(\.id), ["showICloud"])
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
        // The phone's setting is the scene's (`SystemAppearance`), never the screen's own colour
        // scheme, which follows the theme for the status bar.
        let settings = AppSettings(defaults: try makeDefaults())
        let phone = SystemAppearance(style: .dark, followsWindow: false)
        let window = try await hostScreen(settings: settings, style: .dark, phone: phone)
        let editor = try XCTUnwrap(find(LineformTextView.self, in: window))
        XCTAssertEqual(editor.profile.themeID, .quiet, "Dark appearance draws the page as Quiet")

        phone.style = .light
        try await spin { editor.profile.themeID == .system }

        phone.style = .dark
        try await spin { editor.profile.themeID == .quiet }

        settings.automaticDarkMode = false
        try await spin { editor.profile.themeID == .system }
    }

    /// The status bar (the screen's colour scheme) follows the display theme, not the phone: a dark
    /// phone with a light theme gets dark status text, a light phone with Quiet light status text.
    /// Automatic Dark Mode still reads the phone (`SystemAppearance`, the window's own style), never the
    /// scheme it set.
    func testStatusBarFollowsTheDisplayTheme() async throws {
        var quiet = ReadingProfile.original
        quiet.themeID = .quiet
        XCTAssertEqual(DocumentScreen.chromeColorScheme(for: .original, systemStyle: .dark), .light)
        XCTAssertEqual(DocumentScreen.chromeColorScheme(for: quiet, systemStyle: .light), .dark)

        // Phone dark, a light theme (Automatic Dark Mode off): light scheme, dark status text.
        let settings = AppSettings(defaults: try makeDefaults())
        settings.automaticDarkMode = false
        let phone = SystemAppearance(style: .dark, followsWindow: false)
        let window = try await hostScreen(settings: settings, style: .dark, phone: phone)
        let editor = try XCTUnwrap(find(LineformTextView.self, in: window))
        XCTAssertEqual(editor.profile.themeID, .system)
        try await spin { editor.traitCollection.userInterfaceStyle == .light }
        XCTAssertNotEqual(window.rootViewController?.preferredStatusBarStyle, .lightContent)

        // Phone light, Quiet: dark scheme, light status text.
        window.isHidden = true
        let profiles = ReadingProfileStore(defaults: try makeDefaults())
        profiles.update { $0.themeID = .quiet }
        let lightPhone = SystemAppearance(style: .light, followsWindow: false)
        let quietWindow = try await hostScreen(settings: settings, style: .light, phone: lightPhone, profiles: profiles)
        let quietEditor = try XCTUnwrap(find(LineformTextView.self, in: quietWindow))
        XCTAssertEqual(quietEditor.profile.themeID, .quiet)
        try await spin { quietEditor.traitCollection.userInterfaceStyle == .dark }
        XCTAssertNotEqual(quietWindow.rootViewController?.preferredStatusBarStyle, .darkContent)

        // Automatic Dark Mode on: the phone going dark still turns Original into Quiet, though the
        // screen's own scheme was light.
        settings.automaticDarkMode = true
        lightPhone.style = .light
        profiles.update { $0.themeID = .system }
        try await spin { quietEditor.profile.themeID == .system }
        lightPhone.style = .dark
        try await spin { quietEditor.profile.themeID == .quiet }
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
        try skipUnlessEnglishInterface()
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LineformiOS/Localizable.xcstrings")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])
        XCTAssertGreaterThan(strings.count, 50)
        let mac = try NSRegularExpression(pattern: "\\bMac(s|’s|'s)?\\b")
        // First run's copy is the owner's own product wording (`FirstRunCopy`, step 11), which may
        // name the Mac app on purpose (iCloud sync with it). The rule is for the app's UI.
        let ownerCopy = Set(FirstRunCopy.allStrings)
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

        // The package strings the iPhone shows (Connect Your AI and the AI messages) follow the same
        // rule, in every language: the Mac's "on this Mac" and "Lineform ▸ Connect Your AI…" have
        // iPhone variants.
        let package = try ConnectAITests.packageCatalog()
        var checkedPackageStrings = 0
        for key in ConnectAIFormModel.allDisplayedStrings {
            var values = [key]
            if let localizations = (package[key] as? [String: Any])?["localizations"] as? [String: [String: Any]] {
                checkedPackageStrings += 1
                values += localizations.values.compactMap { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
            }
            for value in values {
                let range = NSRange(value.startIndex..., in: value)
                XCTAssertNil(mac.firstMatch(in: value, range: range), "an iPhone AI string names a Mac: \(value)")
                XCTAssertFalse(value.contains("Lineform ▸"), "an iPhone AI string points at the Mac's menu bar: \(value)")
            }
        }
        XCTAssertGreaterThan(checkedPackageStrings, 10)
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> UserDefaults {
        let suite = "SettingsTests-\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func hostScreen(settings: AppSettings, style: UIUserInterfaceStyle, text: String = "Hello\n",
                            phone: SystemAppearance? = nil, profiles: ReadingProfileStore? = nil) async throws -> UIWindow {
        let folder = self.folder!
        let document = OpenDocument(folderProvider: { folder }, ubiquitousItems: SettingsTestUbiquitousItems())
        await document.prepare()
        document.edit(text)
        let store = try profiles ?? ReadingProfileStore(defaults: makeDefaults())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(
            rootView: DocumentScreen(document: document, profileStore: store, settings: settings,
                                     systemAppearance: phone ?? SystemAppearance(style: style, followsWindow: false))
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
