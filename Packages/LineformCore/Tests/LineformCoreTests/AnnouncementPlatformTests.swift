import XCTest
@testable import LineformCore

/// An announcement entry may name the apps it is for (`platforms`: "mac", "ios"). With no field it
/// reaches both apps; the Mac shows only entries without the field or naming "mac", the iPhone only
/// entries without it or naming "ios". Runs on macOS and iOS, so `.current` is checked on both.
final class AnnouncementPlatformTests: XCTestCase {
    private func decode(_ entries: String) throws -> [Announcement] {
        try XCTUnwrap(AnnouncementFeed.decode(Data(#"{"version":1,"announcements":[\#(entries)]}"#.utf8)))
    }

    func testAnEntryWithoutPlatformsReachesBothApps() throws {
        let announcement = try XCTUnwrap(decode(#"{"id":"a","title":"T","body":"B"}"#).first)
        XCTAssertNil(announcement.platforms)
        XCTAssertTrue(announcement.appliesTo(appVersion: "1.0", platform: .mac))
        XCTAssertTrue(announcement.appliesTo(appVersion: "1.0", platform: .iPhone))
        XCTAssertTrue(announcement.appliesTo(appVersion: "1.0"))
    }

    func testAnEntryNamingPlatformsReachesOnlyThose() throws {
        let entries = try decode(#"""
        {"id":"mac","title":"T","body":"B","platforms":["mac"]},
        {"id":"ios","title":"T","body":"B","platforms":[" iOS "]},
        {"id":"both","title":"T","body":"B","platforms":["mac","ios"]},
        {"id":"future","title":"T","body":"B","platforms":["visionos"]}
        """#)
        XCTAssertEqual(entries.map(\.id), ["mac", "ios", "both", "future"])
        XCTAssertEqual(entries.filter { $0.appliesTo(appVersion: "1.0", platform: .mac) }.map(\.id), ["mac", "both"])
        XCTAssertEqual(entries.filter { $0.appliesTo(appVersion: "1.0", platform: .iPhone) }.map(\.id), ["ios", "both"])
    }

    /// Without a platform argument the running app's own platform decides, so both stores filter
    /// through the call they already make.
    func testTheRunningPlatformIsTheDefault() throws {
        let entries = try decode(#"""
        {"id":"mac","title":"T","body":"B","platforms":["mac"]},
        {"id":"ios","title":"T","body":"B","platforms":["ios"]}
        """#)
        let shown = entries.filter { $0.appliesTo(appVersion: "1.0") }.map(\.id)
        #if os(iOS)
        XCTAssertEqual(shown, ["ios"])
        #else
        XCTAssertEqual(shown, ["mac"])
        #endif
    }

    /// The version gate still applies alongside the platform one.
    func testTheVersionGateStillApplies() throws {
        let announcement = try XCTUnwrap(decode(#"{"id":"a","title":"T","body":"B","minAppVersion":"2.0","platforms":["ios","mac"]}"#).first)
        XCTAssertFalse(announcement.appliesTo(appVersion: "1.9", platform: .iPhone))
        XCTAssertTrue(announcement.appliesTo(appVersion: "2.0", platform: .iPhone))
    }

    /// The cache round-trips the field, so a cached Mac-only entry stays Mac-only after relaunch.
    func testTheCacheKeepsPlatforms() throws {
        let entries = try decode(#"{"id":"a","title":"T","body":"B","platforms":["mac"]},{"id":"b","title":"T","body":"B"}"#)
        let data = try XCTUnwrap(AnnouncementFeed.encode(entries))
        XCTAssertEqual(AnnouncementFeed.decode(data), entries)
        XCTAssertEqual(AnnouncementFeed.decode(data)?.map(\.platforms), [["mac"], nil])
    }

    /// Unknown keys stay ignored (what lets an older Mac build read a feed that uses `platforms`),
    /// and a malformed `platforms` skips only its own entry.
    func testUnknownKeysAreIgnoredAndABadPlatformsListSkipsOnlyItsEntry() throws {
        let entries = try decode(#"""
        {"id":"a","title":"T","body":"B","somethingNew":{"x":1}},
        {"id":"bad","title":"T","body":"B","platforms":["mac\nios"]},
        {"id":"long","title":"T","body":"B","platforms":["a","b","c","d","e","f","g","h","i"]},
        {"id":"c","title":"T","body":"B","platforms":["ios"]}
        """#)
        XCTAssertEqual(entries.map(\.id), ["a", "c"])
    }
}
