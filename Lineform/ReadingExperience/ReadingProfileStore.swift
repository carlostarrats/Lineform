import Combine
import Foundation

final class ReadingProfileStore: ObservableObject {
    private let defaults: UserDefaults
    private let storageKey: String

    @Published var activeProfile: ReadingProfile {
        didSet {
            persist(activeProfile)
        }
    }

    init(defaults: UserDefaults = .standard, storageKey: String = "Lineform.activeReadingProfile") {
        self.defaults = defaults
        self.storageKey = storageKey
        self.activeProfile = Self.restore(from: defaults, key: storageKey)
    }

    func apply(_ profile: ReadingProfile) {
        activeProfile = profile
    }

    func applyPreset(_ preset: ReadingPreset) {
        var profile = preset.profile
        profile.applyTheme(activeProfile.themeID)
        activeProfile = profile
    }

    func resetToDefault() {
        apply(.original)
    }

    func update(_ mutate: (inout ReadingProfile) -> Void) {
        var profile = activeProfile
        mutate(&profile)
        activeProfile = profile
    }

    private func persist(_ profile: ReadingProfile) {
        guard let data = try? JSONEncoder().encode(profile) else {
            return
        }

        defaults.set(data, forKey: storageKey)
    }

    private static func restore(from defaults: UserDefaults, key: String) -> ReadingProfile {
        guard
            let data = defaults.data(forKey: key),
            let profile = try? JSONDecoder().decode(ReadingProfile.self, from: data)
        else {
            return .original
        }

        return profile
    }
}
