import Combine
import Foundation

final class ReadingProfileStore: ObservableObject {
    private static let legacyOriginalColumnWidth = 680.0
    private let defaults: UserDefaults
    private let storageKey: String

    static let activePresetIDKey = "Lineform.activeReadingPresetID"
    static let overridesKey = "Lineform.readingPresetOverrides"

    @Published var activeProfile: ReadingProfile {
        didSet {
            persist(activeProfile)
        }
    }

    /// The built-in preset whose slot the active profile belongs to. Edits are
    /// written into that preset's override so each preset keeps its own.
    @Published private(set) var activePresetID: UUID? {
        didSet {
            if let id = activePresetID {
                defaults.set(id.uuidString, forKey: Self.activePresetIDKey)
            } else {
                defaults.removeObject(forKey: Self.activePresetIDKey)
            }
        }
    }

    private var overrides: [UUID: ReadingProfile]

    init(defaults: UserDefaults = .standard, storageKey: String = "Lineform.activeReadingProfile") {
        self.defaults = defaults
        self.storageKey = storageKey
        let profile = Self.restore(from: defaults, key: storageKey)
        var restoredOverrides = Self.restoreOverrides(from: defaults)
        var presetID = defaults.string(forKey: Self.activePresetIDKey).flatMap(UUID.init(uuidString:))
        if presetID == nil {
            // Legacy single-profile storage: file the profile into its preset's slot.
            presetID = ReadingPreset.builtIn.first { $0.id == profile.id }?.id
                ?? ReadingPreset.matchingPresetID(for: profile)
            if let id = presetID,
               let preset = ReadingPreset.builtIn.first(where: { $0.id == id }),
               restoredOverrides[id] == nil,
               preset.profile != profile {
                restoredOverrides[id] = profile
                Self.persistOverrides(restoredOverrides, to: defaults)
            }
            if let id = presetID {
                defaults.set(id.uuidString, forKey: Self.activePresetIDKey)
            }
        }
        self.overrides = restoredOverrides
        self.activeProfile = profile
        self.activePresetID = presetID
    }

    func apply(_ profile: ReadingProfile) {
        activePresetID = ReadingPreset.builtIn.first { $0.id == profile.id }?.id
        activeProfile = profile
    }

    func applyPreset(_ preset: ReadingPreset) {
        activePresetID = preset.id
        activeProfile = overrides[preset.id] ?? preset.profile
    }

    func resetToDefault() {
        overrides[ReadingPreset.original.id] = nil
        Self.persistOverrides(overrides, to: defaults)
        apply(.original)
    }

    /// Drops the active preset's edits and restores its pristine profile;
    /// other presets keep theirs. With no active preset, resets to the default.
    func resetCurrentPreset() {
        guard
            let id = activePresetID,
            let preset = ReadingPreset.builtIn.first(where: { $0.id == id })
        else {
            resetToDefault()
            return
        }
        overrides[id] = nil
        Self.persistOverrides(overrides, to: defaults)
        activeProfile = preset.profile
    }

    func update(_ mutate: (inout ReadingProfile) -> Void) {
        var profile = activeProfile
        mutate(&profile)
        activeProfile = profile
        if let id = activePresetID {
            overrides[id] = profile
            Self.persistOverrides(overrides, to: defaults)
        }
    }

    private static func restoreOverrides(from defaults: UserDefaults) -> [UUID: ReadingProfile] {
        guard
            let data = defaults.data(forKey: overridesKey),
            let raw = try? JSONDecoder().decode([String: ReadingProfile].self, from: data)
        else {
            return [:]
        }
        var result: [UUID: ReadingProfile] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) { result[id] = value }
        }
        return result
    }

    private static func persistOverrides(_ overrides: [UUID: ReadingProfile], to defaults: UserDefaults) {
        let raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: overridesKey)
        }
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

        if profile.id == ReadingProfile.original.id, profile.columnWidth == legacyOriginalColumnWidth {
            var migratedProfile = profile
            migratedProfile.columnWidth = ReadingProfile.original.columnWidth
            return migratedProfile
        }

        return profile
    }
}
