import Foundation
import XCTest

/// The iPhone's App Store submission pins: Info.plist keys, the privacy manifest, the version
/// shared with the Mac app, and the compiled icon. None of these affects a Debug build, so
/// nothing else notices when one goes missing; App Store Connect does, at upload.
/// The Mac's counterpart is `LineformTests/ReleaseResourceTests`.
final class PhoneReleaseResourceTests: XCTestCase {
    private var info: [String: Any] {
        get throws { try XCTUnwrap(Bundle.main.infoDictionary) }
    }

    /// Missing `LSApplicationCategoryType` is an outright rejection; missing
    /// `ITSAppUsesNonExemptEncryption` stops every upload to ask the export question by hand.
    func testInfoPlistCarriesAppStoreSubmissionKeys() throws {
        let info = try info
        XCTAssertEqual(info["LSApplicationCategoryType"] as? String, "public.app-category.productivity")
        XCTAssertEqual(info["ITSAppUsesNonExemptEncryption"] as? Bool, false)
    }

    /// On My iPhone › Lineform shows in Files and opens in place, and the app is offered for
    /// Markdown and plain text.
    func testInfoPlistDeclaresDocumentsAndFileSharing() throws {
        let info = try info
        XCTAssertEqual(info["UIFileSharingEnabled"] as? Bool, true)
        XCTAssertEqual(info["LSSupportsOpeningDocumentsInPlace"] as? Bool, true)

        let documentTypes = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let contentTypes = Set(documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        XCTAssertTrue(contentTypes.contains("net.daringfireball.markdown"))
        XCTAssertTrue(contentTypes.contains("public.plain-text"))

        let imported = try XCTUnwrap(info["UTImportedTypeDeclarations"] as? [[String: Any]])
        let markdown = try XCTUnwrap(imported.first { $0["UTTypeIdentifier"] as? String == "net.daringfireball.markdown" })
        let tags = try XCTUnwrap(markdown["UTTypeTagSpecification"] as? [String: Any])
        let extensions = try XCTUnwrap(tags["public.filename-extension"] as? [String])
        XCTAssertEqual(Set(extensions), ["md", "markdown"])
    }

    /// The same container, name and scope as the Mac, so the iCloud Drive folder is one
    /// "Lineform" folder whichever app made it.
    func testInfoPlistDeclaresLineformICloudDocumentsContainer() throws {
        let containers = try XCTUnwrap(try info["NSUbiquitousContainers"] as? [String: [String: Any]])
        let lineformContainer = try XCTUnwrap(containers["iCloud.com.lineform.app"])

        XCTAssertEqual(lineformContainer["NSUbiquitousContainerName"] as? String, "Lineform")
        XCTAssertEqual(lineformContainer["NSUbiquitousContainerIsDocumentScopePublic"] as? Bool, true)
        XCTAssertEqual(lineformContainer["NSUbiquitousContainerSupportedFolderLevels"] as? String, "Any")
    }

    /// The Mac rule, verbatim. The "Other" AI provider may use plain `http` on the local machine
    /// only. If ATS ever needs loosening for that, the ONLY permitted key is
    /// `NSAllowsLocalNetworking`; arbitrary loads (in any form) would let every remote http
    /// address through and are a review flag.
    func testATSAllowsAtMostLocalNetworking() throws {
        let info = try info
        guard let ats = info["NSAppTransportSecurity"] else { return }
        let dictionary = try XCTUnwrap(ats as? [String: Any], "NSAppTransportSecurity must be a dictionary")
        XCTAssertEqual(Set(dictionary.keys), ["NSAllowsLocalNetworking"])
        XCTAssertEqual(dictionary["NSAllowsLocalNetworking"] as? Bool, true)
        for key in dictionary.keys {
            XCTAssertFalse(key.hasPrefix("NSAllowsArbitraryLoads"), key)
        }
    }

    /// No permission prompts. There is no photo picker (images arrive by paste or drop), and
    /// `fileImporter`, the export document picker and the share sheet need no usage
    /// description. A future feature that adds one must justify the key here, by name.
    func testNoUsageDescriptionsAreDeclared() throws {
        let declared = try info.keys.filter { $0.hasPrefix("NS") && $0.hasSuffix("UsageDescription") }
        XCTAssertEqual(declared.sorted(), [], "Usage descriptions need a reason in this test: \(declared.sorted())")
    }

    /// The bundled privacy manifest: no tracking, no collected data, and exactly the
    /// required-reason APIs the app and its statically linked packages use. The reasons are
    /// explained in the manifest itself and in docs/release/app-store-release.md ▸ iPhone.
    func testPrivacyManifestDeclaresNoTrackingAndRequiredReasons() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy must be in the app bundle's Resources"
        )
        let data = try Data(contentsOf: url)
        let manifest = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [String])?.count, 0)
        XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)

        let accessed = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: [String]] = [:]
        for entry in accessed {
            let type = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            XCTAssertNil(reasons[type], "\(type) is declared twice")
            reasons[type] = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
        }
        XCTAssertEqual(reasons, [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1", "3B52.1", "DDA9.1"]
        ])
    }

    /// One App Store listing, one version: the Mac app, its Quick Look extension and the iPhone
    /// app carry the same `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in Debug and
    /// Release, and the running app reports them.
    func testVersionAndBuildMatchTheMacApp() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Lineform.xcodeproj/project.pbxproj")
        let project: String
        do {
            project = try String(contentsOf: projectURL, encoding: .utf8)
        } catch {
            XCTFail("Could not read \(projectURL.path): \(error)")
            throw error
        }

        var versions: [String] = []
        var builds: [String] = []
        for target in ["Lineform", "LineformQuickLook", "LineformiOS"] {
            let configurationIDs = try Self.configurationIDs(forTarget: target, in: project)
            XCTAssertEqual(configurationIDs.count, 2, "\(target) should have Debug and Release")
            for id in configurationIDs {
                let settings = try Self.buildSettings(ofConfiguration: id, in: project)
                versions.append(try XCTUnwrap(Self.value(of: "MARKETING_VERSION", in: settings), "\(target) \(id) MARKETING_VERSION"))
                builds.append(try XCTUnwrap(Self.value(of: "CURRENT_PROJECT_VERSION", in: settings), "\(target) \(id) CURRENT_PROJECT_VERSION"))
            }
        }

        XCTAssertGreaterThanOrEqual(versions.count, 4, "fewer configurations than expected: the parse found nothing")
        XCTAssertEqual(Set(versions).count, 1, "MARKETING_VERSION differs between targets: \(versions)")
        XCTAssertEqual(Set(builds).count, 1, "CURRENT_PROJECT_VERSION differs between targets: \(builds)")

        let info = try info
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, versions.first)
        XCTAssertEqual(info["CFBundleVersion"] as? String, builds.first)
    }

    /// The shared Icon Composer file compiles into the asset catalog and the Info.plist names it.
    func testAppIconIsCompiledForIOS() throws {
        let icons = try XCTUnwrap(try info["CFBundleIcons"] as? [String: Any], "CFBundleIcons is missing")
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any], "CFBundlePrimaryIcon is missing")
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
        XCTAssertNotNil(Bundle.main.url(forResource: "Assets", withExtension: "car"), "Assets.car is not bundled")
    }

    // MARK: - pbxproj parsing

    /// The IDs listed in a target's configuration list (its Debug and Release).
    private static func configurationIDs(forTarget target: String, in project: String) throws -> [String] {
        let lines = project.components(separatedBy: "\n")
        let header = "/* Build configuration list for PBXNativeTarget \"\(target)\" */ = {"
        let start = try XCTUnwrap(lines.firstIndex { $0.hasSuffix(header) }, "no configuration list for \(target)")
        var ids: [String] = []
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "};" { break }
            guard trimmed.hasSuffix("*/,"), let id = trimmed.split(separator: " ").first,
                  id.count == 24, id.allSatisfy(\.isHexDigit) else { continue }
            ids.append(String(id))
        }
        return ids
    }

    /// The lines of one XCBuildConfiguration's definition, from its header to its `name`.
    private static func buildSettings(ofConfiguration id: String, in project: String) throws -> [String] {
        let lines = project.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let start = try XCTUnwrap(
            lines.firstIndex { $0.hasPrefix("\(id) /*") && $0.hasSuffix("= {") },
            "no build configuration \(id)"
        )
        var block: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("name = ") { break }
            block.append(line)
        }
        XCTAssertTrue(block.contains("isa = XCBuildConfiguration;"), "\(id) is not a build configuration")
        return block
    }

    private static func value(of key: String, in settings: [String]) -> String? {
        for line in settings where line.hasPrefix("\(key) = ") && line.hasSuffix(";") {
            return String(line.dropFirst(key.count + 3).dropLast())
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }
}
