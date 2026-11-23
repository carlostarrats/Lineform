import Foundation
import XCTest

/// The iPhone's two catalogs — its own and the LineformCore package's — are complete in all six
/// languages: every translatable key has an English, Spanish, French, German, Japanese and
/// Simplified Chinese value; every string unit is `translated` (never `new`, `needs_review` or
/// `stale`); no value is empty; and every value's format specifiers match the English.
///
/// Reads the committed `.xcstrings` sources through `#filePath`, as the Mac's
/// `LocalizationCatalogTests` does, so the gate protects the files, not a built bundle. English is
/// the source language: a key with no `en` entry IS its English value.
final class PhoneCatalogCompletenessTests: XCTestCase {
    private static let languages = ["en", "es", "fr", "de", "ja", "zh-Hans"]
    private static let catalogs = [
        "LineformiOS/Localizable.xcstrings",
        "Packages/LineformCore/Sources/LineformCore/Resources/Localizable.xcstrings",
    ]

    private func strings(at path: String) throws -> [String: [String: Any]] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["sourceLanguage"] as? String, "en", path)
        return try XCTUnwrap(json["strings"] as? [String: [String: Any]])
    }

    private func isTranslatable(_ entry: [String: Any]) -> Bool {
        (entry["shouldTranslate"] as? Bool) ?? true
    }

    /// Every string unit under one language's localization, plural and device variations included,
    /// as (path within the entry, unit).
    private func units(in localization: [String: Any], path: String = "") -> [(String, [String: Any])] {
        var found: [(String, [String: Any])] = []
        if let unit = localization["stringUnit"] as? [String: Any] {
            found.append((path.isEmpty ? "stringUnit" : path, unit))
        }
        if let variations = localization["variations"] as? [String: [String: [String: Any]]] {
            for (kind, cases) in variations {
                for (name, nested) in cases {
                    found += units(in: nested, path: "\(path)\(kind).\(name)")
                }
            }
        }
        if let substitutions = localization["substitutions"] as? [String: [String: Any]] {
            for (token, nested) in substitutions {
                found += units(in: nested, path: "\(path)substitution \(token).")
            }
        }
        return found
    }

    /// `%#@token@` written as the token's positional specifier, so a substituted value compares
    /// with its key on the same terms as a plain one.
    private func expandingSubstitutions(_ value: String, _ localization: [String: Any]) -> String {
        guard let substitutions = localization["substitutions"] as? [String: [String: Any]] else { return value }
        var expanded = value
        for (token, spec) in substitutions {
            guard let argument = spec["argNum"] as? Int, let format = spec["formatSpecifier"] as? String else { continue }
            expanded = expanded.replacingOccurrences(of: "%#@\(token)@", with: "%\(argument)$\(format)")
        }
        return expanded
    }

    private static let specifier = try! NSRegularExpression(pattern: #"%(\d+\$)?(lld|ld|lu|@|d|f|s)"#)

    /// Argument position → conversion. A bare specifier takes the next implicit position.
    private func specifiers(_ text: String) -> [Int: String] {
        var map: [Int: String] = [:]
        var next = 1
        for match in Self.specifier.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let conversion = String(text[Range(match.range(at: 2), in: text)!])
            if match.range(at: 1).location != NSNotFound,
               let position = Int(String(text[Range(match.range(at: 1), in: text)!]).dropLast()) {
                map[position] = conversion
            } else {
                map[next] = conversion
                next += 1
            }
        }
        return map
    }

    func testEveryKeyIsCompleteAndTranslatedInAllSixLanguages() throws {
        for catalog in Self.catalogs {
            let strings = try strings(at: catalog)
            XCTAssertGreaterThan(strings.count, 5, "\(catalog) was read")
            for (key, entry) in strings where isTranslatable(entry) {
                let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
                for language in Self.languages {
                    guard let localization = localizations[language] else {
                        // The source language's value defaults to the key.
                        if language != "en" { XCTFail("\(catalog): '\(key)' has no \(language)") }
                        continue
                    }
                    let found = units(in: localization)
                    XCTAssertFalse(found.isEmpty, "\(catalog): '\(key)' \(language) has no string unit")
                    for (path, unit) in found {
                        let state = unit["state"] as? String
                        XCTAssertEqual(state, "translated", "\(catalog): '\(key)' \(language) \(path) is \(state ?? "nil")")
                        let value = unit["value"] as? String ?? ""
                        XCTAssertFalse(
                            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            "\(catalog): '\(key)' \(language) \(path) is empty"
                        )
                    }
                }
            }
        }
    }

    func testFormatSpecifiersAgreeWithEnglish() throws {
        for catalog in Self.catalogs {
            for (key, entry) in try strings(at: catalog) where isTranslatable(entry) {
                let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
                let english = specifiers(key)
                for language in Self.languages {
                    guard let localization = localizations[language] else { continue }
                    // Top-level units and plural / device forms; a substitution's own inner
                    // units carry only their own argument and are checked through expansion.
                    var values: [String] = []
                    if let value = (localization["stringUnit"] as? [String: Any])?["value"] as? String {
                        values.append(value)
                    }
                    if let variations = localization["variations"] as? [String: [String: [String: Any]]] {
                        for cases in variations.values {
                            for nested in cases.values {
                                if let value = (nested["stringUnit"] as? [String: Any])?["value"] as? String {
                                    values.append(value)
                                }
                            }
                        }
                    }
                    for value in values {
                        XCTAssertEqual(
                            specifiers(expandingSubstitutions(value, localization)), english,
                            "\(catalog): '\(key)' \(language) format specifiers drift from English: \(value)"
                        )
                    }
                }
            }
        }
    }

    /// A key marked do-not-translate carries no translations that could drift.
    func testDoNotTranslateKeysCarryNoTranslations() throws {
        for catalog in Self.catalogs {
            for (key, entry) in try strings(at: catalog) where !isTranslatable(entry) {
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                XCTAssertTrue(
                    Set(localizations.keys).isSubset(of: ["en"]),
                    "\(catalog): '\(key)' is shouldTranslate false but carries \(localizations.keys.sorted())"
                )
            }
        }
    }
}
