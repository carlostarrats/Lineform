import Foundation

/// Persists the chosen PDF-export typography preset id. Mirrors the `HiddenFoldersMenuState`
/// pattern: plain `UserDefaults`, injectable for tests. Unknown/absent → `.standard`.
enum ExportStylePreference {
    static let defaultsKey = "Lineform.export.typographyStyleID"

    static func selectedPresetID(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: defaultsKey) ?? ExportTypographyPreset.standard.id
    }

    static func setSelectedPresetID(_ id: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: defaultsKey)
    }

    static func selectedPreset(defaults: UserDefaults = .standard) -> ExportTypographyPreset {
        ExportTypographyPreset.preset(withID: defaults.string(forKey: defaultsKey))
    }
}
