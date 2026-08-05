import XCTest

/// Reads the .xcstrings source files from the repo (via #filePath), not the built
/// bundle — the gates protect the committed catalogs.
final class LocalizationCatalogTests: XCTestCase {
    private static let languages = ["es", "fr", "de", "ja", "zh-Hans"]

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)          // …/LineformTests/LocalizationCatalogTests.swift
            .deletingLastPathComponent()          // …/LineformTests
            .deletingLastPathComponent()          // repo root
    }

    private func catalog(_ name: String) throws -> [String: [String: Any]] {
        let url = repoRoot().appendingPathComponent("Lineform/\(name).xcstrings")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: [String: Any]])
    }

    private func translation(_ entry: [String: Any], _ language: String) -> String? {
        let localizations = entry["localizations"] as? [String: [String: Any]]
        let unit = localizations?[language]?["stringUnit"] as? [String: Any]
        // Plural entries nest under "variations"; any translated variation counts as present.
        if unit == nil, let variations = localizations?[language]?["variations"] as? [String: Any],
           let plural = variations["plural"] as? [String: [String: Any]],
           let anyForm = plural.values.first?["stringUnit"] as? [String: Any] {
            return anyForm["value"] as? String
        }
        return unit?["value"] as? String
    }

    private func isTranslatable(_ entry: [String: Any]) -> Bool {
        (entry["shouldTranslate"] as? Bool) ?? true
    }

    func testEveryKeyIsTranslatedInEveryLanguage() throws {
        for name in ["Localizable", "InfoPlist", "AppShortcuts"] {
            let strings = try catalog(name)
            for (key, entry) in strings where isTranslatable(entry) {
                for language in Self.languages {
                    XCTAssertNotNil(translation(entry, language),
                                    "\(name): '\(key)' missing \(language)")
                }
            }
        }
    }

    func testFormatSpecifiersMatchAcrossLanguages() throws {
        let pattern = try NSRegularExpression(pattern: #"%(\d+\$)?(lld|@|d|ld|lu|f|s)"#)
        func specifiers(_ s: String) -> [String] {
            pattern.matches(in: s, range: NSRange(s.startIndex..., in: s))
                .map { String(s[Range($0.range, in: s)!]) }
        }
        for name in ["Localizable", "InfoPlist", "AppShortcuts"] {
            for (key, entry) in try catalog(name) where isTranslatable(entry) {
                let source = specifiers(key)
                for language in Self.languages {
                    guard let value = translation(entry, language) else { continue }
                    XCTAssertEqual(specifiers(value), source,
                                   "\(name): '\(key)' \(language) placeholder drift")
                }
            }
        }
    }

    func testGlossaryTermsTranslateConsistently() throws {
        let glossaryURL = repoRoot().appendingPathComponent("docs/notes/lineform-glossary.json")
        let glossary = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: glossaryURL)) as? [String: [String: String]])
        // Keys whose English is a whole glossary term used in a different sense may
        // be exempted here, with a comment saying why. Empty until proven needed.
        // Three keys use "write" as the ordinary verb, not as the name of Write mode. The
        // glossary rendering is a NOUN in every language ("Escritura", "Écriture",
        // "Schreiben", "執筆", "写作"), so forcing it in here would replace a natural verb
        // clause with the mode's label — "mientras escribes" would have to become
        // "durante la Escritura", and "Lineform no ha podido escribir" would claim the app
        // failed at the mode rather than at the file write. The mode itself is carried by
        // the "Write" and "Toggle Write / Read" keys, which are NOT exempt.
        let exemptions: Set<String> = [
            "Highlights the current line while you write.",
            "Keeps the current line centered as you write.",
            "Lineform couldn’t write “%@”. Choose a different location and try again.",
        ]

        // Whole-word matching, not substring: "Tab" must not match "Table" and
        // "Read" must not match "Reading & Accessibility".
        func containsWholeWord(_ text: String, _ term: String) -> Bool {
            guard let regex = try? NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: term))\\b",
                options: .caseInsensitive) else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        let strings = try catalog("Localizable")
        for (term, translations) in glossary {
            for (key, entry) in strings
            where isTranslatable(entry) && containsWholeWord(key, term) && !exemptions.contains(key) {
                for language in Self.languages {
                    guard let value = translation(entry, language),
                          let expected = translations[language] else { continue }
                    XCTAssertTrue(
                        value.localizedCaseInsensitiveContains(expected),
                        "'\(key)' \(language): expected glossary term '\(expected)' in '\(value)'")
                }
            }
        }
    }
}
