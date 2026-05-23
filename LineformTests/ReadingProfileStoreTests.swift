import XCTest
@testable import Lineform

final class ReadingProfileStoreTests: XCTestCase {
    func testPersistsActiveProfileAcrossStoreInstances() {
        let defaults = UserDefaults(suiteName: "LineformReadingProfileStoreTests")!
        defaults.removePersistentDomain(forName: "LineformReadingProfileStoreTests")

        let store = ReadingProfileStore(defaults: defaults)
        store.apply(ReadingPreset.paper.profile)

        let restored = ReadingProfileStore(defaults: defaults)

        XCTAssertEqual(restored.activeProfile, ReadingPreset.paper.profile)
    }

    func testFallsBackToOriginalWhenNoProfileIsPersisted() {
        let defaults = UserDefaults(suiteName: "LineformReadingProfileStoreEmptyTests")!
        defaults.removePersistentDomain(forName: "LineformReadingProfileStoreEmptyTests")

        let store = ReadingProfileStore(defaults: defaults)

        XCTAssertEqual(store.activeProfile, .original)
    }

    func testResetRestoresDefaultNormalReadingProfile() {
        let defaults = UserDefaults(suiteName: "LineformReadingProfileStoreResetTests")!
        defaults.removePersistentDomain(forName: "LineformReadingProfileStoreResetTests")
        let store = ReadingProfileStore(defaults: defaults)
        store.apply(ReadingPreset.dyslexia.profile)

        store.resetToDefault()

        XCTAssertEqual(store.activeProfile, .original)
    }
}
